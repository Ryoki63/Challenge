// NotificationSettingsViewModel.swift — 通知の設定画面の状態管理(REQUIREMENTS §3.12・§3.15 / T16 #16)
//
// 設定 → 通知。v1.0 のアプリ内で切り替えられるのは、ローカル通知の次の 3 つだけ:
//   - リマインド(ON/OFF・時刻): **約束の remind_at が正**(約束設定の画面と同じ値)。保存すると、約束を更新する(promise-set。
//     タイトルと絵文字は読んだままを送る)ので、サーバーに届いてから端末の予約に反映する。草稿を持ち、「保存する」で確定する
//     (時刻を回している途中で、通信しない)。サーバーの約束が読めない間は変えられない(元の値が分からないまま保存しない)
//   - ストリーク危機(夜 9 時)の ON/OFF: 端末ローカル。変えたらすぐ保存して予約を合わせる(通信しない)
// 相手名義の通知(チェックイン・つつく・リアクション)の ON/OFF は v1.0 ではアプリの中では切り替えられない(サーバー側の通知設定は
// v1.1 — D3)。iOS の設定アプリで通知をオフにすると、Lien の通知がすべて止まる。
// OS の通知許可が「拒否」のときは案内を出す。「まだ」のときは、リマインドかストリーク危機を ON にしたときに許可を求め、
// 許可されたら予約を合わせ直す(許可が無い間は、OS が予約を断っているかもしれない)。
// (オンボーディングで「あとで」を選んだ人が、あとから使い始められるように)。

import Foundation
import Observation

