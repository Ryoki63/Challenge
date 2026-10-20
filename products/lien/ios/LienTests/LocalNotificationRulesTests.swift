// LocalNotificationRulesTests.swift — ローカル通知の識別子と取り消し条件(アプリの同期と NSE で共通の規則。T16 #16)
//
// 検証対象(LocalNotificationID.swift。Lien / LienNSE でソース共有):
//   - 識別子(日付つき)・暦(グレゴリオ暦+端末のタイムゾーン)
//   - 「今日の分をもう出さなくてよい」の条件(自分が完了 → リマインド / ふたりそろった・ペアが無い・ストリークが 0 → ストリーク危機)
//   - snapshot が今日のものでないときは何も言わない(昨日の完了を今日の完了と取り違えない)
//   - 日付が変わって 1:00 までに作られた snapshot の完了は「不明」(サーバーが前の日の日付で組み立てているかもしれない)
//   - 前面で届いたローカル通知を捨ててよいか(NSE が取り消せなかったときの最後の網)
//   - アプリと NSE が同じ計画・同じ規則を使っていること(ソースの確認)と、NSE の共有ファイルが Foundation(と通知センター)だけに依存すること

import XCTest
@testable import Lien

final class LocalNotificationRulesTests: XCTestCase {
    private typealias Clock = NotificationClock
    private let calendar = NotificationClock.calendar()
    private let now = NotificationClock.date(2026, 10, 14, 15, 0)

    // MARK: 識別子

    func testIdentifiersCarryTheDayAndAreRecognizedByKind() {
        let reminder = LocalNotificationID.reminder(dayKey: "2026-10-14")
        let risk = LocalNotificationID.streakRisk(dayKey: "2026-10-14")
        XCTAssertEqual(reminder, "lien.local.reminder.2026-10-14")
        XCTAssertEqual(risk, "lien.local.streak-risk.2026-10-14")

        XCTAssertTrue(LocalNotificationID.isOurs(reminder))
        XCTAssertTrue(LocalNotificationID.isOurs(risk))
        XCTAssertTrue(LocalNotificationID.isReminder(reminder))
        XCTAssertFalse(LocalNotificationID.isReminder(risk))
        XCTAssertTrue(LocalNotificationID.isStreakRisk(risk))
        XCTAssertFalse(LocalNotificationID.isStreakRisk(reminder))

        // リモート通知の識別子(APNs の apns-collapse-id など)やほかのアプリの通知は、このアプリのローカル通知ではない
        XCTAssertFalse(LocalNotificationID.isOurs("B2A6D0C8-5B6F-4A33-9C54-0123456789AB"))
        XCTAssertFalse(LocalNotificationID.isOurs("lien.remote.reminder.2026-10-14"))
        XCTAssertFalse(LocalNotificationID.isOurs(""))
    }

    func testDayKeyIsZeroPaddedAndFollowsTheCalendarsTimeZone() {
        XCTAssertEqual(LocalNotificationID.dayKey(for: Clock.date(2026, 1, 5, 9, 0), calendar: calendar), "2026-01-05")
        XCTAssertEqual(LocalNotificationID.dayKey(for: Clock.date(2026, 12, 31, 23, 59, 59), calendar: calendar), "2026-12-31")
        XCTAssertEqual(LocalNotificationID.dayKey(for: Clock.date(2027, 1, 1, 0, 0, 0), calendar: calendar), "2027-01-01")
        // 日付が変わる瞬間は、タイムゾーンで決まる(東京の 2026-10-15 00:30 は、ロサンゼルスではまだ 10-14)
        let instant = Clock.date(2026, 10, 15, 0, 30)
        XCTAssertEqual(LocalNotificationID.dayKey(for: instant, calendar: Clock.calendar(Clock.tokyo)), "2026-10-15")
        XCTAssertEqual(LocalNotificationID.dayKey(for: instant, calendar: Clock.calendar(Clock.losAngeles)), "2026-10-14")
    }

