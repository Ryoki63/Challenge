// NotificationPreferences.swift — 端末のローカル通知の設定(REQUIREMENTS §3.12・§3.15 / T16 #16)
//
// v1.0 のアプリ内で切り替えられるのは、ローカル通知(リマインド・ストリーク危機)の ON/OFF とリマインドの時刻だけ。
// サーバーから届く通知(相手のチェックイン・つつく・リアクション)の種別ごとの ON/OFF は v1.1 の「サーバー側の通知設定」(D3)で、
// それまでは iOS の設定アプリで止める。
//
//   - リマインド: **約束の remind_at(promises.remind_at。nil = オフ)が正**。約束設定の画面と通知の設定画面のどちらから
//     変えても同じ値(サーバーの約束)を書く。この端末は、予約のために最後に知った値を覚えておく(ここ)。
//     まだ知らない(`.unknown`。この版へ更新した直後・再インストールの直後)ときは、ReminderScheduler がサーバーの約束から一度読む。
//     読めるまでは予約しない(オフにした人に、20:00 を勝手に出さない)
//   - ストリーク危機: 端末ローカルの設定(サーバーに送らない)。既定はオン
//
// 保存先は App Group の notification_prefs.json(AppGroupStore)。アカウントの削除・サインアウトの後始末(eraseAll)で消える。

import Foundation

// MARK: - リマインドの設定

/// 約束のリマインド(promises.remind_at)を、この端末がどう覚えているか
enum ReminderPreference: Equatable, Sendable {
    /// まだ知らない(サーバーの約束から読めていない)
    case unknown
    /// オフ(remind_at が無い)
    case off
    /// 毎日、端末のローカル時刻の hour:minute に
    case daily(hour: Int, minute: Int)

    /// サーバーの表現("HH:MM")から。nil はオフ。形式が不正な値もオフ(約束設定の画面の読み方と同じ)
    init(remindAt: String?) {
        guard let remindAt, let (hour, minute) = Self.parse(remindAt) else {
            self = .off
            return
        }
        self = .daily(hour: hour, minute: minute)
    }

    /// サーバーの表現("HH:MM")。オフ・不明は nil
    var remindAt: String? {
        guard case .daily(let hour, let minute) = self else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// "HH:MM"(00:00〜23:59)を (時, 分) に。サーバーの検証(promise-set の REMIND_AT_FORMAT)と同じ形だけ受け付ける
    static func parse(_ remindAt: String) -> (hour: Int, minute: Int)? {
        let parts = remindAt.split(separator: ":", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            parts[0].count == 2, parts[1].count == 2,
            // Int("+8") も 8 になるので、数字だけであることを先に確かめる
            parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
            let hour = Int(parts[0]), (0...23).contains(hour),
            let minute = Int(parts[1]), (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }
}

/// ファイルへは文字列 1 つで持つ: "unknown" / "off" / "20:00"。読めない値は `.unknown`(= サーバーの約束から読み直す)
extension ReminderPreference: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "off":
            self = .off
        default:
            if let (hour, minute) = Self.parse(raw) {
                self = .daily(hour: hour, minute: minute)
            } else {
                self = .unknown
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unknown: try container.encode("unknown")
        case .off: try container.encode("off")
        case .daily: try container.encode(remindAt ?? "off")
        }
    }
}

// MARK: - 設定

struct NotificationPreferences: Equatable, Sendable {
    /// 約束のリマインド(promises.remind_at)。既定は「まだ知らない」
    var reminder: ReminderPreference = .unknown
    /// 夜 9 時のストリーク危機。端末ローカルの設定。既定はオン
    var streakRiskEnabled = true

    init(reminder: ReminderPreference = .unknown, streakRiskEnabled: Bool = true) {
        self.reminder = reminder
        self.streakRiskEnabled = streakRiskEnabled
    }
}

extension NotificationPreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case reminder
        case streakRiskEnabled
    }

    /// 欠けているキー・壊れた値は既定で埋める(設定の読み込みで失敗して、通知の予約ごと止まらないように)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reminder = (try? container.decodeIfPresent(ReminderPreference.self, forKey: .reminder)) ?? .unknown
        streakRiskEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .streakRiskEnabled)) ?? true
    }
}

// MARK: - 保存

/// 設定の保存の口(本実装は App Group のファイル / テストはメモリ)
protocol NotificationPreferencesStoring: AnyObject {
    /// 保存された設定。ファイルが無い・壊れているときは既定
    func load() -> NotificationPreferences
    func save(_ preferences: NotificationPreferences)
    /// 保存した設定を消す(サインアウト・アカウントの削除)
    func clear()
}

/// App Group の notification_prefs.json に保存する
final class AppGroupNotificationPreferencesStore: NotificationPreferencesStoring {
    private let store: AppGroupStore

    init(store: AppGroupStore) {
        self.store = store
    }

    func load() -> NotificationPreferences {
        store.loadNotificationPreferences(NotificationPreferences.self) ?? NotificationPreferences()
    }

    func save(_ preferences: NotificationPreferences) {
        // 書き込みの失敗(ディスク満杯など)は握りつぶす: 設定は次の操作・次の同期でやり直せる
        try? store.saveNotificationPreferences(preferences)
    }

    func clear() {
        store.removeNotificationPreferences()
    }
}

/// メモリだけの保存(テスト・プレビュー)
final class InMemoryNotificationPreferencesStore: NotificationPreferencesStoring {
    private(set) var preferences: NotificationPreferences
    /// save が呼ばれた回数(テストが観測する)
    private(set) var saveCount = 0

    init(_ preferences: NotificationPreferences = NotificationPreferences()) {
        self.preferences = preferences
    }

    func load() -> NotificationPreferences { preferences }

    func save(_ preferences: NotificationPreferences) {
        self.preferences = preferences
        saveCount += 1
    }

    func clear() {
        preferences = NotificationPreferences()
    }
}
