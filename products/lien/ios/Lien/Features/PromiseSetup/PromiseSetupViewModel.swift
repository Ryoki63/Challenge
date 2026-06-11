// PromiseSetupViewModel.swift — 約束設定画面の状態管理(T12 / REQUIREMENTS §3.3)
//
// - 入力: タイトル(20字・コードポイント数え=DB の char_length と一致)+絵文字(固定候補)
//   +リマインド toggle(時刻のデフォルト 20:00。ローカル通知のスケジューリングは T16 の責務)
// - save(): PromiseAPIClient.setPromise → 成功で App Group snapshot の
//   myPromiseTitle / myPromiseEmoji を更新(ウィジェットへの楽観反映。正はサーバーで、
//   次の GET /snapshot・push 同梱 snapshot で収束する — DESIGN §4)→ onSaved
// - 編集時は existing を渡してプリフィル。編集してもサーバー側で同一 promise_id への
//   UPDATE になるためストリークに影響しない(寛容設計 — §3.3)
// - LienApp への画面結線は T13 ホーム画面の責務(本タスクでは独立フィーチャー — issue #12)

import Foundation
import Observation

@MainActor
@Observable
final class PromiseSetupViewModel {
    /// タイトル検証エラー(REQUIREMENTS §3.3: 20字まで)
    enum TitleError {
        case empty
        case tooLong
    }

    static let titleMaxLength = Promise.titleMaxLength

    /// リマインド時刻のデフォルト 20:00(21:00 のストリーク危機通知 — §3.5 — より前)
    static let defaultRemindHour = 20
    static let defaultRemindMinute = 0

    // MARK: - 入力状態(View からバインド)

    var title = ""
    var emoji = Strings.PromiseSetup.emojiPalette.first ?? "💪"
    var remindEnabled = true
    /// リマインド時刻(時・分のみ意味を持つ。DatePicker バインド用に Date で保持)
    var remindTime: Date

    // MARK: - 画面状態

    private(set) var isSaving = false
    /// 保存失敗時のユーザー向けメッセージ(同じ画面に留まり、リトライで再送信できる)
    private(set) var saveErrorMessage: String?

    // MARK: - 依存(モック注入可能)

    private let client: PromiseAPIClient
    /// 保存成功時の snapshot 反映先(エンタイトルメント未解決環境では nil — 反映はスキップ)
    private let store: AppGroupStore?
    private let calendar: Calendar
    private let onSaved: (Promise) -> Void

    init(
        client: PromiseAPIClient,
        store: AppGroupStore?,
        existing: Promise? = nil,
        calendar: Calendar = .current,
        onSaved: @escaping (Promise) -> Void = { _ in }
    ) {
        self.client = client
        self.store = store
        self.calendar = calendar
        self.onSaved = onSaved
        self.remindTime = Self.time(
            hour: Self.defaultRemindHour,
            minute: Self.defaultRemindMinute,
            calendar: calendar
        )
        if let existing {
            title = existing.title
            emoji = existing.emoji
            if let parsed = Self.parseRemindAt(existing.remindAt, calendar: calendar) {
                remindEnabled = true
                remindTime = parsed
            } else {
                remindEnabled = false
            }
        }
    }

    // MARK: - 検証

    /// 前後の空白・改行を除いた送信用タイトル
    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil なら送信可。DB の check(char_length <= 20)と同じ数え方
    /// (Unicode コードポイント = unicodeScalars)で検証する
    var titleError: TitleError? {
        let trimmed = trimmedTitle
        if trimmed.isEmpty { return .empty }
        if trimmed.unicodeScalars.count > Self.titleMaxLength { return .tooLong }
        return nil
    }

    var canSave: Bool {
        titleError == nil && !isSaving
    }

    /// サーバーへ送る remindAt("HH:MM"。toggle オフは nil)
    var remindAtToSend: String? {
        guard remindEnabled else { return nil }
        let c = calendar.dateComponents([.hour, .minute], from: remindTime)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - 保存

    func save() async {
        guard canSave else { return }
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }
        do {
            let promise = try await client.setPromise(
                title: trimmedTitle,
                emoji: emoji,
                remindAt: remindAtToSend
            )
            // ウィジェット表示用に snapshot へ楽観反映(失敗しても遷移は続行 —
            // サーバー側 snapshot で自己修復する設計 — DESIGN §4)
            applyToSnapshot(promise)
            onSaved(promise)
        } catch {
            saveErrorMessage = Strings.PromiseSetup.saveErrorMessage
        }
    }

    /// 自分の約束を App Group snapshot に反映する。
    /// snapshot がまだ無い(オンボ直後のソロ)場合は最小のソロ snapshot を作る
    private func applyToSnapshot(_ promise: Promise) {
        guard let store else { return }
        if var snapshot = store.loadSnapshot() {
            snapshot.myPromiseTitle = promise.title
            snapshot.myPromiseEmoji = promise.emoji
            try? store.saveSnapshot(snapshot)
        } else {
            try? store.saveSnapshot(PairSnapshot(
                schemaVersion: PairSnapshot.currentSchemaVersion,
                pairId: nil,
                updatedAt: Date(),
                streakCurrent: 0,
                streakBest: 0,
                todayMeDone: false,
                todayPartnerDone: false,
                myPromiseTitle: promise.title,
                myPromiseEmoji: promise.emoji,
                partnerName: nil,
                partnerPromiseTitle: nil,
                partnerPromiseEmoji: nil,
                plantStage: 0,
                plantMood: .normal,
                plantName: nil,
                hasPartnerPhotoToday: false
            ))
        }
    }

    // MARK: - 時刻ヘルパ

    /// 今日の hour:minute を指す Date(DatePicker 初期値用)
    private static func time(hour: Int, minute: Int, calendar: Calendar) -> Date {
        calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    /// "HH:MM"(サーバー表現)→ Date。形式不正・nil は nil
    private static func parseRemindAt(_ remindAt: String?, calendar: Calendar) -> Date? {
        guard let remindAt else { return nil }
        let parts = remindAt.split(separator: ":")
        guard
            parts.count == 2,
            let hour = Int(parts[0]), (0...23).contains(hour),
            let minute = Int(parts[1]), (0...59).contains(minute)
        else { return nil }
        return time(hour: hour, minute: minute, calendar: calendar)
    }
}
