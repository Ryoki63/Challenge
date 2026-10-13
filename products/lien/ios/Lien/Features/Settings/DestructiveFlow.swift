// DestructiveFlow.swift — 取り消せない操作(ペアの解消・アカウントの削除)の確認の流れ(T23 #23)
//
// REQUIREMENTS §3.2「ペア解消は確認2段階」・設定のアカウント削除も同じ。流れは次のとおり:
//
//   idle ──begin()──▶ reviewing(何が起きるかを説明する画面)
//                      │  ▲ dismissFinalPrompt()(最後の確認の「やめる」)
//                      ▼  │
//                    finalPrompt(最後の確認のアラート)──confirm()──▶ working ──成功──▶ idle(succeeded)
//                      │                                              └─失敗──▶ reviewing(errorMessage つき。やり直せる)
//   cancel()(説明の画面を閉じる)で reviewing / finalPrompt から idle へ
//
// - **確認の2段階を経ないと実行されない**: operation を呼ぶのは confirm() だけで、finalPrompt からしか進めない
//   (begin → proceedToFinalConfirmation → confirm の順。説明の画面でボタンを押す前・アラートを出す前には呼べない)
// - confirm() は状態を**同期的に** working へ進めてから、実行を別タスクで走らせる。SwiftUI のアラートは
//   ボタンのアクションのあとに isPresented を false にするので、状態が finalPrompt のままだと、閉じる処理が
//   「やめる」と取り違えて reviewing に戻してしまう(実行が止まる)。working に進めておけば、閉じる処理は何もしない
// - 実行中(working)は閉じられない(cancel は効かない)。失敗しても何も失われない(説明の画面に戻り、もう一度できる)

import Foundation
import Observation

/// アカウント・ペアに対する操作(実体は AppModel。テストはモック)
@MainActor
protocol AccountOperating: AnyObject {
    /// 現役のペアを解消する(= ブロック)。成功したら、端末の snapshot とウィジェットもソロの形に更新済みで戻る
    func dissolvePair() async throws
    /// アカウントを削除する。成功したら、端末の記録を消してサインアウトし、オンボーディングへ戻っている
    func deleteAccount() async throws
    /// サインアウトする(端末の記録を消してオンボーディングへ戻る。サーバー側のアカウントは消えない)
    func signOut() async
}

enum DestructiveStage: Equatable {
    case idle
    /// 何が起きるかを説明する画面を出している
    case reviewing
    /// 最後の確認のアラートを出している
    case finalPrompt
    /// 実行中
    case working
}

@MainActor
@Observable
final class DestructiveFlow {
    private(set) var stage: DestructiveStage = .idle
    /// 直近の実行に失敗したときの一言(責めない文言)。説明の画面に出す
    private(set) var errorMessage: String?
    /// 直近の実行が成功したか(完了の一言用。次の begin() で false に戻る)
    private(set) var succeeded = false

    private let errorText: String
    private let operation: @MainActor () async throws -> Void
    /// 成功したあとに呼ぶ(設定画面の表示を更新するなど)。持ち主の init が全部そろったあとで設定する
    @ObservationIgnored var onSucceeded: @MainActor () -> Void = {}
    /// 実行中のタスク(テストが完了を待つのに使う)
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?

    /// - errorText: 実行に失敗したときに出す文言
    /// - operation: 実行する操作。確認の2段階を経た confirm() からしか呼ばれない
    init(
        errorText: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        self.errorText = errorText
        self.operation = operation
    }

    /// 説明の画面を開く
    func begin() {
        guard stage == .idle else { return }
        errorMessage = nil
        succeeded = false
        stage = .reviewing
    }

    /// 説明の画面のボタン(「ペアを解消する」など)を押した: 最後の確認のアラートへ進む
    func proceedToFinalConfirmation() {
        guard stage == .reviewing else { return }
        stage = .finalPrompt
    }

    /// 最後の確認の「やめる」(アラートだけを閉じて、説明の画面に戻る)
    func dismissFinalPrompt() {
        guard stage == .finalPrompt else { return }
        stage = .reviewing
    }

    /// アラートが閉じられた(SwiftUI の isPresented が false になった)。実行に進んでいなければ「やめる」と同じ
    func finalPromptDidClose() {
        dismissFinalPrompt()
    }

    /// 説明の画面を閉じる(戻る・シートを下げる)。実行中は閉じられない
    func cancel() {
        guard stage == .reviewing || stage == .finalPrompt else { return }
        stage = .idle
    }

    /// 最後の確認の「実行」(「解消する」「削除する」)。最後の確認を経ていなければ何もしない
    func confirm() {
        guard stage == .finalPrompt else { return }
        stage = .working
        errorMessage = nil
        runTask = Task { await run() }
    }

    /// confirm() を呼んで、実行の完了まで待つ(テスト用)
    func confirmAndWait() async {
        confirm()
        await runTask?.value
    }

    private func run() async {
        do {
            try await operation()
            stage = .idle
            succeeded = true
            onSucceeded()
        } catch {
            // 何も失われていない(アカウント・ペアはそのまま)。説明の画面に戻して、もう一度できるようにする
            stage = .reviewing
            errorMessage = errorText
        }
    }
}