@MainActor
@Observable
final class NotificationSettingsViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed
    }

    private(set) var loadState: LoadState = .loading
    /// OS の通知許可の状態。読むまでは「許可」とみなす(拒否の案内を一瞬出さない)
    private(set) var authorization: NotificationAuthorization = .authorized
    /// サーバーから読めた、自分の現役の約束(リマインドを保存するときのタイトルと絵文字の元)
    private(set) var promise: Promise?

    // 草稿(リマインド)。「保存する」で確定する
    var reminderEnabled = true
    var reminderTime: Date

    /// ストリーク危機(夜 9 時)。端末ローカルの設定
    private(set) var streakRiskEnabled: Bool

    private(set) var isSaving = false
    /// 保存に失敗したときのメッセージ(責めない文言)
    private(set) var saveErrorMessage: String?
    /// 保存できた直後の一言
    private(set) var showsSavedNote = false

    private let auth: AuthServicing
    private let promiseClient: PromiseAPIClient
    private let reminders: ReminderManaging
    private let authorizer: PushAuthorizing
    private let calendar: Calendar
    /// リマインドを保存できた(約束の更新が済んだ)。設定画面と AppModel が、表示と端末の予約を更新する
    private let onReminderSaved: (Promise) -> Void

    init(
        auth: AuthServicing,
        promiseClient: PromiseAPIClient,
        reminders: ReminderManaging,
        authorizer: PushAuthorizing,
        calendar: Calendar = .current,
        onReminderSaved: @escaping (Promise) -> Void = { _ in }
    ) {
        self.auth = auth
        self.promiseClient = promiseClient
        self.reminders = reminders
        self.authorizer = authorizer
        self.calendar = calendar
        self.onReminderSaved = onReminderSaved
        self.streakRiskEnabled = reminders.preferences.streakRiskEnabled
        self.reminderTime = Self.time(hour: PromiseSetupViewModel.defaultRemindHour,
                                      minute: PromiseSetupViewModel.defaultRemindMinute,
                                      calendar: calendar)
    }

    // MARK: 表示

    /// リマインドを変えられるか(サーバーの現役の約束が読めているときだけ)
    var canEditReminder: Bool {
        loadState == .loaded && promise != nil
    }

    /// 約束がまだ無い(約束を決める前に設定を開いた)
    var hasNoPromise: Bool {
        loadState == .loaded && promise == nil
    }

    /// 草稿が、保存済みの値(約束の remind_at)と違うか
    var isReminderDirty: Bool {
        guard let promise else { return false }
        switch ReminderPreference(remindAt: promise.remindAt) {
        case .daily(let hour, let minute):
            let draft = draftTime
            return !reminderEnabled || draft.hour != hour || draft.minute != minute
        case .off, .unknown:
            return reminderEnabled
        }
    }

    var canSaveReminder: Bool {
        canEditReminder && isReminderDirty && !isSaving
    }

    /// 約束へ送る remind_at("HH:MM"。オフは nil)
    var reminderAtToSend: String? {
        guard reminderEnabled else { return nil }
        return String(format: "%02d:%02d", draftTime.hour, draftTime.minute)
    }

    // MARK: 読み込み

    /// 画面を開いたとき(と「もう一度ためす」)。端末の設定・OS の許可・サーバーの約束を読む
    func load() async {
        streakRiskEnabled = reminders.preferences.streakRiskEnabled
        authorization = await reminders.authorizationStatus()
        loadState = .loading
        do {
            let fetched = try await auth.fetchMyPromise()
            promise = fetched
            applyDraft(from: fetched?.remindAt)
            loadState = .loaded
        } catch {
            loadState = .failed
        }
    }

    /// iOS の設定アプリから戻ってきたとき(許可の状態が変わっているかもしれない)
    func refreshAuthorization() async {
        authorization = await reminders.authorizationStatus()
    }

    // MARK: リマインドの保存

    func saveReminder() async {
        guard canSaveReminder, let promise else { return }
        isSaving = true
        saveErrorMessage = nil
        showsSavedNote = false
        defer { isSaving = false }
        do {
            // 約束の絵文字は UI から廃止した(2026-10-26)が、サーバーの promise-set は emoji 必須(空は不可)。
            // いまの約束に絵文字が入っていればそのまま返し(ここで変えない)、空なら固定値を送る
            let saved = try await promiseClient.setPromise(
                title: promise.title,
                emoji: promise.emoji.isEmpty ? PromiseSetupViewModel.placeholderEmoji : promise.emoji,
                remindAt: reminderAtToSend
            )
            self.promise = saved
            applyDraft(from: saved.remindAt)
            showsSavedNote = true
            onReminderSaved(saved)
            if reminderEnabled { await requestAuthorizationIfNeeded() }
        } catch {
            saveErrorMessage = Strings.NotificationSettings.reminderSaveError
        }
    }

    // MARK: ストリーク危機

    /// スイッチの操作。画面の値は**その場で**変え(いったん元に戻って見えない)、保存と予約は続けて行う。
    /// 戻り値の Task は、保存と予約が終わるまで(テストが待つ)
    @discardableResult
    func streakRiskToggled(to enabled: Bool) -> Task<Void, Never> {
        streakRiskEnabled = enabled
        return Task { await persistStreakRisk(enabled) }
    }

    /// 端末ローカルの設定。すぐ保存して、予約を合わせる(通信しない)
    func setStreakRiskEnabled(_ enabled: Bool) async {
        streakRiskEnabled = enabled
        await persistStreakRisk(enabled)
    }

    private func persistStreakRisk(_ enabled: Bool) async {
        await reminders.setStreakRiskEnabled(enabled)
        if enabled { await requestAuthorizationIfNeeded() }
    }

    // MARK: 許可

    /// 許可をまだ聞いていないとき(オンボーディングで「あとで」を選んだ)だけ、OS のダイアログを出す。
    /// 拒否されているときは出せないので、画面の案内(iOS の設定アプリへ)に任せる。
    /// 許可されたら、予約を合わせ直す: 許可が出る前の予約は、OS に断られて残っていないかもしれない
    private func requestAuthorizationIfNeeded() async {
        guard await reminders.authorizationStatus() == .notDetermined else { return }
        let granted = await authorizer.requestAuthorization()
        authorization = await reminders.authorizationStatus()
        if granted { await reminders.sync() }
    }

    // MARK: 草稿 ⇔ 約束の remind_at

    private var draftTime: (hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.hour, .minute], from: reminderTime)
        return (parts.hour ?? 0, parts.minute ?? 0)
    }

    private func applyDraft(from remindAt: String?) {
        switch ReminderPreference(remindAt: remindAt) {
        case .daily(let hour, let minute):
            reminderEnabled = true
            reminderTime = Self.time(hour: hour, minute: minute, calendar: calendar)
        case .off, .unknown:
            reminderEnabled = false
            reminderTime = Self.time(hour: PromiseSetupViewModel.defaultRemindHour,
                                     minute: PromiseSetupViewModel.defaultRemindMinute,
                                     calendar: calendar)
        }
    }

    private static func time(hour: Int, minute: Int, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}

// MARK: - 設定画面の行の右側(いまの状態)

extension ReminderPreference {
    /// 「毎日 20:00」/「オフ」。まだ知らない(`.unknown`)ときは nil(何も出さない)
    var summaryText: String? {
        switch self {
        case .unknown: return nil
        case .off: return Strings.NotificationSettings.summaryOff
        case .daily: return remindAt.map(Strings.NotificationSettings.summaryDaily)
        }
    }
}
