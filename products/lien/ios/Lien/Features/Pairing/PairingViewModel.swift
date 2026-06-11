// PairingViewModel.swift — 招待画面の状態管理(T11 / REQUIREMENTS §3.2 / DESIGN §6)
//
// - 発行: issueInvite() → idle/loading/issued。issued でリンク共有・QR・コード表示の3導線を出す
// - 受諾: acceptInvite() → 8文字形式はクライアントで先に検証(不正形式はサーバーへ送らない —
//   invite-accept/core.ts も同じ判定で 400 を返す)。成功で snapshot を App Group へ保存し
//   onPaired → ルートが .paired へ
// - エラーは InviteClientError → Strings.Pairing の文言へ変換(罰・恥系の表現は使わない)

import Foundation
import Observation

@MainActor
@Observable
final class PairingViewModel {
    /// 招待発行の状態
    enum IssueState: Equatable {
        case idle
        case loading
        case issued(InviteCreateResponse)
    }

    // MARK: - 入力状態(View からバインド)

    /// コード手入力欄(ディープリンクのプリフィルにも使う)
    var codeInput = ""

    // MARK: - 画面状態

    private(set) var issueState: IssueState = .idle
    private(set) var issueErrorMessage: String?
    private(set) var isAccepting = false
    private(set) var acceptErrorMessage: String?

    // MARK: - 依存(モック注入可能)

    private let inviteClient: InviteClient
    /// 受諾成功時の snapshot 保存先(エンタイトルメント未解決環境では nil — 保存はスキップ)
    private let store: AppGroupStore?
    private let onPaired: () -> Void
    private var hasPaired = false

    init(
        inviteClient: InviteClient,
        store: AppGroupStore?,
        onPaired: @escaping () -> Void
    ) {
        self.inviteClient = inviteClient
        self.store = store
        self.onPaired = onPaired
    }

    // MARK: - 発行(リンク / QR / コードの3導線はすべて同じ token)

    var issuedInvite: InviteCreateResponse? {
        if case .issued(let invite) = issueState { return invite }
        return nil
    }

    func issueInvite() async {
        guard issueState != .loading else { return }
        issueState = .loading
        issueErrorMessage = nil
        do {
            let invite = try await inviteClient.createInvite()
            issueState = .issued(invite)
        } catch {
            issueState = .idle
            issueErrorMessage = Self.userMessage(for: error)
        }
    }

    // MARK: - 受諾(コード入力)

    /// 前後の空白・改行を除いた送信用コード
    var trimmedCode: String {
        codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canAccept: Bool {
        InviteToken.isValidFormat(trimmedCode) && !isAccepting
    }

    /// ディープリンク lien://invite/<token> からのプリフィル(本格ルーティングは後続タスク)
    func prefill(token: String) {
        codeInput = token
        acceptErrorMessage = nil
    }

    func acceptInvite() async {
        guard !isAccepting, !hasPaired else { return }
        let token = trimmedCode
        guard InviteToken.isValidFormat(token) else {
            acceptErrorMessage = Strings.Pairing.errorInvalidTokenFormat
            return
        }
        isAccepting = true
        acceptErrorMessage = nil
        defer { isAccepting = false }
        do {
            let response = try await inviteClient.acceptInvite(token: token)
            // snapshot を保存してウィジェットにも反映できる状態にする(失敗しても遷移は続行 —
            // フォアグラウンド復帰時の GET /snapshot で自己修復する設計 — DESIGN §4)
            try? store?.saveSnapshot(response.snapshot)
            finishPairing()
        } catch {
            acceptErrorMessage = Self.userMessage(for: error)
        }
    }

    private func finishPairing() {
        guard !hasPaired else { return }
        hasPaired = true
        onPaired()
    }

    // MARK: - エラー文言

    /// InviteClientError → ユーザー向け文言。未知・通信系は汎用のリトライ文言
    static func userMessage(for error: Error) -> String {
        guard let clientError = error as? InviteClientError else {
            return Strings.Pairing.errorNetwork
        }
        switch clientError {
        case .alreadyPaired:
            return Strings.Pairing.errorAlreadyPaired
        case .partnerAlreadyPaired:
            return Strings.Pairing.errorPartnerAlreadyPaired
        case .inviteNotFound:
            return Strings.Pairing.errorInviteNotFound
        case .inviteExpired:
            return Strings.Pairing.errorInviteExpired
        case .inviteAlreadyUsed:
            return Strings.Pairing.errorInviteAlreadyUsed
        case .cannotAcceptOwnInvite:
            return Strings.Pairing.errorCannotAcceptOwnInvite
        case .invalidToken:
            return Strings.Pairing.errorInvalidTokenFormat
        case .userNotFound, .server, .network:
            return Strings.Pairing.errorNetwork
        }
    }
}
