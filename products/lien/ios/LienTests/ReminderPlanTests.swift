// ReminderPlanTests.swift — ローカル通知の予約内容を決める純粋関数(ReminderScheduler.desiredRequests。T16 #16)
//
// 検証対象(ReminderScheduler+Plan.swift):
//   - リマインド: 約束の remind_at に先の 14 日ぶん / 今日の分は、時刻を過ぎたら・自分が完了していたら出さない / 取り消しで戻る
//   - ストリーク危機(夜 9 時): ペアのストリークがあり、その日まだふたりそろっていないときだけ / 文言の出し分け /
//     ふたりそろった日は明日の分 / 同期できないまま日をまたいだときの扱い
//   - 日付またぎ(snapshot が今日のものか / 日付が変わって 1:00 までに作られた snapshot の完了は「不明」)・タイムゾーン・夏時間
//   - 取り消し条件が NSE と共通の規則(LocalNotificationCancellation)と食い違わないこと
//   (ストリーク危機の計画そのものは StreakRiskPlan。NSE が同じ答えを出すことは LocalNotificationPushSyncTests)

import XCTest
@testable import Lien

final class ReminderPlanTests: XCTestCase {
    private typealias Clock = NotificationClock
    private let daily20 = NotificationPreferences(reminder: .daily(hour: 20, minute: 0), streakRiskEnabled: true)

    private func plan(
        _ prefs: NotificationPreferences? = nil,
        snapshot: PairSnapshot?,
        now: Date,
        timeZone: String = Clock.tokyo
    ) -> [PlannedNotification] {
        ReminderScheduler.desiredRequests(
            prefs: prefs ?? daily20,
            snapshot: snapshot,
            now: now,
            calendar: Clock.calendar(timeZone)
        )
    }

    private func reminders(_ planned: [PlannedNotification]) -> [PlannedNotification] {
        planned.filter(\.isReminder)
    }

    private func risks(_ planned: [PlannedNotification]) -> [PlannedNotification] {
        planned.filter(\.isStreakRisk)
    }

    private func ids(_ planned: [PlannedNotification]) -> [String] {
        planned.map(\.id)
    }

    // MARK: - リマインド

    func testDailyReminderIsPlannedForTheNext14DaysAtTheRemindTime() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let planned = reminders(plan(snapshot: NotificationSnapshots.paired(updatedAt: now), now: now))

