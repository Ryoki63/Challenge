// ReminderScheduler.swift — 端末のローカル通知(リマインド・ストリーク危機)の予約(REQUIREMENTS §3.12 / DESIGN §4 / T16 #16)
//
// v1.0 のローカル通知は 2 つだけ。サーバーからの通知(相手のチェックイン・つつく・リアクションなど)とは別で、
// 配送の主体は**端末**(サーバーの cron は使わない)。節目(7/30/100日)の通知は出さない(アプリ内のお祝いは T22)。
//
//   リマインド        約束の remind_at(毎日)。その日、自分が完了していれば出さない
//   ストリーク危機     夜 9 時。ふたりの記録が続いていて、その日まだふたりそろっていないとき。ふたりそろったら出さない
//
// 予約のしかた(「先の 14 日ぶんを、日付つきの 1 回きりの通知として」— ReminderScheduler+Plan.swift)
//   毎日くり返す通知(repeats: true)は「今日だけ出さない」ができない(消すと明日以降も止まる)。そこで、日付ごとの 1 回きりの
//   通知を先の 14 日ぶん予約し、アプリが状態を知るたびに作り直す。作り直す契機(AppModel / HomeViewModel / 設定画面から sync()):
//   起動・前面復帰・サーバーとの同期・自分のチェックインと取り消し・約束の保存・ペアの成立と解消・サインアウト。
//   14 日アプリを開かなかった人には、その先は届かない(静かに終わる。通知を出し続けない)。
//   予約の内容は純粋関数 desiredRequests で決め、OS に残っている予約と比べて、足りないものを足し・要らないものを消す
//   (同じ内容なら触らない = 何度呼んでも同じ。ペンディングの上限 64 件には、最大でも 14 + 1 件(リマインド 14 + ストリーク危機 1)で収まる)
//
// 「その日はもう出さない」の判断は、アプリの同期(ここ)と NSE で同じ規則を使う(LocalNotificationCancellation)。
//
// 取り消せなかったとき(NSE):
//   ふたりそろったことが分かったら、今日の夜 9 時の通知を取り消す。分かる経路は 2 つ:
//     ① アプリが同期したとき(前面復帰・自分のチェックイン・push の受信)— sync() の合わせ込みで消し、
//        配信済みの通知も通知センターから外す
//     ② 相手のチェックインの push を NSE が受けたとき — NSE が今日の分の予約を removePendingNotificationRequests で消す。
//        **NSE が本体のアプリの予約を消せるかは、実機でしか確かめられず、まだ確かめていない**(T20。ios/README.md §12)
//   ②が効かなかったとき(NSE が消せない・相手の push が届かない・通知の許可が無いなど)のふるまいは、テストで固定している
//   (ReminderSchedulerLearningTests / LocalNotificationRulesTests):
//     - 夜 9 時の通知は、ふたりそろっていても予約が残るので、そのまま届く。文言はそのとき読んでも困らない言い方にしてある
//       (「いっしょに守ろう」— Strings.LocalNotification。責めない・脅さない)
//     - アプリが前面にいる間に届いたものは、出さずに捨てる(AppDelegate.willPresent → shouldSuppress)
//     - 次にアプリを開いたとき、今日の分を消し(上の①)、配信済みの通知も外す
//   最悪でも「ふたりそろった日の夜 9 時に、読んで困らない通知が 1 回届く」だけで、記録(ストリーク)には影響しない。
//
// 約束のリマインド時刻の出どころ(NotificationPreferences.reminder): 約束の remind_at が正。この端末が知らない間は、
// 予約の前にサーバーの約束から一度読む(loader)。読めなかったら予約せず、次の同期でもう一度ためす(読み直しの間隔は 5 分)。

import Foundation

// MARK: - 外から使う口

