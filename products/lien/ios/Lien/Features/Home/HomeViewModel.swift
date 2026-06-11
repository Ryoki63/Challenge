// HomeViewModel.swift — ホーム画面の状態管理(T13 / REQUIREMENTS §3.4, §3.9, §3.10)
//
// - 状態の正はサーバー(DESIGN §3.3)。本 VM は App Group の PairSnapshot を読んで表示し、
//   チェックインは CheckinPerforming 経由で楽観反映 → saveSnapshot → ウィジェット reload する
// - CheckinPerforming の実装は T13 ではローカルエコー(LocalEchoCheckinService)。
//   実 API(POST /checkin)+オフラインキュー(pending_ops.json — DESIGN §3.7)+写真添付+
//   当日取消は **T14 で差し替える**
// - WidgetCenter.reloadAllTimelines はクロージャ注入(テストでは観測用に差し替え。
//   reload のトリガーはアプリ本体と NSE のみ — DESIGN §3.5)

import Foundation
import Observation
import WidgetKit

// MARK: - チェックイン実行の抽象(T13: ローカルエコー / T14: 実 API に差し替え)

protocol CheckinPerforming: AnyObject {
    /// 今日のチェックインを実行し、反映後の snapshot(受信者視点 — DESIGN §3.4)を返す
    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot
}

/// ローカルエコー実装: サーバーを呼ばず、楽観更新済みの snapshot をそのまま返す。
/// **T14 で実 API 実装(オフラインキュー込み)に差し替える**(本クラスはその場つなぎ)。
/// ストリーク数は触らない(確定はサーバーのアルゴリズムが正 — DESIGN §5.4)
final class LocalEchoCheckinService: CheckinPerforming {
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        var updated = current
        updated.todayMeDone = true
        // 両者完了なら「ふたり達成!」のキラキラ(REQUIREMENTS §3.4 / §3.9)。
        // 片方未完(=相手待ち)の表情はサーバー側の判断に委ね、ここでは変えない
        if updated.todayPartnerDone {
            updated.plantMood = .happy
        }
        updated.updatedAt = now()
        return updated
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class HomeViewModel {
    // MARK: 画面状態

    /// 表示中の snapshot(nil = 未取得の空状態)
    private(set) var snapshot: PairSnapshot?
    private(set) var isCheckingIn = false
    /// チェックイン失敗時のユーザー向けメッセージ(リトライ可能。責めない文言 — §3.5)
    private(set) var checkinErrorMessage: String?

    // MARK: 依存(モック注入可能)

    private let store: AppGroupStore?
    private let checkinService: CheckinPerforming
    private let reloadWidgets: () -> Void

    init(
        store: AppGroupStore?,
        checkinService: CheckinPerforming,
        reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.store = store
        self.checkinService = checkinService
        self.reloadWidgets = reloadWidgets
    }

    // MARK: 読み込み

    /// App Group から snapshot を読み直す(onAppear / フォアグラウンド復帰時)。
    /// サーバーとの再同期(GET /snapshot)は T14 の責務
    func load() {
        snapshot = store?.loadSnapshot()
    }

    // MARK: 表示分岐(REQUIREMENTS §3.9 / §3.10)

    /// ソロ状態(ペア未成立 = pairId が null)。鉢は土だけ+誘導文言の最小表示(§3.9)
    var isSolo: Bool {
        guard let snapshot else { return false }
        return snapshot.pairId == nil
    }

    /// 植物の imageset 名。解決規則は PlantSprite が正本(ソロ・未取得は土)
    var plantAssetName: String {
        guard let snapshot, snapshot.pairId != nil else { return PlantSprite.soloAssetName }
        return PlantSprite.assetName(stage: snapshot.plantStage, mood: snapshot.plantMood)
    }

    /// fidget(そわそわ)は v0 では normal 画像+View 側の揺れアニメで表現(mapping.md)
    var plantSways: Bool {
        snapshot?.plantMood == .fidget
    }

    /// ストリーク行はペア成立中のみ(ふたりストリークはペアのもの — §3.5)
    var showsStreak: Bool {
        guard let snapshot else { return false }
        return snapshot.pairId != nil
    }

    /// 相手が先に完了 →「(名前)が待ってるよ」(REQUIREMENTS §3.10 表示原則)
    var partnerWaitingText: String? {
        guard
            let snapshot, snapshot.pairId != nil,
            snapshot.todayPartnerDone, !snapshot.todayMeDone,
            let partnerName = snapshot.partnerName
        else { return nil }
        return Strings.Home.partnerWaiting(partnerName)
    }

    /// 両者完了の「ふたり達成!」演出(REQUIREMENTS §3.4)
    var showsBothDoneCelebration: Bool {
        guard let snapshot, snapshot.pairId != nil else { return false }
        return snapshot.todayMeDone && snapshot.todayPartnerDone
    }

    /// チェックイン可否。1日1回(完了済みは押せない — §3.4)。
    /// ソロ状態でもチェックインは可能(招待待ちでも使える — §3.2)
    var canCheckin: Bool {
        guard let snapshot else { return false }
        return !snapshot.todayMeDone && !isCheckingIn
    }

    // MARK: チェックイン(楽観反映。オフラインキュー・写真・当日取消は T14)

    func performCheckin() async {
        guard canCheckin, let current = snapshot else { return }
        isCheckingIn = true
        checkinErrorMessage = nil
        defer { isCheckingIn = false }
        do {
            let updated = try await checkinService.performCheckin(current: current)
            snapshot = updated
            // 保存失敗でも画面表示は更新済みのまま続行(フォアグラウンド復帰時の
            // GET /snapshot で自己修復する設計 — DESIGN §4)
            try? store?.saveSnapshot(updated)
            reloadWidgets()
        } catch {
            checkinErrorMessage = Strings.Home.checkinErrorMessage
        }
    }
}
