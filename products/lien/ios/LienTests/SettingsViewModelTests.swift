// SettingsViewModelTests.swift — 設定画面の状態管理(T23 #23 / REQUIREMENTS §3.15)
//
// 検証対象(SettingsViewModel.swift):
//   - ニックネームと約束(リマインド時刻つき)をサーバーの自分の行から読む / 読めなかったときは約束の編集を開けない
//   - ペアの有無・相手の名前は端末の snapshot から
//   - ペアの解消・アカウントの削除は、確認の2段階を経てからだけ AccountOperating を呼ぶ
//   - サインアウトの確認(1段階)
//   - 通報・お問い合わせのメール(ペア ID を入れる)

import XCTest
@testable import Lien

// MARK: - モック(トップレベル: テストクラスの隔離を継承させない)

private final class SettingsMockAuth: AuthServicing {
    var profileResult: Result<UserProfile, Error> = .success(UserProfile(nickname: "あきら", avatarEmoji: "🌱"))
    var promiseResult: Result<Promise?, Error> = .success(nil)
    private(set) var profileFetches = 0
    private(set) var promiseFetches = 0

    var currentUserID: UUID? { UUID() }

    @discardableResult
    func signInAnonymously() async throws -> UUID { UUID() }
    func updateProfile(nickname: String, avatarEmoji: String, timezone: String) async throws {}
    func accessToken() async throws -> String { "token" }
    func fetchProfile() async throws -> UserProfile {
        profileFetches += 1
        return try profileResult.get()
    }
    func fetchMyPromise() async throws -> Promise? {
        promiseFetches += 1
        return try promiseResult.get()
    }
    func signOut() async {}
}

@MainActor
private final class MockAccount: AccountOperating {
    private(set) var dissolveCount = 0
    private(set) var deleteCount = 0
    private(set) var signOutCount = 0
    var dissolveError: Error?
    var deleteError: Error?
    /// 解消が成功したとき、端末の snapshot をソロの形に書き換える先(AppModel と同じ動き)
    var store: AppGroupStore?

    func dissolvePair() async throws {
        dissolveCount += 1
        if let dissolveError { throw dissolveError }
        if let store, let current = store.loadSnapshot() {
            try store.saveSnapshot(current.dissolved(updatedAt: current.updatedAt))
        }
    }

    func deleteAccount() async throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
    }

    func signOut() async {
        signOutCount += 1
    }
}

