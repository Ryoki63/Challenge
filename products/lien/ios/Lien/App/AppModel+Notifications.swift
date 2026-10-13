// AppModel+Notifications.swift — ローカル通知の OS 許可(issue #16)
//
// AppModel.swift が 300 行の目安を超えているので、通知の許可まわりはここに分けた。
// ローカル通知の予約そのもの(sync)を呼ぶ契機は AppModel.swift(scheduleReminderSync)にある。

import Foundation

extension AppModel {
    /// リマインド付きの約束を保存したのに、OS の通知許可をまだ聞いていない(オンボーディングで「あとで」を選んだ)ときは、
    /// ここで求める(許可が無いまま予約だけが並んで、黙って届かないのを防ぐ)。許可されたら予約を合わせ直す
    /// (許可が出る前の予約は、OS に断られて残っていないかもしれない)。拒否されているときは求めない(設定画面に案内がある)。
    /// リマインドが無い・通知を扱わない構成のときは nil。戻り値の Task は、求める処理が終わるまで(テストが待つ)
    @discardableResult
    func requestNotificationAuthorizationIfNeeded(for promise: Promise) -> Task<Void, Never>? {
        guard promise.remindAt != nil, let reminders = services.reminders else { return nil }
        let authorizer = services.pushAuthorizer
        return Task {
            guard await reminders.authorizationStatus() == .notDetermined else { return }
            if await authorizer.requestAuthorization() { await reminders.sync() }
        }
    }
}
