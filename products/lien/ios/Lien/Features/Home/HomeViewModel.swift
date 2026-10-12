// HomeViewModel.swift — ホーム画面の状態管理(T13+T14 / REQUIREMENTS §3.4, §3.9, §3.10)
//
// - 状態の正はサーバー(DESIGN §3.3)。本 VM は App Group の PairSnapshot を読んで表示し、
//   チェックインは CheckinPerforming 経由で楽観反映 → saveSnapshot → ウィジェット reload する
// - 実 API+オフラインキューの実装は CheckinService(T14)。当日取消・写真添付・キュー再送は
//   注入された checkinService が各能力プロトコル(CheckinCanceling / PhotoAttaching /
//   PendingOpsFlushing — CheckinService.swift)に適合する場合のみ有効化する(as? で能力検出。
//   LocalEchoCheckinService 注入時は従来どおりチェックインのみ)
// - WidgetCenter.reloadAllTimelines はクロージャ注入(テストでは観測用に差し替え。
//   reload のトリガーはアプリ本体と NSE のみ — DESIGN §3.5)
// - 相手の今日の写真(PV #59)は PartnerPhotoModel が持つ。snapshot を表示用に読み直す/反映するたびに
//   snapshotDidChange で知らせる(取りに行くか・消すかはそちらが決める)。nil のとき(Stub 構成)は写真を扱わない

import Foundation
import Observation
import WidgetKit

// MARK: - チェックイン実行の抽象(本実装: CheckinService — T14)

protocol CheckinPerforming: AnyObject {
    /// 今日のチェックインを実行し、反映後の snapshot(受信者視点 — DESIGN §3.4)を返す
    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot
}