private struct Offline: Error {}

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private struct Rig {
        let vm: SettingsViewModel
        let auth: SettingsMockAuth
        let account: MockAccount
        let temp: TempStore
    }

    private func makeRig(snapshot: PairSnapshot? = SnapshotFactory.paired()) throws -> Rig {
        let temp = TempStore()
        if let snapshot { try temp.store.saveSnapshot(snapshot) }
        let auth = SettingsMockAuth()
        let account = MockAccount()
        account.store = temp.store
        let vm = SettingsViewModel(
            auth: auth,
            store: temp.store,
            account: account,
            now: { SnapshotFactory.fixedDate },
            appVersion: "1.0.0 (7)"
        )
        return Rig(vm: vm, auth: auth, account: account, temp: temp)
    }

    private let savedPromise = Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: "20:30")

    // MARK: 読み込み

    func testLoadReadsProfileAndPromiseFromTheServer() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }
        rig.auth.promiseResult = .success(savedPromise)
        XCTAssertEqual(rig.vm.loadState, .loading)

        await rig.vm.load()

        XCTAssertEqual(rig.vm.loadState, .loaded)
        XCTAssertEqual(rig.vm.profile, UserProfile(nickname: "あきら", avatarEmoji: "🌱"))
        XCTAssertEqual(rig.vm.promise, savedPromise, "リマインド時刻まで含めた元の値")
        XCTAssertTrue(rig.vm.canEditPromise)
        XCTAssertEqual(rig.vm.promiseSummary, "💪 筋トレ")
        XCTAssertEqual(rig.vm.versionText, "1.0.0 (7)")
    }

    func testLoadFailureBlocksPromiseEditingBecauseReminderTimeIsUnknown() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }
        rig.auth.profileResult = .failure(Offline())

        await rig.vm.load()

        XCTAssertEqual(rig.vm.loadState, .failed)
        XCTAssertFalse(rig.vm.canEditPromise, "リマインド時刻が分からないまま保存すると、リマインドを消してしまう")
        XCTAssertNil(rig.vm.profile)
    }

    func testPromiseReadFailureAlsoBlocksEditing() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }
        rig.auth.promiseResult = .failure(Offline())

        await rig.vm.load()

        XCTAssertEqual(rig.vm.loadState, .failed)
        XCTAssertFalse(rig.vm.canEditPromise)
    }

    func testRetryAfterFailureLoadsEverything() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }
        rig.auth.profileResult = .failure(Offline())
        await rig.vm.load()
        XCTAssertEqual(rig.vm.loadState, .failed)

        rig.auth.profileResult = .success(UserProfile(nickname: "あきら", avatarEmoji: "🌱"))
        rig.auth.promiseResult = .success(savedPromise)
        await rig.vm.load()

        XCTAssertEqual(rig.vm.loadState, .loaded)
        XCTAssertTrue(rig.vm.canEditPromise)
    }

    func testServerWithoutPromiseFallsBackToTheSnapshotWithoutReminder() async throws {
        // スタブ構成(サーバーが無い)・古い snapshot: 約束は端末の snapshot にしか無い。編集は開けるが、リマインドは分からない
        let rig = try makeRig(snapshot: SnapshotFactory.solo())
        defer { rig.temp.cleanup() }
        rig.auth.promiseResult = .success(nil)

        await rig.vm.load()

        XCTAssertEqual(rig.vm.loadState, .loaded)
        XCTAssertEqual(rig.vm.promise?.title, "筋トレ")
        XCTAssertEqual(rig.vm.promise?.emoji, "💪")
        XCTAssertNil(rig.vm.promise?.remindAt)
        XCTAssertTrue(rig.vm.canEditPromise)
    }

    func testNoPromiseAnywhereShowsNothingToEdit() async throws {
        let rig = try makeRig(snapshot: SnapshotFactory.noPromise())
        defer { rig.temp.cleanup() }

        await rig.vm.load()

        XCTAssertEqual(rig.vm.loadState, .loaded)
        XCTAssertFalse(rig.vm.canEditPromise)
        XCTAssertNil(rig.vm.promiseSummary)
    }

    func testPromiseSavedReplacesThePromiseAndShowsANote() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }
        rig.auth.promiseResult = .success(savedPromise)
        await rig.vm.load()
        XCTAssertFalse(rig.vm.showsPromiseSavedNote)

        rig.vm.promiseSaved(Promise(id: "p-1", title: "ランニング", emoji: "🏃", remindAt: nil))

        XCTAssertEqual(rig.vm.promise?.title, "ランニング")
        XCTAssertEqual(rig.vm.promiseSummary, "🏃 ランニング")
        XCTAssertTrue(rig.vm.showsPromiseSavedNote)
    }

    // MARK: ペアの表示

    func testPairedShowsThePartner() throws {
        let rig = try makeRig(snapshot: SnapshotFactory.paired())
        defer { rig.temp.cleanup() }
        XCTAssertTrue(rig.vm.isPaired)
        XCTAssertEqual(rig.vm.partnerName, "ゆうき")
    }

    func testSoloHasNoPartnerAndNothingToDissolve() throws {
        let rig = try makeRig(snapshot: SnapshotFactory.solo())
        defer { rig.temp.cleanup() }
        XCTAssertFalse(rig.vm.isPaired)
        XCTAssertNil(rig.vm.partnerName)
    }

    // MARK: ペアの解消(確認の2段階)

    func testDissolveRunsOnlyAfterTheTwoConfirmationSteps() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }

        rig.vm.dissolve.begin() // 設定の「ペアを解消する」→ 説明の画面
        rig.vm.dissolve.confirm() // 最後のアラートを経ていない
        XCTAssertEqual(rig.account.dissolveCount, 0)

        rig.vm.dissolve.proceedToFinalConfirmation() // 説明の画面のボタン → アラート
        XCTAssertEqual(rig.account.dissolveCount, 0)

        await rig.vm.dissolve.confirmAndWait() // アラートの「解消する」
        XCTAssertEqual(rig.account.dissolveCount, 1)
        XCTAssertTrue(rig.vm.dissolve.succeeded)
    }

    func testDissolveSuccessRefreshesThePairedDisplay() async throws {
        let rig = try makeRig(snapshot: SnapshotFactory.paired())
        defer { rig.temp.cleanup() }
        XCTAssertTrue(rig.vm.isPaired)

        rig.vm.dissolve.begin()
        rig.vm.dissolve.proceedToFinalConfirmation()
        await rig.vm.dissolve.confirmAndWait()

        XCTAssertFalse(rig.vm.isPaired, "解消のあと、端末の snapshot(ソロの形)から表示を読み直す")
        XCTAssertNil(rig.vm.partnerName)
    }

    func testDissolveFailureKeepsThePairAndAllowsRetry() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }
        rig.account.dissolveError = Offline()

        rig.vm.dissolve.begin()
        rig.vm.dissolve.proceedToFinalConfirmation()
        await rig.vm.dissolve.confirmAndWait()

        XCTAssertEqual(rig.vm.dissolve.stage, .reviewing)
        XCTAssertEqual(rig.vm.dissolve.errorMessage, Strings.Dissolve.errorMessage)
        XCTAssertTrue(rig.vm.isPaired, "失敗したらペアはそのまま")

        rig.account.dissolveError = nil
        rig.vm.dissolve.proceedToFinalConfirmation()
        await rig.vm.dissolve.confirmAndWait()
        XCTAssertEqual(rig.account.dissolveCount, 2)
        XCTAssertFalse(rig.vm.isPaired)
    }

    // MARK: アカウントの削除(確認の2段階)

    func testDeleteAccountRunsOnlyAfterTheTwoConfirmationSteps() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }

        rig.vm.deletion.begin()
        rig.vm.deletion.confirm()
        XCTAssertEqual(rig.account.deleteCount, 0, "説明の画面から、最後のアラートを飛ばして削除はできない")
        rig.vm.deletion.proceedToFinalConfirmation()
        XCTAssertEqual(rig.account.deleteCount, 0)

        await rig.vm.deletion.confirmAndWait()
        XCTAssertEqual(rig.account.deleteCount, 1)
        XCTAssertEqual(rig.account.dissolveCount, 0, "削除の確認でペアの解消は走らない(サーバーが一緒に行う)")
    }

    func testDeleteAccountFailureIsRetryableWithAGentleMessage() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }
        rig.account.deleteError = Offline()

        rig.vm.deletion.begin()
        rig.vm.deletion.proceedToFinalConfirmation()
        await rig.vm.deletion.confirmAndWait()

        XCTAssertEqual(rig.vm.deletion.stage, .reviewing)
        XCTAssertEqual(rig.vm.deletion.errorMessage, Strings.DeleteAccount.errorMessage)
        XCTAssertFalse(rig.vm.deletion.succeeded)
    }

    // MARK: サインアウト

    func testSignOutNeedsConfirmation() async throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }

        rig.vm.requestSignOut()
        XCTAssertTrue(rig.vm.showsSignOutConfirmation)
        XCTAssertEqual(rig.account.signOutCount, 0, "確認を出しただけではサインアウトしない")

        rig.vm.cancelSignOut()
        XCTAssertFalse(rig.vm.showsSignOutConfirmation)
        XCTAssertEqual(rig.account.signOutCount, 0)

        rig.vm.requestSignOut()
        await rig.vm.confirmSignOut()
        XCTAssertFalse(rig.vm.showsSignOutConfirmation)
        XCTAssertEqual(rig.account.signOutCount, 1)
    }

    // MARK: 通報・お問い合わせのメール

    private func queryItems(_ url: URL?) throws -> [String: String] {
        let url = try XCTUnwrap(url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] { items[item.name] = item.value ?? "" }
        return items
    }

    func testGeneralReportMailCarriesThePairId() throws {
        let rig = try makeRig(snapshot: SnapshotFactory.paired())
        defer { rig.temp.cleanup() }

        let items = try queryItems(rig.vm.generalReportURL())

        XCTAssertEqual(items["subject"], Strings.Report.subject(Strings.Report.kindGeneral))
        let body = try XCTUnwrap(items["body"])
        XCTAssertTrue(body.contains("1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a"), "通報の対象を特定する ID")
        XCTAssertTrue(body.contains(Strings.Report.kindGeneral))
    }

    func testReportFromSoloSaysThereIsNoPair() throws {
        let rig = try makeRig(snapshot: SnapshotFactory.solo())
        defer { rig.temp.cleanup() }

        let body = try XCTUnwrap(queryItems(rig.vm.generalReportURL())["body"])

        XCTAssertTrue(body.contains(Strings.Report.noPair))
    }

    func testContactMailHasItsOwnSubject() throws {
        let rig = try makeRig()
        defer { rig.temp.cleanup() }

        let items = try queryItems(rig.vm.contactURL())

        XCTAssertEqual(items["subject"], Strings.Contact.subject)
        XCTAssertTrue(try XCTUnwrap(items["body"]).contains(Strings.Contact.bodyIntro))
    }
}