    func testTheNotificationCalendarIsGregorianEvenIfTheDeviceUsesAnotherCalendar() {
        // 端末の暦が和暦・仏暦でも、年の数え方が変わって日付のキーや通知の日時がずれないように、暦は固定する
        let calendar = LocalNotificationCalendar.current()
        XCTAssertEqual(calendar.identifier, .gregorian)
        XCTAssertEqual(calendar.timeZone.identifier, TimeZone.current.identifier)

        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: Clock.tokyo)!
        let instant = Clock.date(2026, 10, 14, 12, 0)
        XCTAssertEqual(
            LocalNotificationID.dayKey(for: instant, calendar: Clock.calendar()), "2026-10-14",
            "グレゴリオ暦では 2026 年"
        )
        XCTAssertNotEqual(
            LocalNotificationID.dayKey(for: instant, calendar: japanese), "2026-10-14",
            "和暦のままだと年が令和の年になる(だから固定する)"
        )
    }

    // MARK: snapshot が今日のものか

    func testReflectsTodayFollowsTheLocalDay() {
        let snapshot = NotificationSnapshots.paired(updatedAt: Clock.date(2026, 10, 14, 0, 0, 1))
        XCTAssertTrue(snapshot.reflectsToday(now: Clock.date(2026, 10, 14, 23, 59, 59), calendar: calendar))
        XCTAssertFalse(snapshot.reflectsToday(now: Clock.date(2026, 10, 15, 0, 0, 0), calendar: calendar))
        XCTAssertFalse(snapshot.reflectsToday(now: Clock.date(2026, 10, 13, 23, 59, 59), calendar: calendar))
    }

    // MARK: 今日の完了(日付が変わって間もない snapshot は「不明」)

    func testCompletionIsKnownOnlyForASnapshotBuiltTodayAfterTheSettleHour() {
        let built = Clock.date(2026, 10, 14, 9, 0)
        let snapshot = NotificationSnapshots.paired(updatedAt: built, meDone: true, partnerDone: false)
        XCTAssertEqual(
            snapshot.todayCompletion(now: Clock.date(2026, 10, 14, 15, 0), calendar: calendar),
            TodayCompletion(me: true, partner: false)
        )
        XCTAssertNil(snapshot.todayCompletion(now: Clock.date(2026, 10, 15, 9, 0), calendar: calendar), "昨日の snapshot の完了は、今日の完了ではない")
        XCTAssertEqual(
            snapshot.completionOnItsOwnDay(calendar: calendar),
            TodayCompletion(me: true, partner: false),
            "その snapshot を作った日の完了としては確か"
        )
        XCTAssertFalse(TodayCompletion(me: true, partner: false).both)
        XCTAssertTrue(TodayCompletion(me: true, partner: true).both)
    }

    func testCompletionIsUnknownForASnapshotBuiltBeforeTheSettleHour() {
        // サーバーは、checkin・checkin-cancel・nudge の snapshot を、クライアントが送った日付を「今日」として組み立てる。
        // その日付は翌日の 1:00 まで有効(snapshot.ts の CLOSE_DAY_SETTLE_HOUR)。この間に作られた snapshot の完了は、前の日のことかもしれない。
        // ※ ここは **dateLocal が無い古いサーバー**の snapshot(新しいサーバーは下のテスト)
        XCTAssertEqual(LocalNotificationCalendar.snapshotSettleHour, 1)
        for (hour, minute, known) in [(0, 0, false), (0, 59, false), (1, 0, true), (1, 1, true), (23, 59, true)] {
            let snapshot = NotificationSnapshots.paired(
                updatedAt: Clock.date(2026, 10, 15, hour, minute, 30), meDone: true, partnerDone: true
            )
            let now = Clock.date(2026, 10, 15, 12, 0)
            XCTAssertEqual(snapshot.todayCompletion(now: now, calendar: calendar) != nil, known, "\(hour):\(minute)")
            XCTAssertTrue(snapshot.reflectsToday(now: now, calendar: calendar), "今日のものではある(完了だけが不明)")
        }
    }

    // MARK: - 組み立てに使った「今日」(dateLocal。issue #72)

    func testDateLocalMakesTheCompletionCertainEvenBeforeTheSettleHour() {
        // 新しいサーバーは、組み立てに使った「今日」を dateLocal に載せる。0:20 に組み立てても、完了がどの日のものかは確か
        let early = Clock.date(2026, 10, 15, 0, 20)
        let snapshot = NotificationSnapshots.paired(
            updatedAt: early, dateLocal: "2026-10-15", meDone: true, partnerDone: false
        )
        let now = Clock.date(2026, 10, 15, 0, 25)
        XCTAssertEqual(snapshot.dateLocal, "2026-10-15")
        XCTAssertEqual(
            snapshot.completionOnItsOwnDay(calendar: calendar),
            TodayCompletion(me: true, partner: false),
            "dateLocal があれば、時刻ではなく日付で解釈する(0:00〜1:00 も「不明」にしない)"
        )
        XCTAssertTrue(snapshot.reflectsToday(now: now, calendar: calendar))
        XCTAssertEqual(
            snapshot.todayCompletion(now: now, calendar: calendar),
            TodayCompletion(me: true, partner: false)
        )
    }

    func testDateLocalMakesACheckinRightAfterMidnightCancelTodaysReminder() {
        // 受け入れ条件(issue #72): 0:00〜1:00 に自分でチェックインしたら、その日のリマインドが取り消される。
        // サーバーは 0:20 に組み立てた snapshot に dateLocal = その日 を載せる(クライアントが送った日付 = 今日)
        let early = Clock.date(2026, 10, 15, 0, 20)
        let snapshot = NotificationSnapshots.paired(
            updatedAt: early, dateLocal: "2026-10-15", meDone: true, partnerDone: false
        )
        XCTAssertEqual(
            LocalNotificationCancellation.staleIDsForToday(
                snapshot: snapshot, now: Clock.date(2026, 10, 15, 0, 21), calendar: calendar
            ),
            ["lien.local.reminder.2026-10-15"],
            "済んでいるのに、その日のリマインドが残らない(アプリを開き直すまで待たない)"
        )
        // ふたりそろっていれば、その日のストリーク危機も要らない
        var both = snapshot
        both.todayPartnerDone = true
        XCTAssertEqual(
            Set(LocalNotificationCancellation.staleIDsForToday(
                snapshot: both, now: Clock.date(2026, 10, 15, 0, 21), calendar: calendar
            )),
            ["lien.local.reminder.2026-10-15", "lien.local.streak-risk.2026-10-15"]
        )
    }

    func testDateLocalOfThePreviousDayIsNeverReadAsTodaysCompletion() {
        // 14 日 23:58 に圏外で押したチェックインが 15 日 0:20 に届くと、サーバーは 14 日を「今日」として組み立てる
        // (dateLocal = 14 日)。これを 15 日の完了と取り違えない
        let arrival = Clock.date(2026, 10, 15, 0, 20)
        let queuedFromYesterday = NotificationSnapshots.paired(
            updatedAt: arrival, dateLocal: "2026-10-14", meDone: true, partnerDone: true, streak: 24
        )
        let now = Clock.date(2026, 10, 15, 0, 25)
        XCTAssertFalse(queuedFromYesterday.reflectsToday(now: now, calendar: calendar), "14 日の snapshot")
        XCTAssertNil(queuedFromYesterday.todayCompletion(now: now, calendar: calendar))
        XCTAssertEqual(
            LocalNotificationCancellation.staleIDsForToday(snapshot: queuedFromYesterday, now: now, calendar: calendar),
            [],
            "昨日の完了を理由に、今日の分を取り消さない"
        )
        XCTAssertEqual(
            queuedFromYesterday.completionOnItsOwnDay(calendar: calendar),
            TodayCompletion(me: true, partner: true),
            "その snapshot の日(14 日)の完了としては確か"
        )
        XCTAssertEqual(
            queuedFromYesterday.daysSinceSnapshotDay(now: now, calendar: calendar), 1,
            "いまのローカル日から見て 1 日前"
        )
    }

    func testDateLocalIsReadInTheDevicesTimeZone() {
        // dateLocal はサーバーが組み立てに使った日付そのもの。端末のタイムゾーンが違えば「今日」との一致も変わる
        let instant = Clock.date(2026, 10, 15, 0, 20) // 東京の 15 日 0:20 = ロサンゼルスの 14 日 8:20
        let snapshot = NotificationSnapshots.paired(
            updatedAt: instant, dateLocal: "2026-10-15", meDone: true
        )
        XCTAssertTrue(snapshot.reflectsToday(now: instant, calendar: Clock.calendar(Clock.tokyo)))
        XCTAssertFalse(
            snapshot.reflectsToday(now: instant, calendar: Clock.calendar(Clock.losAngeles)),
            "ロサンゼルスではまだ 14 日: 15 日の完了ではない"
        )
    }

    func testAnUnreadableDateLocalFallsBackToTheTimeRule() {
        // 形が違う・存在しない日付の dateLocal は、キーが無い古いサーバーと同じ道に落とす(壊れた値で取り消しを誤らない)
        for raw in ["2026-10-15T00:00:00Z", "2026-1-5", "", "20261015", "2026-02-31"] {
            var snapshot = NotificationSnapshots.paired(
                updatedAt: Clock.date(2026, 10, 15, 0, 20), meDone: true
            )
            snapshot.dateLocal = raw
            XCTAssertNil(snapshot.serverDay(calendar: calendar), raw)
            XCTAssertEqual(
                snapshot.snapshotDay(calendar: calendar), calendar.startOfDay(for: snapshot.updatedAt),
                "\(raw): updatedAt の日に戻る"
            )
            XCTAssertNil(
                snapshot.completionOnItsOwnDay(calendar: calendar),
                "\(raw): 0:20 の snapshot なので、時刻の規則で「不明」(古いサーバーと同じ)"
            )
        }
    }

    func testDayKeyRoundTripsThroughTheCalendar() {
        let tokyo = Clock.calendar(Clock.tokyo)
        for key in ["2026-10-15", "2026-01-01", "2024-02-29"] {
            let date = LocalNotificationID.date(fromDayKey: key, calendar: tokyo)
            XCTAssertNotNil(date, key)
            XCTAssertEqual(date.map { LocalNotificationID.dayKey(for: $0, calendar: tokyo) }, key)
        }
        // 存在しない日・形が違う日は nil(暦が繰り上げた日を、その日と取り違えない)
        for key in ["2026-02-31", "2026-13-01", "2026-00-10", "2026-1-5", "2026-10-15T00:00:00Z", ""] {
            XCTAssertNil(LocalNotificationID.date(fromDayKey: key, calendar: tokyo), key)
        }
    }


    func testTheSettleHourFollowsTheDevicesTimeZone() {
        // 同じ瞬間でも、端末のタイムゾーンの 0:20 かどうかで決まる(東京の 15 日 0:20 は、ロサンゼルスでは 14 日 8:20)
        let instant = Clock.date(2026, 10, 15, 0, 20)
        let snapshot = NotificationSnapshots.paired(updatedAt: instant, meDone: true)
        XCTAssertNil(snapshot.completionOnItsOwnDay(calendar: Clock.calendar(Clock.tokyo)))
        XCTAssertNotNil(snapshot.completionOnItsOwnDay(calendar: Clock.calendar(Clock.losAngeles)))
    }

    // MARK: 取り消し条件

    func testCompletingTodayMakesTodaysReminderStaleButNotTheStreakRisk() {
        let snapshot = NotificationSnapshots.paired(updatedAt: now, meDone: true, partnerDone: false)
        XCTAssertEqual(
            LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar),
            ["lien.local.reminder.2026-10-14"],
            "自分が済んだらリマインドは要らない。相手がまだなら、ストリーク危機は残す"
        )
    }

    func testBothDoneMakesTodaysStreakRiskStaleAsWell() {
        let snapshot = NotificationSnapshots.paired(updatedAt: now, meDone: true, partnerDone: true)
        XCTAssertEqual(
            Set(LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar)),
            ["lien.local.reminder.2026-10-14", "lien.local.streak-risk.2026-10-14"]
        )
    }

    func testPartnerAloneDoingItCancelsNothing() {
        // 相手が済んで自分がまだ: 自分のリマインドも、ストリーク危機(自分が済ませれば間に合う)も、まだ要る
        let snapshot = NotificationSnapshots.paired(updatedAt: now, meDone: false, partnerDone: true)
        XCTAssertEqual(LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar), [])
    }

    func testNothingIsDoneYetCancelsNothing() {
        let snapshot = NotificationSnapshots.paired(updatedAt: now)
        XCTAssertEqual(LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar), [])
    }

    func testDissolvedPairMakesTodaysStreakRiskStale() {
        var snapshot = NotificationSnapshots.paired(updatedAt: now)
        snapshot.pairId = nil
        XCTAssertEqual(
            LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar),
            ["lien.local.streak-risk.2026-10-14"],
            "ペアが無くなったら、ストリーク危機は要らない(リマインドは自分の約束のものなので残す)"
        )
    }

    func testNoStreakMakesTodaysStreakRiskStale() {
        // ストリークが途切れた(close-day の streak_reset の push)あとの snapshot: 古い日数の通知を、これ以上届けない
        let reset = NotificationSnapshots.paired(updatedAt: now, streak: 0)
        XCTAssertEqual(
            LocalNotificationCancellation.staleIDsForToday(snapshot: reset, now: now, calendar: calendar),
            ["lien.local.streak-risk.2026-10-14"]
        )
    }

    func testUnknownCompletionCancelsNothingOnItsOwn() {
        // 日付が変わって 1:00 までに作られた snapshot の「ふたりそろった」は、前の日のことかもしれない: 今日の分を取り消さない
        let early = Clock.date(2026, 10, 14, 0, 20)
        let snapshot = NotificationSnapshots.paired(updatedAt: early, meDone: true, partnerDone: true)
        XCTAssertEqual(
            LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: Clock.date(2026, 10, 14, 7, 0), calendar: calendar),
            []
        )
        // ただし、完了によらない理由(ペアが無い・ストリークが 0)は、いつでも言える
        var solo = snapshot
        solo.pairId = nil
        XCTAssertEqual(
            LocalNotificationCancellation.staleIDsForToday(snapshot: solo, now: Clock.date(2026, 10, 14, 7, 0), calendar: calendar),
            ["lien.local.streak-risk.2026-10-14"]
        )
    }

    func testAStaleSnapshotSaysNothingAboutToday() {
        // 昨日ふたりそろった snapshot(todayMeDone / todayPartnerDone は昨日の完了)を、今日の完了と取り違えない
        let yesterday = NotificationSnapshots.paired(
            updatedAt: Clock.date(2026, 10, 13, 22, 0), meDone: true, partnerDone: true
        )
        XCTAssertEqual(LocalNotificationCancellation.staleIDsForToday(snapshot: yesterday, now: now, calendar: calendar), [])
    }

    // MARK: アプリと NSE が同じ計画・同じ規則を使っている(ソースの確認)

    func testTheAppAndTheNotificationServiceExtensionShareOnePlanAndOneCancellationRule() throws {
        // ストリーク危機の計画(StreakRiskPlan)・取り消し条件(LocalNotificationCancellation)・OS の予約との合わせ込み
        // (NotificationReconciler)は、アプリの同期(ReminderScheduler)と NSE で同じ関数を使う。
        // 片方だけが別の規則に変わる(アプリが予約するものと、NSE が合わせるものが食い違う)のを、ソースの上で止める
        let nse = Self.withoutComments(try SourceTree.text("LienNSE/NotificationService.swift"))
        XCTAssertTrue(nse.contains("LocalNotificationPushSync.align"), "NSE が共通の合わせ込みを呼んでいない")
        XCTAssertTrue(nse.contains("UserNotificationCenterScheduler()"), "NSE が通知センターを共通の抽象越しに触っていない")
        XCTAssertFalse(nse.contains("removePendingNotificationRequests"), "NSE が通知センターを直接触っている — 共通の合わせ込みを通すこと")
        XCTAssertFalse(nse.contains("StreakRiskPlan"), "NSE が自前でストリーク危機を計算している — LocalNotificationPushSync に任せること")

        let sync = try SourceTree.text("Lien/Core/Notifications/LocalNotificationPushSync.swift")
        XCTAssertTrue(sync.contains("StreakRiskPlan.desired"), "NSE の合わせ込みが、アプリと同じ計画を使っていない")
        XCTAssertTrue(sync.contains("NotificationReconciler.reconcile"))
        XCTAssertTrue(sync.contains("NotificationReconciler.dismissDelivered"))
        XCTAssertTrue(sync.contains("LocalNotificationCancellation.staleIDsForToday"), "NSE の合わせ込みが、共通の取り消し条件を使っていない")

        let plan = try SourceTree.text("Lien/Core/Notifications/ReminderScheduler+Plan.swift")
        XCTAssertTrue(plan.contains("StreakRiskPlan.desired"), "アプリの計画が、NSE と同じストリーク危機の計画を使っていない")

        let scheduler = try SourceTree.text("Lien/Core/Notifications/ReminderScheduler.swift")
        XCTAssertTrue(scheduler.contains("NotificationReconciler.reconcile"), "アプリの同期が共通の合わせ込みを使っていない")
        XCTAssertTrue(scheduler.contains("NotificationReconciler.dismissDelivered"))

        let delegate = try SourceTree.text("Lien/App/AppDelegate.swift")
        XCTAssertTrue(delegate.contains("LocalNotificationCancellation.shouldSuppress"), "前面で届いたときの網が無い")
    }

    /// 行コメント(// …)の行を除いたソース(コメントに書いた名前を、使っている証拠に数えない)
    private static func withoutComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// project.yml の LienNSE の sources に並ぶ、Swift ファイルの個別指定(ios/ からの相対パス)
    private func notificationServiceExtensionSharedFiles() throws -> [String] {
        let yml = try SourceTree.text("project.yml")
        let nseBlock = try XCTUnwrap(
            yml.components(separatedBy: "\n  LienNSE:").last?.components(separatedBy: "\n  LienTests:").first,
            "project.yml に LienNSE が無い"
        )
        return nseBlock.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- path: "), trimmed.hasSuffix(".swift") else { return nil }
            return String(trimmed.dropFirst("- path: ".count))
        }
    }

    func testTheNotificationServiceExtensionTargetCompilesTheSharedPlanFiles() throws {
        let shared = try notificationServiceExtensionSharedFiles()
        for required in [
            "Lien/Core/Strings.swift", // ストリーク危機の文言
            "Lien/Core/Notifications/LocalNotificationID.swift", // 識別子・暦・今日の完了・取り消し条件
            "Lien/Core/Notifications/NotificationScheduling.swift", // 予約 1 件の値と通知センターの抽象
            "Lien/Core/Notifications/NotificationPreferences.swift", // ストリーク危機のオン・オフ(notification_prefs.json)
            "Lien/Core/Notifications/StreakRiskPlan.swift",
            "Lien/Core/Notifications/NotificationReconciler.swift",
            "Lien/Core/Notifications/LocalNotificationPushSync.swift",
            "Lien/Core/Notifications/UserNotificationCenterScheduler.swift", // 通知リクエストの組み立て・本物の通知センター
        ] {
            XCTAssertTrue(shared.contains(required), "LienNSE の sources に \(required) が無い(NSE が共通の計画を使えない)")
        }
    }

    func testEveryFileSharedWithTheNotificationServiceExtensionDependsOnlyOnFoundation() throws {
        // NSE は UIKit も必須理由 API も使わない(PrivacyManifestTests)。共有するファイルは Foundation だけに依存する。
        // 例外は、通知センターに触れる UserNotificationCenterScheduler(UserNotifications。NSE も取り込む)だけ
        let allowed: [String: Set<String>] = [
            "Lien/Core/Notifications/UserNotificationCenterScheduler.swift": ["Foundation", "UserNotifications"],
        ]
        for path in try notificationServiceExtensionSharedFiles() {
            let source = try SourceTree.text(path)
            let imports = Set(source.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ")
                return parts.count == 2 && parts[0] == "import" ? String(parts[1]) : nil
            })
            XCTAssertEqual(imports, allowed[path] ?? ["Foundation"], path)
        }
    }

    // MARK: 前面で届いたときに捨ててよいか(NSE が取り消せなかったときの最後の網)

    func testShouldSuppressOnlyTheStaleLocalNotificationOfToday() {
        let both = NotificationSnapshots.paired(updatedAt: now, meDone: true, partnerDone: true)
        let risk = "lien.local.streak-risk.2026-10-14"
        let reminder = "lien.local.reminder.2026-10-14"
        XCTAssertTrue(LocalNotificationCancellation.shouldSuppress(identifier: risk, snapshot: both, now: now, calendar: calendar))
        XCTAssertTrue(LocalNotificationCancellation.shouldSuppress(identifier: reminder, snapshot: both, now: now, calendar: calendar))

        let none = NotificationSnapshots.paired(updatedAt: now)
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(identifier: risk, snapshot: none, now: now, calendar: calendar))
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(identifier: reminder, snapshot: none, now: now, calendar: calendar))

        // 別の日の通知・リモート通知・snapshot が無いときは、捨てない(通知を失わない側に倒す)
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(
            identifier: "lien.local.streak-risk.2026-10-15", snapshot: both, now: now, calendar: calendar
        ))
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(
            identifier: "B2A6D0C8-5B6F-4A33-9C54-0123456789AB", snapshot: both, now: now, calendar: calendar
        ))
        XCTAssertFalse(LocalNotificationCancellation.shouldSuppress(identifier: risk, snapshot: nil, now: now, calendar: calendar))
    }
}