/// ローカルエコー実装: サーバーを呼ばず、楽観更新済みの snapshot をそのまま返す。
/// 本実装は CheckinService(T14。実 API+オフラインキュー)。本クラスは Config 未設定
/// (CI・Secrets なし)環境の場つなぎとして残す(AppServices の Stub 構成が使う — issue #55)。
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
    /// 当日取消の送信中(T14)
    private(set) var isCanceling = false
    /// 写真添付の処理中(縮小+アップロード — T14)
    private(set) var isAttachingPhoto = false
    /// チェックイン失敗時のユーザー向けメッセージ(リトライ可能。責めない文言 — §3.5)
    private(set) var checkinErrorMessage: String?
    /// 取消失敗時のメッセージ(責めない文言 — §3.5)
    private(set) var cancelErrorMessage: String?
    /// 写真添付失敗時のメッセージ(責めない文言 — §3.5)
    private(set) var photoErrorMessage: String?
    /// 写真添付が完了した直後の一言(同一セッション内の表示用)
    private(set) var photoAttachedNote: String?
    /// つつき送信中(T15)
    private(set) var isSendingNudge = false
    /// つつき失敗時のメッセージ(責めない文言 — §3.5)
    private(set) var nudgeErrorMessage: String?
    /// つつき送信が完了した直後の一言(同一セッション内の表示用)
    private(set) var nudgeSentNote: String?
    /// リアクション送信中(T15)
    private(set) var isSendingReaction = false
    /// リアクション失敗時のメッセージ(責めない文言 — §3.5)
    private(set) var reactionErrorMessage: String?
    /// リアクション送信が完了した直後の一言(同一セッション内の表示用)
    private(set) var reactionSentNote: String?

    // MARK: 依存(モック注入可能)

    private let store: AppGroupStore?
    private let checkinService: CheckinPerforming
    private let reloadWidgets: () -> Void

    /// 追加能力(T14)。checkinService が適合する場合のみ非 nil(能力検出)
    private let cancelService: CheckinCanceling?
    private let photoService: PhotoAttaching?
    private let opsFlusher: PendingOpsFlushing?
    /// 追加能力(T15 / issue #55)。明示注入があればそれを使い(Live 構成: LiveNudgeReactService)、
    /// 無ければ checkinService が適合する場合のみ非 nil(能力検出。Stub 構成は
    /// LocalEchoCheckinService のモック適合 — NudgeReactService.swift)
    private let nudgeService: NudgeSending?
    private let reactionService: Reacting?

    /// 相手の今日の写真(PV #59。ホームのカードと、タップで開く全画面)。nil のときは写真を扱わない
    let partnerPhoto: PartnerPhotoModel?

    init(
        store: AppGroupStore?,
        checkinService: CheckinPerforming,
        nudgeService: NudgeSending? = nil,
        reactionService: Reacting? = nil,
        partnerPhoto: PartnerPhotoModel? = nil,
        reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.store = store
        self.checkinService = checkinService
        self.partnerPhoto = partnerPhoto
        self.reloadWidgets = reloadWidgets
        self.cancelService = checkinService as? CheckinCanceling
        self.photoService = checkinService as? PhotoAttaching
        self.opsFlusher = checkinService as? PendingOpsFlushing
        self.nudgeService = nudgeService ?? (checkinService as? NudgeSending)
        self.reactionService = reactionService ?? (checkinService as? Reacting)
    }

    // MARK: 読み込み

    /// App Group から snapshot を読み直す(onAppear / フォアグラウンド復帰時 / AppModel の同期完了時)。
    /// 未送信キューの再送は flushPendingOps(T14)。サーバーとの能動的な再同期
    /// (GET /snapshot)は AppModel / SnapshotSynchronizer が行い、結果は App Group 経由で届く
    func load() {
        snapshot = store?.loadSnapshot()
        partnerPhoto?.snapshotDidChange(snapshot)
    }

    // MARK: 表示分岐(REQUIREMENTS §3.9 / §3.10)

    /// ソロ状態(ペア未成立 = pairId が null)。鉢は土だけ+誘導文言の最小表示(§3.9)
    var isSolo: Bool {
        guard let snapshot else { return false }
        return snapshot.pairId == nil
    }

    /// 植物の描画状態(GROWTH §4.1 の表。snapshot → PlantCharacterState。重ねるレイヤーは PlantLayers が決める)。
    /// ソロ(pairId が null)と snapshot 未取得は、鉢の土の中で眠る姿
    var plantState: PlantCharacterState {
        guard let snapshot else { return .solo }
        return PlantCharacterState(snapshot: snapshot)
    }

    /// fidget(片方だけ完了のそわそわ)は View 側の小さな揺れで表す(REQUIREMENTS §3.9)。
    /// 葉の開閉と視線は plantState が表すので、揺れは付け足し
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
        return !snapshot.todayMeDone && !isBusy
    }

    /// 当日取消の導線を出すか(完了済み+取消能力あり — §3.4 / T14)
    var canCancelCheckin: Bool {
        guard let snapshot, cancelService != nil else { return false }
        return snapshot.todayMeDone && !isBusy
    }

    /// 「写真を添える」を出すか(完了済み+写真能力あり+ペア成立 — §3.4 / DESIGN §5.6。
    /// ソロは写真の置き場所が無いため出さない)
    var canAttachPhoto: Bool {
        guard let snapshot, photoService != nil else { return false }
        return snapshot.todayMeDone && snapshot.pairId != nil && !isBusy
    }

    /// つつくボタンを出すか(ペア成立+相手が未完のときだけ押せる — REQUIREMENTS §3.7)。
    /// 1日3回の上限はクライアントでは数えない(サーバー正本 — functions/nudge/core.ts。
    /// 超過時はサーバー応答 429 を nudgeErrorMessage で表示する)
    var canNudge: Bool {
        guard let snapshot, nudgeService != nil, snapshot.pairId != nil else { return false }
        return !snapshot.todayPartnerDone && !isBusy
    }

    /// リアクション導線を出すか(ペア成立+相手が今日チェックイン済み — REQUIREMENTS §3.8)
    var canReact: Bool {
        guard let snapshot, reactionService != nil, snapshot.pairId != nil else { return false }
        return snapshot.todayPartnerDone && !isBusy
    }

    private var isBusy: Bool {
        isCheckingIn || isCanceling || isAttachingPhoto || isSendingNudge || isSendingReaction
    }

    // MARK: チェックイン(楽観反映。実 API+オフラインキューは CheckinService — T14)

    func performCheckin() async {
        guard canCheckin, let current = snapshot else { return }
        isCheckingIn = true
        clearMessages()
        defer { isCheckingIn = false }
        do {
            let updated = try await checkinService.performCheckin(current: current)
            apply(updated)
        } catch {
            checkinErrorMessage = Strings.Home.checkinErrorMessage
        }
    }

    // MARK: 当日取消(誤タップ対応 — §3.4。責めない文言 / T14)

    func performCancel() async {
        guard canCancelCheckin, let current = snapshot, let cancelService else { return }
        isCanceling = true
        clearMessages()
        defer { isCanceling = false }
        do {
            let updated = try await cancelService.cancelCheckin(current: current)
            apply(updated)
        } catch {
            cancelErrorMessage = Strings.Checkin.cancelErrorMessage
        }
    }

    // MARK: 写真添付(完了後・任意・その日1枚 — §3.4 / DESIGN §5.6 / T14)

    func attachPhoto(_ imageData: Data) async {
        guard canAttachPhoto, let current = snapshot, let photoService else { return }
        isAttachingPhoto = true
        clearMessages()
        defer { isAttachingPhoto = false }
        do {
            let updated = try await photoService.attachPhoto(current: current, imageData: imageData)
            apply(updated)
            photoAttachedNote = Strings.Checkin.attachPhotoDoneNote
        } catch {
            photoErrorMessage = Strings.Checkin.attachPhotoErrorMessage
        }
    }

    // MARK: つつく(REQUIREMENTS §3.7 / T15)

    func sendNudge(stamp: NudgeStamp) async {
        guard canNudge, let nudgeService else { return }
        isSendingNudge = true
        clearMessages()
        defer { isSendingNudge = false }
        do {
            try await nudgeService.sendNudge(stamp: stamp)
            nudgeSentNote = Strings.Nudge.sentNote
        } catch NudgeSendError.limitReached {
            nudgeErrorMessage = Strings.Nudge.limitReachedMessage
        } catch {
            nudgeErrorMessage = Strings.Nudge.errorMessage
        }
    }

    // MARK: リアクション(REQUIREMENTS §3.8 / T15)

    func sendReaction(stamp: ReactionStamp) async {
        guard canReact, let reactionService else { return }
        isSendingReaction = true
        clearMessages()
        defer { isSendingReaction = false }
        do {
            try await reactionService.sendReaction(stamp: stamp)
            reactionSentNote = Strings.Reaction.sentNote
        } catch {
            reactionErrorMessage = Strings.Reaction.errorMessage
        }
    }

    // MARK: 未送信キューの再送(起動時+フォアグラウンド復帰時 — DESIGN §3.7 / T14)

    func flushPendingOps() async {
        guard let opsFlusher, !isBusy else { return }
        if let server = await opsFlusher.flushPendingOps() {
            apply(server)
        }
    }

    // MARK: private

    /// 新しい snapshot を画面+App Group に反映し、ウィジェットを reload する。
    /// 保存失敗でも画面表示は更新済みのまま続行(フォアグラウンド復帰時の
    /// GET /snapshot で自己修復する設計 — DESIGN §4)
    private func apply(_ updated: PairSnapshot) {
        snapshot = updated
        try? store?.saveSnapshot(updated)
        reloadWidgets()
        partnerPhoto?.snapshotDidChange(updated)
    }

    private func clearMessages() {
        checkinErrorMessage = nil
        cancelErrorMessage = nil
        photoErrorMessage = nil
        photoAttachedNote = nil
        nudgeErrorMessage = nil
        nudgeSentNote = nil
        reactionErrorMessage = nil
        reactionSentNote = nil
    }
}