/// ローカル通知の管理の口(AppModel・設定画面が使う。テストは偽物を注入する)。
/// 操作はすべて @MainActor(プロトコル全体には付けない: 付けると、本体のクラスまで MainActor に縛られて、
/// AppServices の組み立てが MainActor の中でしかできなくなる)
protocol ReminderManaging: AnyObject {
    /// 端末が覚えているローカル通知の設定
    @MainActor var preferences: NotificationPreferences { get }
    /// 端末の状態(snapshot・設定)を読み、予約中のローカル通知を合わせる。同時に走るのは 1 本で、
    /// 走行中に来た要求は、終わった直後に 1 回だけ取り直す(呼び出し側は、その取り直しが終わるまで待つ)
    @MainActor func sync() async
    /// 約束を保存した・設定画面でリマインドを変えた。その約束の remind_at を、この端末が覚えるリマインドの時刻にする
    /// (予約への反映は、続けて sync() を呼ぶ)
    @MainActor func recordReminder(from promise: Promise)
    /// ストリーク危機(夜 9 時)のオン・オフ。端末ローカルの設定を保存して、予約を合わせる
    @MainActor func setStreakRiskEnabled(_ enabled: Bool) async
    /// サインアウト・アカウントの削除のあと: 設定を消し、予約も配信済みの通知も残さない
    @MainActor func reset() async
    /// OS の通知許可の状態(設定画面の案内用)
    @MainActor func authorizationStatus() async -> NotificationAuthorization
}

// MARK: - 本体

/// クラス自体は MainActor に縛らない(AppServices の組み立てが MainActor の外でも行われるため)。
/// 状態を持つ・動かす操作はすべて @MainActor(ReminderManaging の約束)
final class ReminderScheduler: ReminderManaging {
    /// サーバーの約束から、リマインドの時刻を読む。読めたら `.off` か `.daily`、読めなかった(通信の失敗など)ら nil
    typealias ReminderLoader = @MainActor () async -> ReminderPreference?

    /// 約束のリマインドを、この端末が知らない間に読み直す最短の間隔(秒。通信の失敗が続くときに、同期のたびに叩かない)
    static let loadRetryInterval: TimeInterval = 300

    private let center: NotificationScheduling
    private let preferencesStore: NotificationPreferencesStoring
    private let snapshotSource: @MainActor () -> PairSnapshot?
    private let reminderLoader: ReminderLoader?
    private let now: @MainActor () -> Date
    private let makeCalendar: @MainActor () -> Calendar

    @MainActor private var isSyncing = false
    @MainActor private var resyncRequested = false
    @MainActor private var waiters: [CheckedContinuation<Void, Never>] = []
    /// サーバーの約束からリマインドの時刻を読んでいる最中の処理(同期の外で走る。1 本だけ)
    @MainActor private var learningTask: Task<Void, Never>?
    @MainActor private var lastLoadAttempt: Date?
    /// reset() のたびに進む。読み込みの最中にサインアウトされたとき、前のアカウントの約束の結果を捨てる
    @MainActor private var generation = 0

    init(
        center: NotificationScheduling,
        preferences: NotificationPreferencesStoring,
        snapshotSource: @escaping @MainActor () -> PairSnapshot?,
        reminderLoader: ReminderLoader? = nil,
        now: @escaping @MainActor () -> Date = Date.init,
        calendar: @escaping @MainActor () -> Calendar = LocalNotificationCalendar.current
    ) {
        self.center = center
        self.preferencesStore = preferences
        self.snapshotSource = snapshotSource
        self.reminderLoader = reminderLoader
        self.now = now
        self.makeCalendar = calendar
    }

    @MainActor var preferences: NotificationPreferences {
        preferencesStore.load()
    }

    /// サーバーの約束からリマインドの時刻を読んでいる最中か(テストが観測する)
    @MainActor var isLearningReminder: Bool {
        learningTask != nil
    }

    // MARK: 設定の変更

    @MainActor func recordReminder(from promise: Promise) {
        var updated = preferencesStore.load()
        updated.reminder = ReminderPreference(remindAt: promise.remindAt)
        preferencesStore.save(updated)
    }

    @MainActor func setStreakRiskEnabled(_ enabled: Bool) async {
        var updated = preferencesStore.load()
        updated.streakRiskEnabled = enabled
        preferencesStore.save(updated)
        await sync()
    }

    @MainActor func reset() async {
        generation += 1
        learningTask?.cancel()
        learningTask = nil
        preferencesStore.clear()
        lastLoadAttempt = nil
        // snapshot が無い(消したあと)ので、予約も配信済みも残らない。走行中の同期があれば、その終わりに取り直される
        await sync()
    }

    @MainActor func authorizationStatus() async -> NotificationAuthorization {
        await center.authorizationStatus()
    }

