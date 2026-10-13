// SettingsViewModel.swift — 設定画面の状態管理(REQUIREMENTS §3.15 / T23 #23)
//
// 設定画面(ホームの歯車から開くシート)が出すもの:
//   - プロフィール(ニックネームとアイコンの表示と編集 — 編集は ProfileEditViewModel)・約束(編集は約束設定の画面を開く)・
//     通知(リマインド・ストリーク危機。画面は NotificationSettingsView)
//   - ペア(相手の名前と「ペアを解消する」= ブロック)
//   - サポート(お問い合わせ・通報・利用規約・プライバシーポリシー)
//   - アカウント(サインアウト・アカウントの削除)
//
// - 状態の正はサーバー(DESIGN §3.3)。ニックネームと約束(リマインド時刻まで)は、開くたびにサーバーの自分の行から読む。
//   読めなかったとき(オフライン等)は、約束の編集を開けないようにする(リマインド時刻が分からないまま保存すると、
//   リマインドを消してしまうため)。ペアの有無と相手の名前は端末の snapshot(App Group)から
// - ペアの解消とアカウントの削除は、確認の2段階(DestructiveFlow)を経てからだけ実行される
// - 実際の操作(サーバー呼び出し・端末の記録の消去・オンボーディングへの復帰)は AccountOperating(実体は AppModel)

import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed
    }

    private(set) var loadState: LoadState = .loading
    /// 自分の users 行のプロフィール(読めるまで nil)
    private(set) var profile: UserProfile?
    /// 約束の編集の元(サーバーから読んだ、リマインド時刻つきの値)。読めるまで nil
    private(set) var promise: Promise?
    /// 端末の snapshot(ペアの有無・相手の名前・約束の表示)
    private(set) var snapshot: PairSnapshot?
    /// 約束を保存した直後の一言を出すか
    private(set) var showsPromiseSavedNote = false
    /// プロフィールを保存した直後の一言を出すか
    private(set) var showsProfileSavedNote = false
    /// サインアウトの確認(1段階のアラート)を出すか
    var showsSignOutConfirmation = false

    /// ペアの解消(= ブロック)。確認は2段階
    let dissolve: DestructiveFlow
    /// アカウントの削除。確認は2段階
    let deletion: DestructiveFlow

    private let auth: AuthServicing
    private let store: AppGroupStore?
    private let account: AccountOperating
    private let now: () -> Date
    private let appVersion: String

    init(
        auth: AuthServicing,
        store: AppGroupStore?,
        account: AccountOperating,
        now: @escaping () -> Date = Date.init,
        appVersion: String = ReportContext.appVersionText()
    ) {
        self.auth = auth
        self.store = store
        self.account = account
        self.now = now
        self.appVersion = appVersion
        self.snapshot = store?.loadSnapshot()
        self.dissolve = DestructiveFlow(
            errorText: Strings.Dissolve.errorMessage,
            operation: { [account] in try await account.dissolvePair() }
        )
        self.deletion = DestructiveFlow(
            errorText: Strings.DeleteAccount.errorMessage,
            operation: { [account] in try await account.deleteAccount() }
        )
        // 解消が済んだら、画面の表示(ペアの有無)を端末の snapshot から読み直す
        // (AppModel が snapshot をソロの形に書いたあとに呼ばれる)
        dissolve.onSucceeded = { [weak self] in self?.refreshSnapshot() }
    }

    // MARK: 表示

    var isPaired: Bool {
        snapshot?.pairId != nil
    }

    /// ペアの相手の名前(ペアが無い・名前が読めないときは nil)
    var partnerName: String? {
        guard isPaired else { return nil }
        return snapshot?.partnerName
    }

    /// 約束の表示用の文("💪 筋トレ")。サーバーから読めた値を優先し、無ければ snapshot の値
    var promiseSummary: String? {
        if let promise {
            return [promise.emoji, promise.title].filter { !$0.isEmpty }.joined(separator: " ")
        }
        guard let snapshot, snapshot.hasActivePromise, let title = snapshot.myPromiseTitle else { return nil }
        return [snapshot.myPromiseEmoji, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 約束の編集を開けるか(サーバーの値が読めているときだけ。読めていない間は元のリマインド時刻が分からない)
    var canEditPromise: Bool {
        promise != nil
    }

    var versionText: String {
        appVersion
    }

    // MARK: 読み込み

    /// 設定画面を開いたとき(と「もう一度ためす」)。ニックネームと約束をサーバーから読み、snapshot も読み直す
    func load() async {
        snapshot = store?.loadSnapshot()
        loadState = .loading
        do {
            let profile = try await auth.fetchProfile()
            let promise = try await auth.fetchMyPromise()
            self.profile = profile
            self.promise = promise ?? fallbackPromise()
            loadState = .loaded
        } catch {
            loadState = .failed
        }
    }

    /// ペアの解消のあとなど、端末の snapshot が変わったとき
    func refreshSnapshot() {
        snapshot = store?.loadSnapshot()
    }

    // MARK: プロフィールの編集

    /// 編集画面の状態を作る(編集画面を開くたびに 1 つ)。サーバーから読めていない間は nil
    /// (いまの値が分からないまま保存すると、読めていないニックネームを空で上書きしかねない)
    func makeProfileEditor() -> ProfileEditViewModel? {
        guard loadState == .loaded, let profile else { return nil }
        return ProfileEditViewModel(profile: profile, auth: auth, onSaved: { [weak self] saved in
            self?.profileSaved(saved)
        })
    }

    /// プロフィールを保存できた(編集画面から)。設定画面の表示を新しい値にする
    func profileSaved(_ saved: UserProfile) {
        profile = saved
        showsProfileSavedNote = true
    }

    /// 約束設定の画面で保存できた
    func promiseSaved(_ saved: Promise) {
        promise = saved
        showsPromiseSavedNote = true
        snapshot = store?.loadSnapshot()
    }

    /// 通知の設定画面でリマインドを保存できた(約束のほかの項目は変わらない)。約束の行の「保存しました」は出さない
    func reminderSaved(_ saved: Promise) {
        promise = saved
    }

    /// サーバーに現役の約束が無いのに snapshot には約束が残っている(スタブ構成・古い snapshot)ときの代わり。
    /// リマインド時刻は分からないので nil(約束設定の画面ではリマインドなしで開く)
    private func fallbackPromise() -> Promise? {
        guard let snapshot, snapshot.hasActivePromise, let title = snapshot.myPromiseTitle else { return nil }
        return Promise(id: "", title: title, emoji: snapshot.myPromiseEmoji ?? "", remindAt: nil)
    }

    // MARK: サインアウト

    func requestSignOut() {
        showsSignOutConfirmation = true
    }

    func cancelSignOut() {
        showsSignOutConfirmation = false
    }

    /// サインアウトの確認の「サインアウト」
    func confirmSignOut() async {
        showsSignOutConfirmation = false
        await account.signOut()
    }

    // MARK: メール(通報・お問い合わせ)

    private var reportContext: ReportContext {
        ReportContext.current(pairId: store?.loadSnapshot()?.pairId, now: now())
    }

    /// 設定の「不適切な内容を通報する」。特定の対象を持たない通報の下書き
    func generalReportURL() -> URL? {
        ReportComposer.reportURL(target: .general, context: reportContext)
    }

    /// 設定の「お問い合わせ」
    func contactURL() -> URL? {
        ReportComposer.contactURL(context: reportContext)
    }
}
