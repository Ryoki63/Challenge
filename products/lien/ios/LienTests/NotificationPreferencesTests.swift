// NotificationPreferencesTests.swift — ローカル通知の設定とその保存(T16 #16)
//
// 検証対象(NotificationPreferences.swift / AppGroupStore.swift):
//   - リマインドの時刻の表現("HH:MM" ⇔ ReminderPreference)。サーバーの検証(promise-set の REMIND_AT_FORMAT)と同じ形だけ受け付ける
//   - 設定の保存(App Group の notification_prefs.json): 往復・既定値・壊れたファイル・欠けたキー
//   - サインアウト・アカウントの削除の後始末(eraseAll)で消えること

import XCTest
@testable import Lien

final class NotificationPreferencesTests: XCTestCase {
    // MARK: リマインドの表現

    func testRemindAtRoundTripsThroughThePreference() {
        XCTAssertEqual(ReminderPreference(remindAt: "20:00"), .daily(hour: 20, minute: 0))
        XCTAssertEqual(ReminderPreference(remindAt: "07:05"), .daily(hour: 7, minute: 5))
        XCTAssertEqual(ReminderPreference(remindAt: "00:00"), .daily(hour: 0, minute: 0))
        XCTAssertEqual(ReminderPreference(remindAt: "23:59"), .daily(hour: 23, minute: 59))
        XCTAssertEqual(ReminderPreference.daily(hour: 7, minute: 5).remindAt, "07:05")
        XCTAssertEqual(ReminderPreference.daily(hour: 20, minute: 0).remindAt, "20:00")
        XCTAssertNil(ReminderPreference.off.remindAt)
        XCTAssertNil(ReminderPreference.unknown.remindAt)
    }

    func testNilAndMalformedRemindAtMeanOff() {
        // 約束に remind_at が無い = オフ(約束設定の画面の読み方と同じ)。形式が不正な値もオフ
        XCTAssertEqual(ReminderPreference(remindAt: nil), .off)
        for malformed in ["", "20", "20:0", "2:00", "24:00", "12:60", "ab:cd", "+8:00", "-1:00", "20:00:00", "20-00", " 20:00"] {
            XCTAssertEqual(ReminderPreference(remindAt: malformed), .off, malformed)
            XCTAssertNil(ReminderPreference.parse(malformed), malformed)
        }
    }