    // MARK: 同期

    @MainActor func sync() async {
        if isSyncing {
            // 走っている同期が、終わった直後に 1 回だけ取り直す。その取り直しが終わるまで待つ
            resyncRequested = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isSyncing = true
        repeat {
            resyncRequested = false
            await syncOnce()
        } while resyncRequested
        isSyncing = false
        let finished = waiters
        waiters = []
        for waiter in finished { waiter.resume() }
    }

    @MainActor private func syncOnce() async {
        learnReminderIfNeeded()

        // 読み取りから計算までは await を挟まない(途中で状態が変わっても、読んだ値の組で一貫した予約になる)
        let prefs = preferencesStore.load()
        let snapshot = snapshotSource()
        let current = now()
        let calendar = makeCalendar()
        let desired = Self.desiredRequests(prefs: prefs, snapshot: snapshot, now: current, calendar: calendar)

        // 予約: OS に残っている予約と比べて、要らないもの(計算に無い識別子)を消し、足りないもの・内容が違うものを
        // 置く(同じ識別子の予約は置き換わる)。内容が同じものは触らない
        let pending = await center.pendingLocalNotifications()
        let desiredByID = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(pending.filter { desiredByID[$0.id]?.matches(pending: $0) == true }.map(\.id))
        let obsolete = Set(pending.map(\.id)).subtracting(desiredByID.keys).sorted()
        if !obsolete.isEmpty {
            await center.removePending(ids: obsolete)
        }
        for notification in desired where !kept.contains(notification.id) {
            await center.schedule(notification)
        }

        await dismissDeliveredNotifications(snapshot: snapshot, now: current, calendar: calendar)
    }

    /// 通知センターに残っている、もう古い通知を外す(リマインドを出したあとで完了した / ふたりそろった)。
    /// snapshot が無い(サインアウト後)ときは、このアプリのローカル通知をすべて外す
    @MainActor private func dismissDeliveredNotifications(snapshot: PairSnapshot?, now: Date, calendar: Calendar) async {
        guard let snapshot else {
            let delivered = await center.deliveredLocalNotificationIDs()
            if !delivered.isEmpty { await center.removeDelivered(ids: delivered) }
            return
        }
        let stale = LocalNotificationCancellation.staleIDsForToday(snapshot: snapshot, now: now, calendar: calendar)
        guard !stale.isEmpty else { return }
        let delivered = Set(await center.deliveredLocalNotificationIDs())
        let toRemove = stale.filter(delivered.contains)
        if !toRemove.isEmpty { await center.removeDelivered(ids: toRemove) }
    }

    /// リマインドの時刻をこの端末がまだ知らない(`.unknown`)なら、サーバーの約束から読み始める。
    /// 約束があるときだけ(無い間は読むものが無い)。**同期の中では待たない**: 通信が詰まっても、自分のチェックインによる
    /// 取り消しやサインアウトの後始末を遅らせないため。読めたら設定に保存して、もう一度同期する(そこで予約される)。
    /// 読めなければ何もしない(リマインドは予約しない)で、一定の間隔(loadRetryInterval)をあけて読み直す
    @MainActor private func learnReminderIfNeeded() {
        guard
            learningTask == nil,
            preferencesStore.load().reminder == .unknown,
            let reminderLoader,
            let snapshot = snapshotSource(), snapshot.hasActivePromise
        else { return }
        let attempt = now()
        if let last = lastLoadAttempt, attempt.timeIntervalSince(last) < Self.loadRetryInterval { return }
        lastLoadAttempt = attempt

        let startedIn = generation
        learningTask = Task { @MainActor [weak self] in
            let loaded = await reminderLoader()
            guard let self else { return }
            // サインアウトされていたら、前のアカウントの約束の結果は使わない(reset が learningTask も片づけている)
            guard startedIn == self.generation else { return }
            self.learningTask = nil
            guard let loaded, loaded != .unknown else { return }
            // 読んでいる間に、約束の保存などで確かな値が入っていたら、そちらを優先する
            var latest = self.preferencesStore.load()
            guard latest.reminder == .unknown else { return }
            latest.reminder = loaded
            self.preferencesStore.save(latest)
            await self.sync()
        }
    }
}