        XCTAssertEqual(ReminderScheduler.horizonDays, 14)
        XCTAssertEqual(planned.count, 14)
        XCTAssertEqual(planned.first?.id, "lien.local.reminder.2026-10-14")
        XCTAssertEqual(planned.last?.id, "lien.local.reminder.2026-10-27")
        XCTAssertEqual(
            planned.first?.fireAt,
            FireTime(year: 2026, month: 10, day: 14, hour: 20, minute: 0, timeZoneIdentifier: "Asia/Tokyo")
        )
        XCTAssertEqual(
            planned.last?.fireAt,
            FireTime(year: 2026, month: 10, day: 27, hour: 20, minute: 0, timeZoneIdentifier: "Asia/Tokyo")
        )
        XCTAssertEqual(Set(ids(planned)).count, 14, "識別子は日付ごとに 1 つ")
        for item in planned {
            XCTAssertEqual(item.title, Strings.LocalNotification.title)
            XCTAssertTrue(item.body.contains("筋トレ"), "約束の名前が入る: \(item.body)")
            XCTAssertTrue(item.body.hasSuffix("💪"), "約束の絵文字が末尾に付く: \(item.body)")
        }
    }

    func testReminderUsesTheRemindTimeIncludingMinutes() {
        let now = Clock.date(2026, 10, 14, 6, 0)
        let prefs = NotificationPreferences(reminder: .daily(hour: 7, minute: 30))
        let planned = reminders(plan(prefs, snapshot: NotificationSnapshots.paired(updatedAt: now), now: now))
        XCTAssertEqual(planned.count, 14)
        XCTAssertEqual(planned.first?.fireAt.hour, 7)
        XCTAssertEqual(planned.first?.fireAt.minute, 30)
    }

    func testTodaysReminderIsSkippedOnceTheTimeHasPassed() {
        let snapshot = NotificationSnapshots.paired(updatedAt: Clock.date(2026, 10, 14, 9, 0))

        let justBefore = reminders(plan(snapshot: snapshot, now: Clock.date(2026, 10, 14, 19, 59, 59)))
        XCTAssertEqual(justBefore.count, 14, "まだ今日の分に間に合う")

        let atTheTime = reminders(plan(snapshot: snapshot, now: Clock.date(2026, 10, 14, 20, 0, 0)))
        XCTAssertEqual(atTheTime.count, 13, "発火の時刻ちょうどは、もう予約しない")
        XCTAssertEqual(atTheTime.first?.id, "lien.local.reminder.2026-10-15")

        let after = reminders(plan(snapshot: snapshot, now: Clock.date(2026, 10, 14, 21, 30)))
        XCTAssertEqual(after.count, 13)
        XCTAssertEqual(after.first?.id, "lien.local.reminder.2026-10-15")
    }

    func testTodaysReminderIsSkippedWhenIAlreadyCheckedInButTomorrowsStays() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let done = NotificationSnapshots.paired(updatedAt: now, meDone: true)
        let planned = reminders(plan(snapshot: done, now: now))
        XCTAssertEqual(planned.count, 13)
        XCTAssertEqual(planned.first?.id, "lien.local.reminder.2026-10-15", "今日の分だけ取り消し、明日からの分は残す")
    }

    func testCancelingTheCheckinBringsTodaysReminderBack() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let done = plan(snapshot: NotificationSnapshots.paired(updatedAt: now, meDone: true), now: now)
        let canceled = plan(snapshot: NotificationSnapshots.paired(updatedAt: now, meDone: false), now: now)
        XCTAssertEqual(reminders(done).count, 13)
        XCTAssertEqual(reminders(canceled).count, 14, "取り消す(todayMeDone が戻る)と、今日の分がまた予約される")
        XCTAssertEqual(reminders(canceled).first?.id, "lien.local.reminder.2026-10-14")
    }

    func testPartnerCompletionDoesNotAffectMyReminder() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let planned = reminders(plan(snapshot: NotificationSnapshots.paired(updatedAt: now, partnerDone: true), now: now))
        XCTAssertEqual(planned.count, 14, "相手が済んでいても、自分のリマインドは出す")
    }

    func testYesterdaysDoneFlagIsNotMistakenForTodays() {
        // 昨日の夜に完了した snapshot(todayMeDone = true)が、同期できないまま日をまたいで残っている
        let yesterday = Clock.date(2026, 10, 13, 22, 0)
        let snapshot = NotificationSnapshots.paired(updatedAt: yesterday, meDone: true)
        let now = Clock.date(2026, 10, 14, 8, 0)
        let planned = reminders(plan(snapshot: snapshot, now: now))
        XCTAssertEqual(planned.count, 14, "snapshot が今日のものでないので、今日はまだ(昨日の完了を数えない)")
        XCTAssertEqual(planned.first?.id, "lien.local.reminder.2026-10-14")
    }

    func testNothingIsPlannedWithoutAPromiseOrSnapshotOrKnownReminder() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let snapshot = NotificationSnapshots.paired(updatedAt: now)
        XCTAssertEqual(plan(snapshot: nil, now: now), [], "snapshot が無い(サインアウト後など)")
        XCTAssertEqual(plan(snapshot: NotificationSnapshots.paired(updatedAt: now, title: nil), now: now), [])
        XCTAssertEqual(plan(snapshot: NotificationSnapshots.paired(updatedAt: now, title: "  "), now: now), [])
        XCTAssertEqual(plan(snapshot: SnapshotFactory.noPromise(updatedAt: now), now: now), [], "約束を決める前")
        XCTAssertEqual(
            reminders(plan(NotificationPreferences(reminder: .off), snapshot: snapshot, now: now)), [],
            "リマインドがオフ"
        )
        XCTAssertEqual(
            reminders(plan(NotificationPreferences(reminder: .unknown), snapshot: snapshot, now: now)), [],
            "時刻をまだ知らない間は予約しない(オフにした人に出さない)"
        )
    }

    func testSoloUserStillGetsTheReminder() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let planned = plan(snapshot: NotificationSnapshots.solo(updatedAt: now), now: now)
        XCTAssertEqual(reminders(planned).count, 14, "ペアが無くても、自分の約束のリマインドは出る")
        XCTAssertEqual(risks(planned), [], "ペアが無いので、ストリーク危機は無い")
    }

    func testReminderWordingIsDeterministicPerDayAndVariesAcrossDays() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let snapshot = NotificationSnapshots.paired(updatedAt: now)
        let first = reminders(plan(snapshot: snapshot, now: now))
        let second = reminders(plan(snapshot: snapshot, now: now))
        XCTAssertEqual(first, second, "同じ入力なら同じ予約(作り直しで付け替わらない)")

        let variants = Set(first.map(\.body))
        XCTAssertEqual(variants.count, 3, "14 日で 3 つの言い回しを回す: \(variants)")
        XCTAssertTrue(
            variants.contains("今日の『筋トレ』、まだ間に合うよ💪"),
            "REQUIREMENTS §3.12 の例の言い回しが入っている"
        )
    }

    func testReminderOmitsAnEmptyEmojiAndTrimsTheTitle() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let snapshot = NotificationSnapshots.paired(updatedAt: now, title: "  筋トレ  ", emoji: nil)
        for item in reminders(plan(snapshot: snapshot, now: now)) {
            XCTAssertTrue(item.body.contains("『筋トレ』"), item.body)
            XCTAssertFalse(item.body.contains("  "), item.body)
            XCTAssertTrue(item.body.hasSuffix("よ") || item.body.hasSuffix("ぶ") || item.body.hasSuffix("?"), item.body)
        }
    }

    // MARK: - ストリーク危機(夜 9 時)

    func testStreakRiskIsPlannedTonightWhenTheRecordContinuesAndTheyAreNotBothDone() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let planned = risks(plan(snapshot: NotificationSnapshots.paired(updatedAt: now), now: now))
        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(planned[0].id, "lien.local.streak-risk.2026-10-14")
        XCTAssertEqual(
            planned[0].fireAt,
            FireTime(year: 2026, month: 10, day: 14, hour: 21, minute: 0, timeZoneIdentifier: "Asia/Tokyo")
        )
        XCTAssertEqual(planned[0].title, "Lien")
        XCTAssertEqual(planned[0].body, Strings.LocalNotification.streakRiskNeither(days: 23))
    }

    func testStreakRiskWordingFollowsWhoHasDone() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let partnerDone = risks(plan(snapshot: NotificationSnapshots.paired(updatedAt: now, partnerDone: true), now: now))
        XCTAssertEqual(partnerDone.first?.body, Strings.LocalNotification.streakRiskPartnerDone(partnerName: "ゆうき", days: 23))
        XCTAssertTrue(partnerDone.first?.body.contains("ゆうきが待ってるよ") == true)

        let meDone = risks(plan(snapshot: NotificationSnapshots.paired(updatedAt: now, meDone: true), now: now))
        XCTAssertEqual(meDone.first?.body, Strings.LocalNotification.streakRiskMeDone(partnerName: "ゆうき", days: 23))
        XCTAssertTrue(meDone.first?.body.contains("つつく") == true, "相手がまだのとき、つつくを案内する")
    }

    func testStreakRiskUsesTheCurrentStreakAndFallsBackToAGenericPartnerName() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let planned = risks(plan(
            snapshot: NotificationSnapshots.paired(updatedAt: now, meDone: true, streak: 7, partnerName: " "),
            now: now
        ))
        XCTAssertEqual(planned.first?.body, Strings.LocalNotification.streakRiskMeDone(partnerName: "あいて", days: 7))
    }

    func testNoStreakRiskTodayOnceBothAreDoneButTomorrowsIsReady() {
        // ふたりそろった日: 今日の夜 9 時は出さない。記録は明日へ続くので、明日の夜 9 時の分を予約しておく
        // (明日アプリを開けなくても、つなげたい日の夜に届く)
        let now = Clock.date(2026, 10, 14, 12, 0)
        let both = NotificationSnapshots.paired(updatedAt: now, meDone: true, partnerDone: true, streak: 24)
        let planned = risks(plan(snapshot: both, now: now))
        XCTAssertEqual(planned.map(\.id), ["lien.local.streak-risk.2026-10-15"])
        XCTAssertEqual(
            planned.first?.fireAt,
            FireTime(year: 2026, month: 10, day: 15, hour: 21, minute: 0, timeZoneIdentifier: "Asia/Tokyo")
        )
        XCTAssertEqual(
            planned.first?.body,
            Strings.LocalNotification.streakRiskNeither(days: 24),
            "明日の分は、明日までの記録(いま 24 日)。明日の状態は分からないので、どちらも未完の言い方"
        )
    }

    func testNoStreakRiskAfterNineWhenNotBothDoneAndTomorrowsOnlyWhenBothDone() {
        let snapshot = NotificationSnapshots.paired(updatedAt: Clock.date(2026, 10, 14, 9, 0))
        XCTAssertEqual(
            risks(plan(snapshot: snapshot, now: Clock.date(2026, 10, 14, 21, 0, 0))), [],
            "夜 9 時を過ぎた。今日の分は出せず、明日の分も(今日ふたりそろっていないので)予約しない"
        )
        let both = NotificationSnapshots.paired(
            updatedAt: Clock.date(2026, 10, 14, 21, 30), meDone: true, partnerDone: true
        )
        XCTAssertEqual(
            risks(plan(snapshot: both, now: Clock.date(2026, 10, 14, 22, 0))).map(\.id),
            ["lien.local.streak-risk.2026-10-15"]
        )
    }

    func testNoStreakRiskWithoutAStreakOrAPairOrWhenDisabled() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        XCTAssertEqual(
            risks(plan(snapshot: NotificationSnapshots.paired(updatedAt: now, streak: 0), now: now)), [],
            "ストリークが無い(続いている記録が無い)"
        )
        XCTAssertEqual(risks(plan(snapshot: NotificationSnapshots.solo(updatedAt: now), now: now)), [], "ペアが無い")
        let off = NotificationPreferences(reminder: .daily(hour: 20, minute: 0), streakRiskEnabled: false)
        let planned = plan(off, snapshot: NotificationSnapshots.paired(updatedAt: now), now: now)
        XCTAssertEqual(risks(planned), [], "設定でオフ")
        XCTAssertEqual(reminders(planned).count, 14, "ストリーク危機をオフにしても、リマインドは変わらない")
    }

    func testStreakRiskWorksEvenWhenTheReminderIsOffOrUnknown() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let snapshot = NotificationSnapshots.paired(updatedAt: now)
        for reminder in [ReminderPreference.off, .unknown] {
            let planned = plan(NotificationPreferences(reminder: reminder), snapshot: snapshot, now: now)
            XCTAssertEqual(risks(planned).count, 1, "リマインドの設定とストリーク危機は別: \(reminder)")
        }
    }

    // MARK: 同期できないまま日をまたいだ snapshot

    func testStaleSnapshotFromYesterdayThatWasBothDoneStillKeepsTonightsRisk() {
        // 昨日(14 日)の夜、ふたりそろった。15 日の朝、オフラインでアプリを開いた(snapshot は昨日のまま)。
        // 昨日までの記録は続いているので、今夜の分は消さない
        let snapshot = NotificationSnapshots.paired(
            updatedAt: Clock.date(2026, 10, 14, 21, 30), meDone: true, partnerDone: true, streak: 24
        )
        let planned = risks(plan(snapshot: snapshot, now: Clock.date(2026, 10, 15, 8, 0)))
        XCTAssertEqual(planned.map(\.id), ["lien.local.streak-risk.2026-10-15"])
        XCTAssertEqual(planned.first?.body, Strings.LocalNotification.streakRiskNeither(days: 24))
    }

    func testTheSameNotificationIsPlannedTheNightBeforeAndTheMorningOf() {
        // 14 日の夜(snapshot は今日のもの・ふたりそろった)に予約した明日の分と、15 日の朝(snapshot は昨日のもの)に
        // 作り直した今日の分は、同じ予約 = 作り直しで付け替わらない
        let snapshot = NotificationSnapshots.paired(
            updatedAt: Clock.date(2026, 10, 14, 21, 30), meDone: true, partnerDone: true, streak: 24
        )
        let night = risks(plan(snapshot: snapshot, now: Clock.date(2026, 10, 14, 22, 0)))
        let morning = risks(plan(snapshot: snapshot, now: Clock.date(2026, 10, 15, 8, 0)))
        XCTAssertEqual(night, morning)
        XCTAssertEqual(night.count, 1)
    }

    func testStaleSnapshotWithoutBothDoneYesterdayPlansNoStreakRisk() {
        // 昨日はふたりそろっていなかった(お休みチケットで守られたかもしれない・途切れたかもしれない)。
        // 今日の記録が続いているか分からないので、予約しない
        let notBoth = NotificationSnapshots.paired(updatedAt: Clock.date(2026, 10, 14, 21, 30), meDone: true)
        XCTAssertEqual(risks(plan(snapshot: notBoth, now: Clock.date(2026, 10, 15, 8, 0))), [])
    }

    func testSnapshotsTwoOrMoreDaysOldOrFromTheFuturePlanNoStreakRisk() {
        let both = NotificationSnapshots.paired(
            updatedAt: Clock.date(2026, 10, 12, 21, 30), meDone: true, partnerDone: true
        )
        XCTAssertEqual(
            risks(plan(snapshot: both, now: Clock.date(2026, 10, 14, 8, 0))), [],
            "2 日前: その間に途切れたかもしれない記録について、通知しない"
        )
        let future = NotificationSnapshots.paired(updatedAt: Clock.date(2026, 10, 16, 9, 0))
        XCTAssertEqual(risks(plan(snapshot: future, now: Clock.date(2026, 10, 14, 8, 0))), [], "時計がずれている")
    }

    // MARK: - 日付が変わって間もない snapshot(完了は前の日のことかもしれない)

    func testACompletionInASnapshotBuiltRightAfterMidnightIsNotTrusted() {
        // 14 日(昨日)の 23:58 に圏外で押された相手のチェックインが、15 日 0:20 に届いた。サーバーはクライアントが送った
        // 14 日を「今日」として snapshot を作る(自分も 14 日に済ませていたので、ふたりそろった)。updatedAt は 15 日の 0:20。
        // これを「今日(15 日)の完了」と読むと、15 日のリマインドを取り消し、ストリーク危機を 16 日に回してしまう
        let snapshot = NotificationSnapshots.paired(
            updatedAt: Clock.date(2026, 10, 15, 0, 20), meDone: true, partnerDone: true, streak: 24
        )
        let planned = plan(snapshot: snapshot, now: Clock.date(2026, 10, 15, 7, 0))

        XCTAssertEqual(reminders(planned).count, 14, "今日のリマインドを取り消さない")
        XCTAssertEqual(reminders(planned).first?.id, "lien.local.reminder.2026-10-15")
        XCTAssertEqual(risks(planned).map(\.id), ["lien.local.streak-risk.2026-10-15"], "今日の夜 9 時の分(明日に回さない)")
        XCTAssertEqual(
            risks(planned).first?.body, Strings.LocalNotification.streakRiskNeither(days: 24),
            "完了が分からないので、どちらも未完の言い方"
        )
    }

    func testTheSameCompletionBuiltAfterTheSettleHourIsTrusted() {
        let snapshot = NotificationSnapshots.paired(
            updatedAt: Clock.date(2026, 10, 15, 1, 0), meDone: true, partnerDone: true, streak: 24
        )
        let planned = plan(snapshot: snapshot, now: Clock.date(2026, 10, 15, 7, 0))

        XCTAssertEqual(reminders(planned).first?.id, "lien.local.reminder.2026-10-16", "自分は済み: 今日のリマインドは要らない")
        XCTAssertEqual(risks(planned).map(\.id), ["lien.local.streak-risk.2026-10-16"], "ふたりそろった: 明日の分")
    }

    func testAnUnknownCompletionStillPlansTonightsStreakRiskWhenTheRecordContinues() {
        // 日付が変わって間もない snapshot(誰が済んだかは不明)でも、続いている記録の今夜の分は予約する
        let early = Clock.date(2026, 10, 15, 0, 10)
        XCTAssertEqual(
            risks(plan(snapshot: NotificationSnapshots.paired(updatedAt: early, streak: 23), now: early)).map(\.id),
            ["lien.local.streak-risk.2026-10-15"]
        )
        XCTAssertEqual(
            risks(plan(snapshot: NotificationSnapshots.paired(updatedAt: early, streak: 0), now: early)), [],
            "ストリークが 0 なら、続いている記録が無い"
        )
    }

    func testAYesterdaysSnapshotBuiltBeforeTheSettleHourDoesNotPlanTonight() {
        // 14 日の 0:30 に作られた snapshot(ふたりそろって見える)が、同期できないまま 15 日になった。
        // その完了は 13 日のことかもしれないので、14 日までの記録が続いているとは言えない
        let snapshot = NotificationSnapshots.paired(
            updatedAt: Clock.date(2026, 10, 14, 0, 30), meDone: true, partnerDone: true, streak: 24
        )
        XCTAssertEqual(risks(plan(snapshot: snapshot, now: Clock.date(2026, 10, 15, 8, 0))), [])
    }

    // MARK: - 日付またぎ

    func testTheWindowAndTheDoneFlagRollOverAtMidnight() {
        // 14 日の夕方に完了(今日の分を取り消し)。日付が変わると、同じ snapshot でも「今日はまだ」に戻る
        let snapshot = NotificationSnapshots.paired(updatedAt: Clock.date(2026, 10, 14, 18, 0), meDone: true)

        let evening = reminders(plan(snapshot: snapshot, now: Clock.date(2026, 10, 14, 19, 0)))
        XCTAssertEqual(evening.first?.id, "lien.local.reminder.2026-10-15", "今日の分は済み")
        XCTAssertEqual(evening.count, 13)

        let lateNight = reminders(plan(snapshot: snapshot, now: Clock.date(2026, 10, 14, 23, 59, 30)))
        XCTAssertEqual(lateNight.first?.id, "lien.local.reminder.2026-10-15")

        let nextMorning = reminders(plan(snapshot: snapshot, now: Clock.date(2026, 10, 15, 0, 0, 30)))
        XCTAssertEqual(nextMorning.first?.id, "lien.local.reminder.2026-10-15", "15 日の分。完了は昨日のものなので、出す")
        XCTAssertEqual(nextMorning.count, 14)
        XCTAssertEqual(nextMorning.last?.id, "lien.local.reminder.2026-10-28", "窓が 1 日ぶん進む")
    }

    func testMonthAndYearBoundariesAreHandledByTheCalendar() {
        let now = Clock.date(2026, 12, 25, 12, 0)
        let planned = reminders(plan(snapshot: NotificationSnapshots.paired(updatedAt: now), now: now))
        XCTAssertEqual(planned.count, 14)
        XCTAssertEqual(planned[6].id, "lien.local.reminder.2026-12-31")
        XCTAssertEqual(planned[7].id, "lien.local.reminder.2027-01-01")
        XCTAssertEqual(planned.last?.id, "lien.local.reminder.2027-01-07")
    }

    // MARK: - タイムゾーン・夏時間

    func testTheSameInstantGivesDifferentLocalDaysInDifferentTimeZones() {
        // 2026-10-14 16:00 UTC = 東京 10-15 01:00 / ロサンゼルス 10-14 09:00
        let instant = Date(timeIntervalSince1970: 1_791_993_600)
        let tokyoCalendar = Clock.calendar(Clock.tokyo)
        let laCalendar = Clock.calendar(Clock.losAngeles)
        XCTAssertEqual(LocalNotificationID.dayKey(for: instant, calendar: tokyoCalendar), "2026-10-15")
        XCTAssertEqual(LocalNotificationID.dayKey(for: instant, calendar: laCalendar), "2026-10-14")

        let snapshot = NotificationSnapshots.paired(updatedAt: instant)
        let tokyo = reminders(plan(snapshot: snapshot, now: instant, timeZone: Clock.tokyo))
        let la = reminders(plan(snapshot: snapshot, now: instant, timeZone: Clock.losAngeles))
        XCTAssertEqual(tokyo.first?.id, "lien.local.reminder.2026-10-15")
        XCTAssertEqual(la.first?.id, "lien.local.reminder.2026-10-14")
        XCTAssertEqual(tokyo.first?.fireAt.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(la.first?.fireAt.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(tokyo.first?.fireAt.hour, 20)
        XCTAssertEqual(la.first?.fireAt.hour, 20, "リマインドは、いる場所の 20 時(壁時計)")
    }

    func testReminderStaysAtTheWallClockTimeAcrossDaylightSavingChanges() {
        // ロサンゼルス: 2026-03-08 に夏時間が始まり(2:00 → 3:00)、2026-11-01 に終わる
        for start in [(2026, 3, 5), (2026, 10, 29)] {
            let now = Clock.date(start.0, start.1, start.2, 12, 0, in: Clock.losAngeles)
            let planned = reminders(plan(
                snapshot: NotificationSnapshots.paired(updatedAt: now), now: now, timeZone: Clock.losAngeles
            ))
            XCTAssertEqual(planned.count, 14, "夏時間をまたいでも 14 日ぶん")
            XCTAssertEqual(Set(ids(planned)).count, 14, "日が重複・欠落しない")
            XCTAssertTrue(planned.allSatisfy { $0.fireAt.hour == 20 && $0.fireAt.minute == 0 }, "壁時計の 20:00 のまま")
            let days = planned.map { $0.fireAt.day }
            XCTAssertEqual(days.count, Set(days).count)
        }
    }

    func testAReminderTimeThatDoesNotExistOnTheDaylightSavingDayMovesToTheNextValidTime() {
        // 2026-03-08 の LA は 2:00 〜 3:00 が存在しない。02:30 のリマインドは、その日のうちの次の有効な時刻(3:30)になる
        let now = Clock.date(2026, 3, 7, 1, 0, in: Clock.losAngeles)
        let prefs = NotificationPreferences(reminder: .daily(hour: 2, minute: 30))
        let planned = reminders(plan(
            prefs, snapshot: NotificationSnapshots.paired(updatedAt: now), now: now, timeZone: Clock.losAngeles
        ))
        let springForward = planned.first { $0.id == "lien.local.reminder.2026-03-08" }
        XCTAssertNotNil(springForward, "存在しない時刻の日も、予約が欠けない")
        XCTAssertEqual(springForward?.fireAt.day, 8)
        XCTAssertEqual(springForward?.fireAt.hour, 3)
        XCTAssertEqual(planned.count, 14)
    }

    // MARK: - 取り消し条件と予約の食い違い(NSE と共通の規則)

    func testNothingTheCancellationRuleCallsStaleIsEverPlanned() {
        // 完了の組み合わせ × ペアの有無 × snapshot の新しさ × 時刻 のすべてで、
        // 「もう出さなくてよい」(LocalNotificationCancellation)とされる識別子を、予約しない
        let calendar = Clock.calendar()
        let times = [
            Clock.date(2026, 10, 14, 6, 0), Clock.date(2026, 10, 14, 19, 59), Clock.date(2026, 10, 14, 20, 30),
            Clock.date(2026, 10, 14, 21, 30), Clock.date(2026, 10, 15, 0, 5),
        ]
        let updatedAts = [
            Clock.date(2026, 10, 14, 9, 0), Clock.date(2026, 10, 13, 22, 0), Clock.date(2026, 10, 12, 22, 0),
            Clock.date(2026, 10, 15, 9, 0),
            Clock.date(2026, 10, 14, 0, 30), Clock.date(2026, 10, 15, 0, 30), // 日付が変わって 1:00 までに作られた
        ]
        for now in times {
            for updatedAt in updatedAts {
                for meDone in [false, true] {
                    for partnerDone in [false, true] {
                        for paired in [false, true] {
                            for streak in [0, 5] {
                                var snapshot = NotificationSnapshots.paired(
                                    updatedAt: updatedAt, meDone: meDone, partnerDone: partnerDone, streak: streak
                                )
                                if !paired { snapshot.pairId = nil }
                                let planned = Set(ids(plan(snapshot: snapshot, now: now)))
                                let stale = LocalNotificationCancellation.staleIDsForToday(
                                    snapshot: snapshot, now: now, calendar: calendar
                                )
                                XCTAssertEqual(
                                    planned.intersection(stale), [],
                                    "now=\(now) updatedAt=\(updatedAt) me=\(meDone) partner=\(partnerDone) paired=\(paired) streak=\(streak)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    func testPlannedRequestsAreSortedByFireTimeAndHaveUniqueIdentifiers() {
        let now = Clock.date(2026, 10, 14, 12, 0)
        let planned = plan(snapshot: NotificationSnapshots.paired(updatedAt: now), now: now)
        XCTAssertEqual(planned.count, 15, "リマインド 14 + ストリーク危機 1")
        XCTAssertEqual(Set(ids(planned)).count, planned.count)
        XCTAssertEqual(planned.map(\.fireAt), planned.map(\.fireAt).sorted())
        // 同じ日の 20:00(リマインド)→ 21:00(ストリーク危機)の順
        XCTAssertEqual(Array(ids(planned).prefix(2)), ["lien.local.reminder.2026-10-14", "lien.local.streak-risk.2026-10-14"])
        XCTAssertLessThanOrEqual(planned.count, 64, "OS が覚えておく予約の上限(64)に収まる")
    }

    func testStreakRiskTimeMatchesTheWording() {
        // 文言の「あと3時間」は、夜 9 時から日付が変わるまで。時刻を変えるときは、文言と設定画面の「夜9時」も直す
        XCTAssertEqual(ReminderScheduler.streakRiskHour, 21)
        XCTAssertEqual(ReminderScheduler.streakRiskMinute, 0)
        XCTAssertEqual(24 - ReminderScheduler.streakRiskHour, 3)
        XCTAssertTrue(Strings.LocalNotification.streakRiskNeither(days: 5).hasPrefix("あと3時間"))
        XCTAssertTrue(Strings.NotificationSettings.streakToggle.contains("夜9時"))
        XCTAssertTrue(Strings.NotificationSettings.streakFooter.contains("夜9時"))
    }

    func testWordingNeverUsesPunitiveWords() {
        // 予約される全文言(状況の組み合わせ・名前・絵文字・日数)が、罰なし文言の lint を通る
        let now = Clock.date(2026, 10, 14, 12, 0)
        var bodies: [String] = []
        for (meDone, partnerDone) in [(false, false), (true, false), (false, true), (true, true)] {
            for name in StringsCatalog.representativeNames {
                for streak in [1, 23, 365] {
                    let snapshot = NotificationSnapshots.paired(
                        updatedAt: now, meDone: meDone, partnerDone: partnerDone, streak: streak, partnerName: name
                    )
                    bodies += plan(snapshot: snapshot, now: now).map(\.body)
                }
            }
        }
        XCTAssertGreaterThan(bodies.count, 100)
        for body in bodies {
            XCTAssertEqual(PunishmentFreeLint.violations(in: body), [], body)
        }
    }
}
