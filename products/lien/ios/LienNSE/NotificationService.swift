// NotificationService.swift — Notification Service Extension 本実装の骨格(T07。DESIGN §4)
//
// パイプライン(DESIGN §4):
//   可視プッシュ(mutable-content: 1)の userInfo["lien"]["snapshot"](受信者視点の PairSnapshot)を
//   App Group の pair_snapshot.json へ書き込み → WidgetCenter.reloadAllTimelines() → 通知をそのまま表示。
//   (T16 #16)その snapshot が「今日の分のローカル通知はもう要らない」ことを示すとき(ふたりそろった = 夜 9 時のストリーク危機)は、
//   本体のアプリが予約しているローカル通知の取り消しを試みる(LocalNotificationCancellation — アプリの同期と共通の規則)。
//   **NSE が本体のアプリの予約を消せるかは実機でしか確かめられず、まだ確かめていない**(T20。ios/README.md §12)。
//   消せなかったときのふるまいは ReminderScheduler.swift の冒頭と ReminderSchedulerLearningTests に書いてある
//   (予約が残るので夜 9 時に届くが、文言はそのとき読んで困らない / 前面なら捨てる / 次に開いたときの同期で消す)。
//
// 制約(DESIGN §10): NSE は実行30秒・メモリ約24MB。
//   - snapshot の書き込み(数KB)と reload は軽量なのでこの制約には十分収まる
//   - T17 で追加する写真サムネ DL は 200KB 上限+失敗時フォールバックでこの制約を守る
//   - ローカル通知の取り消しは、通知センターへの数回の呼び出し(軽量)。取り消しがシステムに届くのを待ってから通知を出すが、
//     待てなくても 30 秒の期限(serviceExtensionTimeWillExpire)で必ず通知を出す
//
// 方針: 書き込み失敗・snapshot 欠落・取り消し失敗でも**通知表示は絶対に止めない**(通知消失の防止)。
// snapshot の取りこぼしは、アプリ本体がフォアグラウンド復帰時に GET /snapshot で自己修復する(DESIGN §4)。

import UserNotifications
import WidgetKit

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var originalContent: UNNotificationContent?

    /// 通知を出す(contentHandler を呼ぶ)のは 1 回だけ。取り消しの完了待ちと時間切れが重なっても、二重に呼ばない
    private let deliveryLock = NSLock()
    private var hasDelivered = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        originalContent = request.content
        let bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent
        self.bestAttemptContent = bestAttemptContent

        let snapshot = updateSharedSnapshot(from: request.content.userInfo)

        // TODO(T17): snapshot.hasPartnerPhotoToday の場合に photo_thumb.jpg を DL して
        //            通知添付+App Group へ保存(200KB 上限・失敗時は植物表示にフォールバック — DESIGN §3.4)

        // 通知はそのまま表示する(本文の組み立てはサーバー側 messages.ts の責務 — DESIGN §5.3)。
        // 今日のローカル通知を取り消す必要があるときだけ、取り消しの完了を待ってから出す
        dismissStaleLocalNotifications(for: snapshot) { [weak self] in
            self?.deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // 時間切れ(30秒)時は加工途中でも必ず通知を出す(通知消失の防止)
        deliver()
    }

    private func deliver() {
        deliveryLock.lock()
        let handler = hasDelivered ? nil : contentHandler
        hasDelivered = true
        deliveryLock.unlock()
        guard let handler, let content = bestAttemptContent ?? originalContent else { return }
        handler(content)
    }

    /// userInfo["lien"]["snapshot"] を検証付きで App Group へ書き、ウィジェットを reload する。
    /// 書けた snapshot を返す(欠落・検証失敗は nil)。失敗しても通知表示を優先して握りつぶす(自己修復前提 — DESIGN §4)
    private func updateSharedSnapshot(from userInfo: [AnyHashable: Any]) -> PairSnapshot? {
        guard
            let lien = userInfo["lien"] as? [String: Any],
            let snapshotObject = lien["snapshot"],
            JSONSerialization.isValidJSONObject(snapshotObject),
            let data = try? JSONSerialization.data(withJSONObject: snapshotObject),
            let store = AppGroupStore.standard()
        else { return nil }

        do {
            // saveSnapshotData はデコード検証付き: 壊れたペイロードで正常な snapshot を潰さない
            let snapshot = try store.saveSnapshotData(data)
            // reload のトリガーは NSE とアプリ本体のみ(WidgetKit の reload 予算 — DESIGN §3.5)
            WidgetCenter.shared.reloadAllTimelines()
            return snapshot
        } catch {
            // 書き込み・検証失敗時も通知は表示する(上の呼び出し側が deliver する)
            return nil
        }
    }

    /// 本体のアプリが予約している今日のローカル通知のうち、受け取った snapshot から見て「もう出さなくてよい」ものを取り消す
    /// (ふたりそろったら、夜 9 時のストリーク危機。自分が完了していれば、リマインド)。通知センターに既に出ているものも外す。
    /// 取り消しの要求のあとに予約の一覧を読み、その応答が返ってから completion を呼ぶ(同じ接続の応答なので、
    /// それ以前の取り消しはシステムに届いている)。取り消すものが無いときは、すぐ completion を呼ぶ(通知を遅らせない)
    private func dismissStaleLocalNotifications(for snapshot: PairSnapshot?, completion: @escaping () -> Void) {
        guard let snapshot else {
            completion()
            return
        }
        let identifiers = LocalNotificationCancellation.staleIDsForToday(
            snapshot: snapshot,
            now: Date(),
            calendar: LocalNotificationCalendar.current()
        )
        guard !identifiers.isEmpty else {
            completion()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.getPendingNotificationRequests { _ in completion() }
    }
}
