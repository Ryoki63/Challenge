// CheckinService.swift — チェックインフローの本実装(T14 / REQUIREMENTS §3.4 / DESIGN §3.7, §5.6)
//
// T13 の LocalEchoCheckinService(その場つなぎ)を置き換える CheckinPerforming 実装。
// 役割: 楽観更新 → オフラインキュー(PendingOpsQueue)→ 実 API(CheckinAPIClient)送信。
//
// 方針:
//   - 操作はまずキューに積んでから送る(送信中のクラッシュでも操作が失われない — DESIGN §3.7)
//   - 通信エラー(オフライン)は **成功扱い** で楽観 snapshot を返す(チェックインは
//     オフラインで動作 — REQUIREMENTS §4。再送は起動時+フォアグラウンド復帰時の flush)
//   - 4xx 等の拒否応答は op を破棄して throw(再送しても結果は変わらない。表示の自己修復は
//     フォアグラウンド復帰時の snapshot 再同期 — DESIGN §4)
//   - 成功時はサーバー snapshot が正(楽観値を上書き)。保存+ウィジェット reload は
//     HomeViewModel の責務(CheckinPerforming 契約 — T13)
//   - 写真はオンライン専用(バイナリをキューに持たない — シンプル優先)。失敗はそのまま
//     throw してユーザーの再試行に委ねる
//
// アプリへの結線(LienApp.swift の LocalEchoCheckinService → CheckinService 差し替え)は
// 本タスクでは行わない(T13 競合回避 — issue #14。close 時に残作業として明記)。

import Foundation

// MARK: - 追加能力の抽象(HomeViewModel は checkinService as? で能力検出する)

/// 当日チェックインの取消(REQUIREMENTS §3.4「取り消しは当日中のみ可」)
protocol CheckinCanceling: AnyObject {
    /// 今日のチェックインを取り消し、反映後の snapshot を返す
    func cancelCheckin(current: PairSnapshot) async throws -> PairSnapshot
}

/// 写真添付(REQUIREMENTS §3.4「完了後に写真を添える」/ DESIGN §5.6)
protocol PhotoAttaching: AnyObject {
    /// 今日のチェックインに写真を添え、反映後の snapshot を返す。
    /// imageData は元画像(縮小は実装側 = PhotoProcessor の責務)
    func attachPhoto(current: PairSnapshot, imageData: Data) async throws -> PairSnapshot
}

/// 未送信キューの再送口(アプリ起動時+フォアグラウンド復帰時 — DESIGN §3.7)
protocol PendingOpsFlushing: AnyObject {
    /// キューを順に送信し、最後に得たサーバー snapshot を返す(何も送れなければ nil)
    func flushPendingOps() async -> PairSnapshot?
}

// MARK: - 本実装

final class CheckinService: CheckinPerforming, CheckinCanceling, PhotoAttaching, PendingOpsFlushing {
    private let api: CheckinAPIClient
    private let queue: PendingOpsQueue
    private let now: () -> Date
    private let calendar: Calendar
    /// 写真縮小(テストでは軽量スタブに差し替え)。CPU バウンドなので Task.detached で呼ぶ
    private let processPhoto: @Sendable (Data) throws -> ProcessedPhoto

    init(
        api: CheckinAPIClient,
        queue: PendingOpsQueue,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        processPhoto: @escaping @Sendable (Data) throws -> ProcessedPhoto = PhotoProcessor.process
    ) {
        self.api = api
        self.queue = queue
        self.now = now
        self.calendar = calendar
        self.processPhoto = processPhoto
    }

    // MARK: CheckinPerforming(T13 契約を維持)

    func performCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        let today = todayLocal()
        let optimistic = optimisticCheckin(from: current)

        // 先に積んでから送る(送信成功直後のクラッシュでも再送は冪等 200 で安全 — DESIGN §5.5)。
        // 同日 op とのマージで photoPath が昇格しうるため、以降の照合は「今日の checkin」で行う
        queue.enqueue(.checkin(dateLocal: today, photoPath: nil))

