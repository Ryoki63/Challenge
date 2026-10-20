// NotificationService.swift — Notification Service Extension 本実装の骨格(T07。DESIGN §4)
//
// パイプライン(DESIGN §4):
//   可視プッシュ(mutable-content: 1)の userInfo["lien"]["snapshot"](受信者視点の PairSnapshot)を
//   App Group の pair_snapshot.json へ書き込み → WidgetCenter.reloadAllTimelines() → 通知をそのまま表示。
//   (T16 #16)その snapshot に、端末のローカル通知(リマインド・夜 9 時のストリーク危機)を合わせる
//   (LocalNotificationPushSync — アプリの同期と同じ計画 StreakRiskPlan。足りなければ足し、古ければ消す):
//     - ふたりそろった / お休みチケットで守られた / ストリークが途切れた … 夜 9 時の分を、アプリを開かなくても合わせる
//       (アプリの同期だけだと、アプリを開かない日の夜 9 時の通知が無い)
//     - 自分が済んでいる … 今日のリマインドを取り消す
//   **NSE が本体のアプリの予約を読み・消し・足せるかは実機でしか確かめられず、まだ確かめていない**(T20。ios/README.md §12)。
//   できなかったときのふるまいは ReminderScheduler.swift の冒頭と ReminderSchedulerLearningTests に書いてある
//   (足せなかった分は次に開いたときの同期で足される / 消せなかった分は夜 9 時に届くが、文言はそのとき読んで困らない /
//   前面なら捨てる / 次に開いたときの同期で消す)。
//
// 制約(DESIGN §10): NSE は実行30秒・メモリ約24MB。
//   - snapshot の書き込み(数KB)と reload は軽量なのでこの制約には十分収まる
//   - T17 で追加する写真サムネ DL は 200KB 上限+失敗時フォールバックでこの制約を守る
//   - ローカル通知の合わせ込みは、通知センターへの数回の呼び出し(軽量)。システムに届くのを待ってから通知を出すが、
//     待てなくても 30 秒の期限(serviceExtensionTimeWillExpire)で必ず通知を出す
//
// 方針: 書き込み失敗・snapshot 欠落・合わせ込みの失敗でも**通知表示は絶対に止めない**(通知消失の防止)。
// snapshot の取りこぼしは、アプリ本体がフォアグラウンド復帰時に GET /snapshot で自己修復する(DESIGN §4)。

import UserNotifications
import WidgetKit

/// 通知を出す(contentHandler を呼ぶ)のは deliveryGate で 1 回に絞る。そのほかの状態は didReceive で一度だけ書き、
/// 以降は読むだけなので、別のスレッド(ローカル通知の合わせ込みの完了・時間切れ)から deliver を呼んでよい
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var originalContent: UNNotificationContent?

    /// 通知を出す(contentHandler を呼ぶ)のは 1 回だけ。ローカル通知の合わせ込みの完了待ちと時間切れが重なっても、二重に呼ばない
    private let deliveryGate = NotificationDeliveryGate()

    /// ローカル通知の合わせ込みを待つ最長の時間(秒)。通常は数十ミリ秒。通知センターの応答が遅いときも、
    /// 相手の通知をこれ以上遅らせない(30 秒の期限まで待たない)
    static let alignTimeout: TimeInterval = 4

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
        // 端末のローカル通知を snapshot に合わせてから(システムに届くのを待ってから)出す
        alignLocalNotifications(with: snapshot) { [weak self] in
            self?.deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // 時間切れ(30秒)時は加工途中でも必ず通知を出す(通知消失の防止)
        deliver()
    }

    private func deliver() {
        guard deliveryGate.claim(), let handler = contentHandler,
              let content = bestAttemptContent ?? originalContent else { return }
        handler(content)
    }

    /// userInfo["lien"]["snapshot"] を検証付きで App Group へ書き、ウィジェットを reload する。
    /// 書けた snapshot を返す(欠落・検証失敗は nil)。失敗しても通知表示を優先して握りつぶす(自己修復前提 — DESIGN §4)
    private func updateSharedSnapshot(from userInfo: [AnyHashable: Any]) -> PairSnapshot? {
        guard let store = AppGroupStore.standard() else { return nil }

        do {
            return try PushSnapshotWriter(store: store, reloadWidgets: {
                WidgetCenter.shared.reloadAllTimelines()
            }).receive(userInfo)
        } catch {
            // 書き込み・検証失敗時も通知は表示する(上の呼び出し側が deliver する)
            return nil
        }
    }

    /// 端末のローカル通知(本体のアプリが予約している夜 9 時のストリーク危機と今日のリマインド)を、受け取った snapshot に合わせる
    /// (LocalNotificationPushSync。アプリの同期と同じ計画・同じ規則)。通知センターに既に出ているものも外す。
    /// 取り消しと追加の要求のあとに予約の一覧を読み、その応答が返ってから completion を呼ぶ(同じ接続の応答なので、
    /// それ以前の要求はシステムに届いている)。snapshot が無いときは、すぐ completion を呼ぶ(通知を遅らせない)。
    /// 応答が遅いときは、alignTimeout で打ち切って completion を呼ぶ(completion は何度呼んでも、通知は 1 回しか出ない)
    private func alignLocalNotifications(with snapshot: PairSnapshot?, completion: @escaping @Sendable () -> Void) {
        guard let snapshot else {
            completion()
            return
        }
        // 設定(ストリーク危機のオン・オフ)はアプリが App Group に書いたもの。読めない・まだ無いときは既定(オン)
        let prefs = AppGroupStore.standard().map { AppGroupNotificationPreferencesStore(store: $0).load() }
            ?? NotificationPreferences()
        Task {
            await LocalNotificationPushSync.align(
                center: UserNotificationCenterScheduler(),
                prefs: prefs,
                snapshot: snapshot,
                now: Date(),
                calendar: LocalNotificationCalendar.current()
            )
            completion()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.alignTimeout) {
            completion()
        }
    }
}