    func testPreferenceSurvivesJSONRoundTripAsAPlainString() throws {
        for preference in [ReminderPreference.unknown, .off, .daily(hour: 20, minute: 30)] {
            let data = try JSONEncoder().encode(["reminder": preference])
            let decoded = try JSONDecoder().decode([String: ReminderPreference].self, from: data)
            XCTAssertEqual(decoded["reminder"], preference)
        }
        let data = try JSONEncoder().encode(["reminder": ReminderPreference.daily(hour: 7, minute: 5)])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"reminder":"07:05"}"#)
    }

    func testUnreadableReminderValueFallsBackToUnknown() throws {
        // 読めない値は「まだ知らない」= サーバーの約束から読み直す(予約が止まったままにならない)
        let data = Data(#"{"reminder":"banana"}"#.utf8)
        let decoded = try JSONDecoder().decode([String: ReminderPreference].self, from: data)
        XCTAssertEqual(decoded["reminder"], ReminderPreference.unknown)
    }

    // MARK: 設定

    func testDefaultsAreUnknownReminderAndStreakRiskOn() {
        let defaults = NotificationPreferences()
        XCTAssertEqual(defaults.reminder, .unknown)
        XCTAssertTrue(defaults.streakRiskEnabled, "ストリーク危機は既定でオン")
    }

    func testPreferencesRoundTripThroughCodable() throws {
        let preferences = NotificationPreferences(reminder: .daily(hour: 21, minute: 15), streakRiskEnabled: false)
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(NotificationPreferences.self, from: data), preferences)
    }

    func testMissingOrBrokenKeysFallBackToDefaults() throws {
        let empty = try JSONDecoder().decode(NotificationPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, NotificationPreferences())

        let onlyStreak = try JSONDecoder().decode(NotificationPreferences.self, from: Data(#"{"streakRiskEnabled":false}"#.utf8))
        XCTAssertEqual(onlyStreak, NotificationPreferences(reminder: .unknown, streakRiskEnabled: false))

        let broken = try JSONDecoder().decode(
            NotificationPreferences.self, from: Data(#"{"reminder":42,"streakRiskEnabled":"yes"}"#.utf8)
        )
        XCTAssertEqual(broken, NotificationPreferences(), "型違いのキーで、設定の読み込みごと失敗しない")
    }

    // MARK: 保存(App Group のファイル)

    func testStoreSavesAndLoadsAcrossInstances() {
        let temp = TempStore()
        defer { temp.cleanup() }
        let first = AppGroupNotificationPreferencesStore(store: temp.store)
        XCTAssertEqual(first.load(), NotificationPreferences(), "ファイルが無ければ既定")

        let saved = NotificationPreferences(reminder: .daily(hour: 6, minute: 45), streakRiskEnabled: false)
        first.save(saved)

        let second = AppGroupNotificationPreferencesStore(store: temp.store)
        XCTAssertEqual(second.load(), saved, "別のインスタンス(再起動相当)からも同じ設定が読める")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.store.notificationPrefsFileURL.path))
        XCTAssertEqual(AppGroupStore.notificationPrefsFileName, "notification_prefs.json")
    }

    func testStoreTreatsACorruptFileAsDefaults() throws {
        let temp = TempStore()
        defer { temp.cleanup() }
        try FileManager.default.createDirectory(at: temp.directory, withIntermediateDirectories: true)
        try Data("これは JSON ではない".utf8).write(to: temp.store.notificationPrefsFileURL)
        XCTAssertEqual(AppGroupNotificationPreferencesStore(store: temp.store).load(), NotificationPreferences())
    }

    func testClearRemovesTheSavedPreferences() {
        let temp = TempStore()
        defer { temp.cleanup() }
        let store = AppGroupNotificationPreferencesStore(store: temp.store)
        store.save(NotificationPreferences(reminder: .off, streakRiskEnabled: false))
        store.clear()
        XCTAssertEqual(store.load(), NotificationPreferences())
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.store.notificationPrefsFileURL.path))
        store.clear() // 無いファイルを消してもエラーにならない
    }

    func testEraseAllAlsoRemovesThePreferences() throws {
        // アカウントの削除・サインアウトの後始末(AppModel.endSession → eraseAll)で、前のアカウントの設定を持ち越さない
        let temp = TempStore()
        defer { temp.cleanup() }
        try temp.store.saveSnapshot(SnapshotFactory.paired())
        let store = AppGroupNotificationPreferencesStore(store: temp.store)
        store.save(NotificationPreferences(reminder: .daily(hour: 8, minute: 0), streakRiskEnabled: false))

        try temp.store.eraseAll()

        XCTAssertNil(temp.store.loadSnapshot())
        XCTAssertEqual(store.load(), NotificationPreferences())
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.store.notificationPrefsFileURL.path))
    }

    func testPreferencesFileIsSeparateFromTheSnapshot() throws {
        // snapshot の上書き(サーバーとの同期・NSE の書き込み)で、端末の設定が消えない
        let temp = TempStore()
        defer { temp.cleanup() }
        let store = AppGroupNotificationPreferencesStore(store: temp.store)
        let saved = NotificationPreferences(reminder: .daily(hour: 20, minute: 0), streakRiskEnabled: false)
        store.save(saved)

        try temp.store.saveSnapshot(SnapshotFactory.paired())
        try temp.store.saveSnapshot(SnapshotFactory.solo())

        XCTAssertEqual(store.load(), saved)
    }

    // MARK: メモリ上の保存(テスト・プレビュー)

    func testInMemoryStoreBehavesLikeTheFileStore() {
        let store = InMemoryNotificationPreferencesStore()
        XCTAssertEqual(store.load(), NotificationPreferences())
        store.save(NotificationPreferences(reminder: .off, streakRiskEnabled: false))
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.load(), NotificationPreferences(reminder: .off, streakRiskEnabled: false))
        store.clear()
        XCTAssertEqual(store.load(), NotificationPreferences())
    }
}
