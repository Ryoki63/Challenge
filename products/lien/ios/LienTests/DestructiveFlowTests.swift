// DestructiveFlowTests.swift — 取り消せない操作(ペアの解消・アカウントの削除)の確認の流れ(T23 #23)
//
// 検証対象(DestructiveFlow.swift):
//   - 確認の2段階(説明の画面 → 最後のアラート)を経ないと操作が実行されない
//   - 「やめる」・戻るで取り消せる。実行中は閉じられない
//   - アラートが閉じられる処理(SwiftUI は実行ボタンのあとにも isPresented を false にする)が、実行を止めない
//   - 失敗しても何も失われず、説明の画面に戻ってやり直せる

import XCTest
@testable import Lien

@MainActor
final class DestructiveFlowTests: XCTestCase {
    private struct Failure: Error {}

    /// 呼び出し回数と、成功/失敗の切り替えができる操作
    private final class Operation {
        var callCount = 0
        var failuresRemaining = 0
        var delayNanoseconds: UInt64 = 0

        func run() async throws {
            callCount += 1
            if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw Failure()
            }
        }
    }

    private func makeFlow(_ operation: Operation) -> DestructiveFlow {
        DestructiveFlow(errorText: "うまくいきませんでした", operation: { try await operation.run() })
    }

    // MARK: 2 段階を経ないと実行されない

    func testOperationRunsOnlyAfterBothConfirmationSteps() async {
        let op = Operation()
        let flow = makeFlow(op)
        XCTAssertEqual(flow.stage, .idle)

        flow.confirm() // 何も始めていない
        XCTAssertEqual(op.callCount, 0)
        XCTAssertEqual(flow.stage, .idle)

        flow.begin() // 1段階目: 説明の画面
        XCTAssertEqual(flow.stage, .reviewing)
        flow.confirm() // 説明の画面から、最後の確認を飛ばして実行はできない
        XCTAssertEqual(op.callCount, 0, "最後のアラートを経ていない")
        XCTAssertEqual(flow.stage, .reviewing)

        flow.proceedToFinalConfirmation() // 2段階目: 最後のアラート
        XCTAssertEqual(flow.stage, .finalPrompt)
        XCTAssertEqual(op.callCount, 0, "アラートを出しただけでは実行されない")

        await flow.confirmAndWait()
        XCTAssertEqual(op.callCount, 1)
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertTrue(flow.succeeded)
        XCTAssertNil(flow.errorMessage)
    }

    func testProceedToFinalConfirmationIsIgnoredBeforeBegin() {
        let flow = makeFlow(Operation())
        flow.proceedToFinalConfirmation()
        XCTAssertEqual(flow.stage, .idle, "説明の画面を経ずに最後のアラートへは進めない")
    }

    // MARK: 取り消し

    func testCancelFromReviewingAndFinalPromptNeverRunsTheOperation() async {
        let op = Operation()
        let flow = makeFlow(op)

        flow.begin()
        flow.cancel() // 説明の画面を戻る
        XCTAssertEqual(flow.stage, .idle)

        flow.begin()
        flow.proceedToFinalConfirmation()
        flow.cancel() // 最後のアラートが出ている状態でシートが下げられた
        XCTAssertEqual(flow.stage, .idle)

        flow.confirm()
        XCTAssertEqual(op.callCount, 0)
        XCTAssertFalse(flow.succeeded)
    }

    func testDismissingTheFinalPromptReturnsToTheExplanation() {
        let flow = makeFlow(Operation())
        flow.begin()
        flow.proceedToFinalConfirmation()

        flow.dismissFinalPrompt() // アラートの「やめる」
        XCTAssertEqual(flow.stage, .reviewing, "説明の画面に戻る(やり直せる)")

        flow.proceedToFinalConfirmation()
        XCTAssertEqual(flow.stage, .finalPrompt)
    }

    func testAlertClosingAfterConfirmDoesNotInterruptExecution() async {
        // SwiftUI のアラートは、実行ボタンのアクションのあとに isPresented を false にする。
        // 実行に進んだあとは、その「閉じた」通知が実行を止めたり説明の画面へ戻したりしない
        let op = Operation()
        op.delayNanoseconds = 30_000_000
        let flow = makeFlow(op)
        flow.begin()
        flow.proceedToFinalConfirmation()

        flow.confirm() // ボタンのアクション(同期的に working へ)
        flow.finalPromptDidClose() // 直後の isPresented = false
        XCTAssertEqual(flow.stage, .working)

        await flow.runTask?.value
        XCTAssertEqual(op.callCount, 1)
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertTrue(flow.succeeded)
    }

    func testAlertClosingWithoutConfirmActsLikeCancelOfTheAlert() {
        let op = Operation()
        let flow = makeFlow(op)
        flow.begin()
        flow.proceedToFinalConfirmation()

        flow.finalPromptDidClose() // アラートの外側をタップして閉じた
        XCTAssertEqual(flow.stage, .reviewing)
        XCTAssertEqual(op.callCount, 0)
    }

    func testCannotCancelWhileWorking() async {
        let op = Operation()
        op.delayNanoseconds = 30_000_000
        let flow = makeFlow(op)
        flow.begin()
        flow.proceedToFinalConfirmation()
        flow.confirm()
        XCTAssertEqual(flow.stage, .working)

        flow.cancel() // 戻る・シートを下げる
        flow.dismissFinalPrompt()
        flow.begin()
        flow.proceedToFinalConfirmation()
        flow.confirm() // 二重の実行もしない
        XCTAssertEqual(flow.stage, .working, "実行中は閉じられない・やり直せない")

        await flow.runTask?.value
        XCTAssertEqual(op.callCount, 1, "実行は1回だけ")
    }

    // MARK: 失敗とやり直し

    func testFailureReturnsToTheExplanationWithAMessageAndCanBeRetried() async {
        let op = Operation()
        op.failuresRemaining = 1
        let flow = makeFlow(op)

        flow.begin()
        flow.proceedToFinalConfirmation()
        await flow.confirmAndWait()

        XCTAssertEqual(flow.stage, .reviewing, "説明の画面に戻る(何も失われていない)")
        XCTAssertEqual(flow.errorMessage, "うまくいきませんでした")
        XCTAssertFalse(flow.succeeded)

        // やり直しも、最後のアラートを経る
        flow.confirm()
        XCTAssertEqual(op.callCount, 1, "説明の画面から、最後の確認を飛ばして再実行はできない")
        flow.proceedToFinalConfirmation()
        await flow.confirmAndWait()

        XCTAssertEqual(op.callCount, 2)
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertNil(flow.errorMessage, "成功したらエラーは消える")
        XCTAssertTrue(flow.succeeded)
    }

    func testBeginAgainClearsThePreviousResult() async {
        let op = Operation()
        let flow = makeFlow(op)
        flow.begin()
        flow.proceedToFinalConfirmation()
        await flow.confirmAndWait()
        XCTAssertTrue(flow.succeeded)

        flow.begin()
        XCTAssertFalse(flow.succeeded, "次の説明の画面を開いたら、前の完了の一言は消える")
        XCTAssertEqual(flow.stage, .reviewing)
    }

    func testOnSucceededRunsAfterSuccessOnly() async {
        let op = Operation()
        op.failuresRemaining = 1
        let flow = makeFlow(op)
        var succeededCount = 0
        flow.onSucceeded = { succeededCount += 1 }

        flow.begin()
        flow.proceedToFinalConfirmation()
        await flow.confirmAndWait() // 失敗
        XCTAssertEqual(succeededCount, 0)

        flow.proceedToFinalConfirmation()
        await flow.confirmAndWait() // 成功
        XCTAssertEqual(succeededCount, 1)
    }
}