        let result = await drainQueue()
        if let rejection = result.rejections.first(where: { $0.op.isCheckin && $0.op.dateLocal == today }) {
            // サーバーが拒否(409 no_promise 等)。楽観値を返さず VM にエラー表示させる
            throw rejection.error
        }
        if queue.containsCheckin(dateLocal: today) {
            // オフライン: キュー残存のまま完了扱い(REQUIREMENTS §3.4 オフライン記録)
            return optimistic
        }
        // 成功: FIFO 送信で自分の op が最後 → lastSnapshot は自分の応答
        return result.lastSnapshot ?? optimistic
    }

    // MARK: CheckinCanceling

    func cancelCheckin(current: PairSnapshot) async throws -> PairSnapshot {
        let today = todayLocal()
        let optimistic = optimisticCancel(from: current)

        // 相殺判定: 未送信の checkin(今日)が積まれていれば enqueue が両方消す
        // (サーバーは元から未記録なので何も送らなくてよい — PendingOps.swift)
        let offsetsPendingCheckin = queue.containsCheckin(dateLocal: today)
        let op = PendingOp.checkinCancel(dateLocal: today)
        queue.enqueue(op)
        if offsetsPendingCheckin {
            return optimistic
        }

        let result = await drainQueue()
        if let rejection = result.rejections.first(where: { $0.op == op }) {
            throw rejection.error
        }
        if queue.contains(op) {
            return optimistic // オフライン: 再送待ち(日付が変わると 400 で破棄 → snapshot 自己修復)
        }
        return result.lastSnapshot ?? optimistic
    }

    // MARK: PhotoAttaching

    func attachPhoto(current: PairSnapshot, imageData: Data) async throws -> PairSnapshot {
        // ソロは写真の置き場所(ペア)が無い(DESIGN §5.6。サーバーも 400 no_pair を返す)
        guard current.pairId != nil else { throw CheckinClientError.noPair }
        let today = todayLocal()

        // 1. 縮小(原寸 2048px+サムネ 200KB 以下 — NSE 契約)。メインスレッドを塞がない
        let process = processPhoto
        let processed = try await Task.detached(priority: .userInitiated) {
            try process(imageData)
        }.value

        // 2. 署名付きアップロードURLの取得(チェックイン未了ならここで同時に記録される)
        let issued = try await api.checkin(dateLocal: today, photoPath: nil, requestPhotoUpload: true)
        guard let upload = issued.photoUpload else {
            throw CheckinClientError.server(code: "missing_photo_upload")
        }

        // 3. 原寸+サムネをアップロード → photoPath 付きで再送(行に記録+相手へ photo push)
        try await api.uploadPhoto(processed.photo, to: upload.photo)
        try await api.uploadPhoto(processed.thumb, to: upload.thumb)
        let final = try await api.checkin(
            dateLocal: today,
            photoPath: upload.photo.path,
            requestPhotoUpload: false
        )
        return final.snapshot
    }

    // MARK: PendingOpsFlushing

    func flushPendingOps() async -> PairSnapshot? {
        await drainQueue().lastSnapshot
    }

    // MARK: - 楽観更新(LocalEchoCheckinService と同方針: ストリーク数は触らない — DESIGN §5.4)

    private func optimisticCheckin(from current: PairSnapshot) -> PairSnapshot {
        var updated = current
        updated.todayMeDone = true
        // 両者完了なら「ふたり達成!」(REQUIREMENTS §3.4)。片方未完の表情はサーバーに委ねる
        if updated.todayPartnerDone {
            updated.plantMood = .happy
        }
        updated.updatedAt = now()
        return updated
    }

    private func optimisticCancel(from current: PairSnapshot) -> PairSnapshot {
        var updated = current
        updated.todayMeDone = false
        // 「ふたり達成」状態からの取消だけ表情を戻す(それ以外はサーバーの判断を保持)
        if updated.plantMood == .happy {
            updated.plantMood = updated.todayPartnerDone ? .fidget : .normal
        }
        updated.updatedAt = now()
        return updated
    }

    // MARK: - キュー送信

    private struct DrainResult {
        var lastSnapshot: PairSnapshot?
        var rejections: [(op: PendingOp, error: CheckinClientError)] = []
    }

    /// キューを FIFO で送信する。
    /// - 成功: op を取り除き snapshot を記録
    /// - 通信エラー: 中断してキュー残存(再送は次回 flush — DESIGN §3.7)
    /// - 拒否応答(4xx 等): op を破棄して続行(再送しても結果不変。記録して呼び出し元が判断)
    private func drainQueue() async -> DrainResult {
        var result = DrainResult()
        var remaining = queue.load()
        while let op = remaining.first {
            do {
                result.lastSnapshot = try await send(op)
                remaining.removeFirst()
                queue.replaceAll(remaining)
            } catch let error as CheckinClientError where !error.isRetryable {
                result.rejections.append((op, error))
                remaining.removeFirst()
                queue.replaceAll(remaining)
            } catch {
                break // 通信エラー(または不明エラー)は再送対象として残す
            }
        }
        return result
    }

    private func send(_ op: PendingOp) async throws -> PairSnapshot {
        switch op {
        case .checkin(let dateLocal, let photoPath):
            return try await api.checkin(
                dateLocal: dateLocal,
                photoPath: photoPath,
                requestPhotoUpload: false
            ).snapshot
        case .checkinCancel(let dateLocal):
            return try await api.cancelCheckin(dateLocal: dateLocal).snapshot
        }
    }

    // MARK: - 日付

    private func todayLocal() -> String {
        DayBoundary.dateLocalString(for: now(), calendar: calendar)
    }
}

// MARK: - date_local 文字列(端末ローカルTZ。サーバーの date_local "YYYY-MM-DD" と同形式)

extension DayBoundary {
    /// `date` が属するローカル日を "YYYY-MM-DD" で返す(checkin / checkin-cancel の dateLocal)。
    /// タイムゾーンは `calendar`(既定: 端末ローカル)から取るが、年月日は**グレゴリオ暦で固定**する
    /// (端末の暦設定が和暦・仏暦でも date_local の契約はグレゴリオ暦 — DESIGN §9 / streak.ts)
    static func dateLocalString(for date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }
}
