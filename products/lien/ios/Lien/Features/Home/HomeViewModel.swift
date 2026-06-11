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
/// (CI・Secrets なし)環境の場つなぎとして残す(LienApp.swift の結線が参照 — 差し替えは後続の数行)。
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

    // MARK: 依存(モック注入可能)

    private let store: AppGroupStore?
    private let checkinService: CheckinPerforming
    private let reloadWidgets: () -> Void

    /// 追加能力(T14)。checkinService が適合する場合のみ非 nil(能力検出)
    private let cancelService: CheckinCanceling?
    private let photoService: PhotoAttaching?
    private let opsFlusher: PendingOpsFlushing?

    init(
        store: AppGroupStore?,
        checkinService: CheckinPerforming,
        reloadWidgets: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.store = store
        self.checkinService = checkinService
        self.reloadWidgets = reloadWidgets
        self.cancelService = checkinService as? CheckinCanceling
        self.photoService = checkinService as? PhotoAttaching
        self.opsFlusher = checkinService as? PendingOpsFlushing
    }

    // MARK: 読み込み

    /// App Group から snapshot を読み直す(onAppear / フォアグラウンド復帰時)。
    /// 未送信キューの再送は flushPendingOps(T14)。サーバーとの能動的な再同期
    /// (GET /snapshot)はスナップショット同期の後続タスクの責務
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

    private var isBusy: Bool {
        isCheckingIn || isCanceling || isAttachingPhoto
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
    }

    private func clearMessages() {
        checkinErrorMessage = nil
        cancelErrorMessage = nil
        photoErrorMessage = nil
        photoAttachedNote = nil
    }
}
