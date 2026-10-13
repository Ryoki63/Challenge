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
//   6. オンボーディングのまま起動したあとでセッションが読めるようになったら、phase を導き直す
//      (再起動後の最初のアンロック前にバックグラウンド起動されると Keychain を読めない — issue #62)
//   7. アカウント・ペアの操作(AccountOperating — issue #23): ペアの解消(= ブロック)・アカウントの削除・
//      サインアウトのあとの端末の後始末(記録を消し、ウィジェットを更新し、オンボーディングへ戻る)と、
//      セッションが使えなくなったとき(snapshot の取得が 401 / user_not_found で続く)の確認
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
    /// 設定画面(ホームの歯車から開くシート)を出すか
    var showsSettings = false
    /// セッションが使えなくなったと判断して、「はじめからやり直しますか?」の確認を出しているか
    /// (snapshot の取得が 401 / user_not_found で連続した — SessionHealthMonitor)
    private(set) var sessionLost = false

    /// ホームの通報・ブロックの状態(アプリで 1 つ。相手の写真・ニックネームと約束の文・植物の名前の長押しと、
    /// 確認の表示が同じものを見る — T23 #23)
    @ObservationIgnored lazy var moderation: ModerationViewModel = ModerationViewModel(
        store: services.store,
        account: self
    )

    // MARK: - 依存

    let services: AppServices
    private let synchronizer: SnapshotSynchronizer
    private let now: () -> Date
    /// 同期の結果を端末へ書いてよいか(アカウントの削除・サインアウトで端末の記録を消している間は閉じる)
    private let syncGate: SyncGate
    /// セッションが連続して拒否されているかの見張り
    private var sessionMonitor = SessionHealthMonitor()
    /// 端末の記録を消してサインアウトしている最中(同期と二重の後始末を止める)
    private var isEndingSession = false

    private var isRefreshing = false
    /// 同期の走行中に別の要求が来た(終了直後に1回だけ取り直す)。テストが観測する
    private(set) var rerunRequested = false
    private var lastRefreshFinishedAt: Date?
    /// このプロセスの中で、オンボーディングのプロフィール送信(匿名サインインを含む)を始めたか。
    /// 始めたあとにできたセッションは「いま作っているセッション」であって、起動時に読めなかったものの
    /// 復元ではない。復元と取り違えて phase を進めると、通知の許可画面などを飛ばしてしまう
    private var isOnboardingUnderway = false

    /// 前面復帰の同期を省く最短間隔(起動直後の start() との二重取得を避ける。push 起点は省かない)
    static let minForegroundRefreshInterval: TimeInterval = 2

    init(services: AppServices, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.now = now
        let pendingOps = services.pendingOps
        let gate = SyncGate()
        self.syncGate = gate
        self.synchronizer = SnapshotSynchronizer(
            client: services.snapshotClient,
            store: services.store,
            hasPendingOps: { !(pendingOps?.isEmpty ?? true) },
            reloadWidgets: services.reloadWidgets,
            canApply: { gate.isOpen }
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
        await syncFirstTimeIfNeeded()
    }

    /// フォアグラウンド復帰時(DESIGN §4: アプリ本体は復帰時に必ず GET /snapshot で自己修復する)
    func sceneDidBecomeActive() async {
        Task { await services.pushTokenSync.flush() }
        if phase == .onboarding {
            // 起動時にセッションが読めずオンボのまま立ち上がった端末が、アンロック後に前面へ来た場合の回復
            // (復帰直後の同期は、直近の同期との間隔で間引かない)
            guard restoreSessionIfAvailable() else { return }
            await syncFirstTimeIfNeeded()
            return
        }
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
        if phase == .onboarding {
            // バックグラウンド起動のプロセスが、アンロック後に受けた push でセッションの復元に気づく場合
            guard restoreSessionIfAvailable() else { return }
            await syncFirstTimeIfNeeded()
            return
        }
        await refresh()
    }

    // MARK: - 画面からの通知

    /// オンボーディングのプロフィール送信(匿名サインインを含む)が始まった。
    /// 以降、完了するまでの間にできたセッションは、起動時に読めなかったセッションの復元として扱わない
    func onboardingProfileSubmitStarted() {
        isOnboardingUnderway = true
    }

    /// オンボーディング完了(匿名サインインとプロフィール更新は済んでいる)
    func onboardingFinished() async {
        isOnboardingUnderway = false
        reloadFromStore()
        Task { await services.pushTokenSync.sessionDidChange() }
        await syncFirstTimeIfNeeded()
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

    /// ソロのホームの「相手を招待する」
    func presentPairing() {
        guard phase == .solo else { return }
        showsPairing = true
    }

    // MARK: - サーバー同期

    /// GET /snapshot で端末の snapshot を最新にして phase を再導出する。
    /// 同時に1本だけ。走行中に呼ばれたら、終わった直後に1回だけ取り直す
    func refresh() async {
        // 端末の記録を消している最中は同期しない(古いアカウントの snapshot を書き戻さない)
        guard !isEndingSession else { return }
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
            noteSyncOutcome(outcome)
            isResolving = false
            reloadFromStore()
        } while rerunRequested && !isEndingSession
    }

    /// 同期の結果からセッションの状態を見張る。401 / user_not_found が連続したら確認を出す
    private func noteSyncOutcome(_ outcome: SnapshotSynchronizer.Outcome) {
        if sessionMonitor.record(outcome) == .lost {
            sessionLost = true
        }
    }

    // MARK: - private

    /// セッションがある状態から始める同期。端末に snapshot が無ければ(再インストール直後など)、
    /// 既存の約束・ペアがサーバーにあるかもしれないので、結果が出るまで約束設定を出さず読み込み表示にする
    private func syncFirstTimeIfNeeded() async {
        if phase == .promiseSetup, services.store?.loadSnapshot() == nil {
            isResolving = true
        }
        await refresh()
    }

    /// phase がオンボーディングのまま起動したあとで、セッションが読めるようになっていたら(= 既存ユーザー)、
    /// phase を導き直す。戻り値は、オンボーディングを抜けた(同期を始めてよい)か。
    ///
    /// 再起動後に端末が最初にアンロックされるまで、Keychain(AfterFirstUnlock)は読めない。その前に
    /// サイレント push などでバックグラウンド起動されたプロセスは、セッション無し = オンボーディングで
    /// 立ち上がり、あとで前面に来ても何も読み直さなければ、既存ユーザーがずっとオンボのままになる。
    /// オンボーディングの操作中(プロフィール送信を始めたあと)は、いま作ったセッションを復元と取り違えない
    private func restoreSessionIfAvailable() -> Bool {
        guard
            phase == .onboarding,
            !isOnboardingUnderway,
            services.auth.currentUserID != nil
        else { return false }
        reloadFromStore()
        Task { await services.pushTokenSync.sessionDidChange() } // セッションが戻ったので、保留中の APNs 登録も促す
        return phase != .onboarding
    }

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

// MARK: - 同期の書き込み許可

/// アカウントの削除・サインアウトで端末の記録を消している間、同期の結果の書き込みを止める栓
/// (SnapshotSynchronizer.canApply が読む。init の途中で self を捕まえずに済むよう、参照型の小さな箱にしてある)
@MainActor
final class SyncGate {
    var isOpen = true
}

// MARK: - アカウント・ペアの操作(AccountOperating — issue #23)

extension AppModel: AccountOperating {
    /// 設定画面を開く(歯車)。ホームと、約束を決める前の画面で開ける(サインアウト・アカウントの削除に入れるように)。
    /// オンボーディング(アカウントを作る前)では開かない
    func presentSettings() {
        guard phase != .onboarding else { return }
        showsSettings = true
    }

    /// 現役のペアを解消する(= ブロック)。サーバーがソロの形の snapshot を返すので、端末の snapshot と
    /// ウィジェットを即座にソロへ更新する(相手には、サーバーがサイレントで知らせる)。冪等: すでにペアが
    /// 無くても成功し、端末はソロの形になる。失敗(通信など)は投げ、何も変えない
    func dissolvePair() async throws {
        guard let client = services.accountClient else { throw AccountClientError.unavailable }
        let snapshot = try await client.dissolvePair()
        try? services.store?.saveSnapshot(snapshot)
        services.reloadWidgets()
        reloadFromStore() // paired → solo(相手の写真の表示も消える)
        Task { await refresh() } // サーバーとも突き合わせる(未送信のチェックインが残っていれば上書きしない)
    }

    /// アカウントを削除する。サーバーの削除が成功してから、端末の記録を消してサインアウトし、オンボーディングへ戻る。
    /// サーバーの削除に失敗したときは投げ、端末は何も変えない(やり直せる)。
    /// 401 / user_not_found は成功とみなさない(認証サーバーの一時的な不調でも 401 になる。アカウントが残っているのに
    /// 端末の記録だけ消すと、削除できないまま戻れなくなる)
    func deleteAccount() async throws {
        guard let client = services.accountClient else { throw AccountClientError.unavailable }
        try await client.deleteAccount()
        await endSession(unregisterPush: false)
    }

    /// サインアウト: この端末のセッションを破棄し、端末の記録を消して、オンボーディングへ戻る。
    /// サーバー側のアカウントは残る(登録なしで始めたので、同じ記録には戻れない)。先に、この端末への push を止める
    func signOut() async {
        await endSession(unregisterPush: true)
    }

    /// 「ログイン状態を確認できません」の「あとで」: 何も消さずに、数え直す
    func dismissSessionLostPrompt() {
        sessionLost = false
        sessionMonitor.reset()
    }

    /// 「ログイン状態を確認できません」の「はじめからやり直す」: サインアウトして端末の記録を消し、オンボーディングへ戻る。
    /// セッションはもうサーバーに受け付けられないので、push の登録を外す通信は試みない
    func restartAfterSessionLost() async {
        sessionLost = false
        await endSession(unregisterPush: false)
    }

    /// 端末の後始末(アカウントの削除・サインアウト・セッション無効のあと):
    /// 走っている同期の完了を待ち → push の登録を外し(または端末の記録だけ捨て)→ サインアウト →
    /// App Group の記録(snapshot・未送信キュー・相手の写真のサムネ)を消す → ウィジェットを更新 → オンボーディングへ
    private func endSession(unregisterPush: Bool) async {
        guard !isEndingSession else { return }
        isEndingSession = true
        syncGate.isOpen = false // 走っている同期の結果は、書かずに捨てる
        rerunRequested = false
        var waited = 0
        while isRefreshing, waited < 100 { // 最大 5 秒
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }

        if unregisterPush {
            await services.pushTokenSync.unregister()
        } else {
            await services.pushTokenSync.forgetLocalRecord()
        }
        await services.auth.signOut()
        services.store?.eraseAll()

        sessionMonitor.reset()
        sessionLost = false
        pendingInviteToken = nil
        showsPairing = false
        showsSettings = false
        moderation.reset() // 開いていた通報・ブロックの確認を閉じる(次のアカウントに持ち越さない)
        isResolving = false
        services.reloadWidgets()
        reloadFromStore() // セッションが無いので onboarding

        syncGate.isOpen = true
        isEndingSession = false
    }
}
