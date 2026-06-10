// NotificationService.swift — Notification Service Extension 本実装の骨格(T07。DESIGN §4)
//
// パイプライン(DESIGN §4):
//   可視プッシュ(mutable-content: 1)の userInfo["lien"]["snapshot"](受信者視点の PairSnapshot)を
//   App Group の pair_snapshot.json へ書き込み → WidgetCenter.reloadAllTimelines() → 通知をそのまま表示。
//
// 制約(DESIGN §10): NSE は実行30秒・メモリ約24MB。
//   - snapshot の書き込み(数KB)と reload は軽量なのでこの制約には十分収まる
//   - T17 で追加する写真サムネ DL は 200KB 上限+失敗時フォールバックでこの制約を守る
//
// 方針: 書き込み失敗・snapshot 欠落でも**通知表示は絶対に止めない**(通知消失の防止)。
// snapshot の取りこぼしは、アプリ本体がフォアグラウンド復帰時に GET /snapshot で自己修復する(DESIGN §4)。

import UserNotifications
import WidgetKit

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent
        self.bestAttemptContent = bestAttemptContent

        updateSharedSnapshot(from: request.content.userInfo)

        // TODO(T17): snapshot.hasPartnerPhotoToday の場合に photo_thumb.jpg を DL して
        //            通知添付+App Group へ保存(200KB 上限・失敗時は植物表示にフォールバック — DESIGN §3.4)

        // 通知はそのまま表示する(本文の組み立てはサーバー側 messages.ts の責務 — DESIGN §5.3)
        contentHandler(bestAttemptContent ?? request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        // 時間切れ(30秒)時は加工途中でも必ず通知を出す(通知消失の防止)
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    /// userInfo["lien"]["snapshot"] を検証付きで App Group へ書き、ウィジェットを reload する。
    /// 失敗しても通知表示を優先して握りつぶす(自己修復前提 — DESIGN §4)
    private func updateSharedSnapshot(from userInfo: [AnyHashable: Any]) {
        guard
            let lien = userInfo["lien"] as? [String: Any],
            let snapshotObject = lien["snapshot"],
            JSONSerialization.isValidJSONObject(snapshotObject),
            let data = try? JSONSerialization.data(withJSONObject: snapshotObject),
            let store = AppGroupStore.standard()
        else { return }

        do {
            // saveSnapshotData はデコード検証付き: 壊れたペイロードで正常な snapshot を潰さない
            try store.saveSnapshotData(data)
            // reload のトリガーは NSE とアプリ本体のみ(WidgetKit の reload 予算 — DESIGN §3.5)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // 書き込み・検証失敗時も通知は表示する(上の contentHandler 呼び出しに委ねる)
        }
    }
}
