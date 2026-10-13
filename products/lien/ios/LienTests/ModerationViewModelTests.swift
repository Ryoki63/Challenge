// ModerationViewModelTests.swift — ホームでの通報とブロックの状態(T23 #23 / App Store ガイドライン 1.2)
//
// 検証対象(ModerationViewModel.swift):
//   - 通報は確認を経てから mailto を返す(確認の「やめる」では何も開かない)
//   - 写真の長押しメニューの項目(通報・ブロック)が、長押しした写真の指し先を通報の対象にする
//   - ブロック(= ペア解消)は設定画面と同じ確認の2段階を経てから実行される

import XCTest
@testable import Lien

@MainActor
private final class RecordingAccount: AccountOperating {
    private(set) var dissolveCount = 0
    var dissolveError: Error?

    func dissolvePair() async throws {
        dissolveCount += 1
        if let dissolveError { throw dissolveError }
    }
    func deleteAccount() async throws {}
    func signOut() async {}
}

@MainActor
final class ModerationViewModelTests: XCTestCase {
    private struct Offline: Error {}

    private let photoReference = PartnerPhotoReference(
        pairID: "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
        dateLocal: "2026-06-11",
        photoPath: "pairs/1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a/2026-06-11/b2222222-2222-4222-8222-222222222222/photo.jpg"
    )

    private func makeViewModel(
        snapshot: PairSnapshot? = SnapshotFactory.paired(),
        email: String = "support@example.com"
    ) throws -> (vm: ModerationViewModel, account: RecordingAccount, temp: TempStore) {
        let temp = TempStore()
        if let snapshot { try temp.store.saveSnapshot(snapshot) }
        let account = RecordingAccount()
        let vm = ModerationViewModel(
            store: temp.store,
            account: account,
            now: { SnapshotFactory.fixedDate },
            email: email
        )
        return (vm, account, temp)
    }

    private func body(of url: URL?) throws -> String {
        let url = try XCTUnwrap(url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(components.queryItems?.first { $0.name == "body" }?.value)
    }

    // MARK: 通報

    func testReportNeedsConfirmationBeforeAnyMailIsOpened() throws {
        let (vm, _, temp) = try makeViewModel()
        defer { temp.cleanup() }

        vm.requestReport(.nickname("ゆうき"))
        XCTAssertEqual(vm.pendingReport, .nickname("ゆうき"), "確認を出す")

        vm.cancelReport() // 確認の「やめる」
        XCTAssertNil(vm.pendingReport)
        XCTAssertNil(vm.confirmReport(), "やめたら、開く mailto は無い")
    }

    func testConfirmedReportReturnsAMailtoWithTheTargetAndThePairId() throws {
        let (vm, _, temp) = try makeViewModel()
        defer { temp.cleanup() }

        vm.requestReport(.photo(photoReference))
        let url = try XCTUnwrap(vm.confirmReport())

        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:support@example.com?"))
        let text = try body(of: url)
        XCTAssertTrue(text.contains(photoReference.photoPath))
        XCTAssertTrue(text.contains("1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a"), "snapshot の pairId")
        XCTAssertNil(vm.pendingReport, "開いたら確認は閉じる")
        XCTAssertFalse(vm.showsMailFailure)
    }

    func testReportWithAnUnusableRecipientShowsTheMailFailure() throws {
        let (vm, _, temp) = try makeViewModel(email: "bad address")
        defer { temp.cleanup() }

        vm.requestReport(.nickname("ゆうき"))
        XCTAssertNil(vm.confirmReport())

        XCTAssertTrue(vm.showsMailFailure, "メールを作れなければ、失敗のアラートを出す")
    }

    func testMailOpenFailedShowsTheAlert() throws {
        let (vm, _, temp) = try makeViewModel()
        defer { temp.cleanup() }
        vm.mailOpenFailed()
        XCTAssertTrue(vm.showsMailFailure)
    }

    // MARK: 写真の長押しメニュー

    func testPhotoActionsAreReportAndBlock() throws {
        let (vm, _, temp) = try makeViewModel()
        defer { temp.cleanup() }

        let actions = vm.photoActions

        XCTAssertEqual(actions.map(\.id), ["report", "block"])
        XCTAssertEqual(actions.map(\.title), [Strings.Report.menuReportPhoto, Strings.Report.menuBlock])
        XCTAssertEqual(actions.map(\.isDestructive), [false, true], "ブロックは赤で出す")
    }

    func testReportActionTargetsTheLongPressedPhoto() throws {
        let (vm, _, temp) = try makeViewModel()
        defer { temp.cleanup() }

        let report = try XCTUnwrap(vm.photoActions.first { $0.id == "report" })
        report.perform(photoReference)

        XCTAssertEqual(vm.pendingReport, .photo(photoReference), "長押しした写真の指し先が通報の対象になる")
    }

    func testBlockActionOpensTheExplanationButDoesNotDissolveYet() throws {
        let (vm, account, temp) = try makeViewModel()
        defer { temp.cleanup() }

        let block = try XCTUnwrap(vm.photoActions.first { $0.id == "block" })
        block.perform(photoReference)

        XCTAssertEqual(vm.block.stage, .reviewing, "確認の1段階目(説明のシート)")
        XCTAssertEqual(account.dissolveCount, 0, "長押しだけではペアを解消しない")
    }

    // MARK: ブロック(= ペア解消)

    func testBlockDissolvesOnlyAfterTheTwoConfirmationSteps() async throws {
        let (vm, account, temp) = try makeViewModel()
        defer { temp.cleanup() }

        vm.requestBlock()
        vm.block.confirm() // 最後のアラートを経ていない
        XCTAssertEqual(account.dissolveCount, 0)

        vm.block.proceedToFinalConfirmation()
        await vm.block.confirmAndWait()

        XCTAssertEqual(account.dissolveCount, 1)
        XCTAssertEqual(vm.block.stage, .idle)
        XCTAssertTrue(vm.block.succeeded)
    }

    func testBlockFailureLeavesThePairAndAllowsRetry() async throws {
        let (vm, account, temp) = try makeViewModel()
        defer { temp.cleanup() }
        account.dissolveError = Offline()

        vm.requestBlock()
        vm.block.proceedToFinalConfirmation()
        await vm.block.confirmAndWait()

        XCTAssertEqual(vm.block.stage, .reviewing)
        XCTAssertEqual(vm.block.errorMessage, Strings.Dissolve.errorMessage)
        XCTAssertFalse(vm.block.succeeded)
    }

    func testCancellingTheBlockSheetDoesNothing() throws {
        let (vm, account, temp) = try makeViewModel()
        defer { temp.cleanup() }
        vm.requestBlock()
        vm.block.cancel()
        XCTAssertEqual(vm.block.stage, .idle)
        XCTAssertEqual(account.dissolveCount, 0)
    }

    func testResetClosesEveryOpenConfirmation() throws {
        let (vm, _, temp) = try makeViewModel()
        defer { temp.cleanup() }
        vm.requestReport(.nickname("ゆうき"))
        vm.requestBlock()
        vm.mailOpenFailed()

        vm.reset() // サインアウト・アカウント削除のあと

        XCTAssertNil(vm.pendingReport)
        XCTAssertFalse(vm.showsMailFailure)
        XCTAssertEqual(vm.block.stage, .idle, "次のアカウントでホームに戻ったとき、前の確認が出てこない")
    }
}
