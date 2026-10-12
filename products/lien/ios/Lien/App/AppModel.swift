// AppModel.swift — ルート状態とサーバー同期の司令塔(issue #55 / DESIGN §3.3, §4)
//
// 役割:
//   1. ルート画面系統(AppPhase)を AppRouter で導出して保持する
//      (入力は「セッションの有無」と「App Group の snapshot」だけ。独自の永続フラグは持たない)
//   2. サーバー同期(GET /snapshot)を起動時・前面復帰時・push 受信時に走らせ、結果を App Group へ
//      反映して phase を更新する(ペア成立 solo → paired も、ペア解消 paired → solo も同じ経路)
//   3. 画面側の変更(オンボ完了・約束保存・ペア成立)を受けて phase を再導出する
//   4. push_token / push_env の自動保存(PushTokenSync)を、セッション確立・前面復帰のたびに促す
//   5. 招待ディープリンク(lien://invite/<token>)を保持し、ソロのホームで招待画面を開く
//
// 同期は同時に1本だけ走らせる。走行中に要求が来たら、終わった直後に1回だけ取り直す。

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    // MARK: - 画面状態

    /// ルート画面系統(AppRouter の出力)
    private(set) var phase: AppPhase
    /// ホームが snapshot を読み直すトリガ(同期・約束保存・ペア成立のたびに増える)
    private(set) var snapshotRevision = 0
    /// セッションはあるが snapshot が未取得で、初回同期の結果を待っている
    /// (再インストールで既存の約束・ペアを取りこぼして約束設定を見せてしまうのを避ける)
    private(set) var isResolving = false

    /// ディープリンクで受けた招待コード(招待画面が入力欄へプリフィルして消費する)
    var pendingInviteToken: String?
    /// 招待画面(ソロのホームから開くシート)を出すか
    var showsPairing = false

    // MARK: - 依存

    let services: AppServices
    private let synchronizer: SnapshotSynchronizer
    private let now: () -> Date

    private var isRefreshing = false
    private var rerunRequested = false
    private var lastRefreshFinishedAt: Date?

    /// 前面復帰の同期を省く最短間隔(起動直後の start() との二重取得を避ける。push 起点は省かない)
    static let minForegroundRefreshInterval: TimeInterval = 2

    init(services: AppServices, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.now = now
        let pendingOps = services.pendingOps
        self.synchronizer = SnapshotSynchronizer(
            client: services.snapshotClient,
            store: services.store,
            hasPendingOps: { !(pendingOps?.isEmpty ?? true) },
            reloadWidgets: services.reloadWidgets
        )
        self.phase = AppRouter.phase(
            hasSession: services.auth.currentUserID != nil,
            snapshot: services.store?.loadSnapshot()
        )
    }

    // MARK: - ライフサイクル

    /// アプリ起動時(RootView の .task)。既存セッションの復元で保留中だった APNs 登録を送り、
    /// セッションがあればサーバーと同期する
    func start() async {
        Task { await services.pushTokenSync.sessionDidChange() }
        guard phase != .onboarding else { return }
        if phase == .promiseSetup, services.store?.loadSnapshot() == nil {
            isResolving = true
        }
        await refresh()
    }

    /// フォアグラウンド復帰時(DESIGN §4: アプリ本体は復帰時に必ず GET /snapshot で自己修復する)
    func sceneDidBecomeActive() async {
        Task { await services.pushTokenSync.flush() }
        guard phase != .onboarding else { return }
        if let last = lastRefreshFinishedAt,
           now().timeIntervalSince(last) < Self.minForegroundRefreshInterval {
            return
        }
        await refresh()
    }

    /// リモート通知の受信時(AppDelegate → RemoteNotificationRelay)。
    /// 可視 push は NSE が snapshot を書くが、アプリ本体の表示・phase 更新はここで追従する。
    /// サイレント push(取消・約束変更・ペア更新)はこの同期が主経路になる
    func remoteNotificationReceived() async {
        guard phase != .onboarding else { return }
        await refresh()
    }

    // MARK: - 画面からの通知

    /// オンボーディング完了(匿名サインインとプロフィール更新は済んでいる)
    func onboardingFinished() async {
        reloadFromStore()
        Task { await services.pushTokenSync.sessionDidChange() }
        if phase == .promiseSetup, services.store?.loadSnapshot() == nil {
            isResolving = true
        }
        await refresh()
    }

    /// 約束の保存が成功した(snapshot の myPromise* は PromiseSetupViewModel が書き込み済み)
    func promiseSaved() {
        reloadFromStore()
        services.reloadWidgets() // ウィジェットの空状態(「アプリを開いてはじめよう」)を約束入りの表示へ
        Task { await refresh() }
    }

    /// 招待の受諾が成功した(受諾者視点の snapshot は PairingViewModel が書き込み済み)
    func pairingSucceeded() {
        pendingInviteToken = nil
        reloadFromStore()
        services.reloadWidgets() // ウィジェットをペア成立後の表示へ
        Task { await refresh() }
    }

    /// 招待ディープリンク(lien://invite/<token> / 静的ページ URL)。招待以外・不正形式は無視する
    func handleDeepLink(_ url: URL) {
        guard phase != .paired, let token = DeepLinkHandler.inviteToken(from: url) else { return }
        pendingInviteToken = token
        applyPendingInvite()
    }

    /// ソロのホームの「パートナーを招待する」
    func presentPairing() {
        guard phase == .solo else { return }
        showsPairing = true
    }

    // MARK: - サーバー同期

    /// GET /snapshot で端末の snapshot を最新にして phase を再導出する。
    /// 同時に1本だけ。走行中に呼ばれたら、終わった直後に1回だけ取り直す
    func refresh() async {
        guard !isRefreshing else {
            rerunRequested = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshFinishedAt = now()
        }
        repeat {
            rerunRequested = false
            var outcome = await synchronizer.sync()
            if outcome == .skippedLocalChanged {
                // 取得中にホームが新しい状態を保存した: 取得結果は捨てて1回だけ取り直す
                outcome = await synchronizer.sync()
            }
            isResolving = false
            reloadFromStore()
        } while rerunRequested
    }

    // MARK: - private

    /// App Group の snapshot とセッションから phase を再導出し、ホームに読み直しを促す
    private func reloadFromStore() {
        phase = AppRouter.phase(
            hasSession: services.auth.currentUserID != nil,
            snapshot: services.store?.loadSnapshot()
        )
        snapshotRevision += 1
        applyPendingInvite()
    }

    /// 保留中の招待コードに応じて招待画面を開閉する:
    /// ペア成立済みなら不要(コードも捨てる)/ ソロのホームなら開く(オンボ・約束設定の後で届く)
    private func applyPendingInvite() {
        switch phase {
        case .paired:
            pendingInviteToken = nil
            showsPairing = false
        case .solo:
            if pendingInviteToken != nil { showsPairing = true }
        case .onboarding, .promiseSetup:
            showsPairing = false
        }
    }
}
