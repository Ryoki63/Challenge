// SessionVerifier.swift — 認証サーバー(Supabase Auth)への、ログイン状態の直接のたしかめ(T23 #23)
//
// 自分たちのサーバー(Edge Function)が「認証できない(401 unauthorized)」と答え続けても、それだけでは
// 「このアカウントはもう使えない」とは決められない。401 は、Edge Function から認証サーバーへの問い合わせの失敗
// (サービスキーの設定ミス・認証サーバーの一時的な不調)でも出うる。そこで「はじめからやり直す」の確認を出す前に、
// **アプリ自身のトークンで認証サーバーに直接たしかめる**:
//
//   GET <supabaseURL>/auth/v1/user   (apikey: 公開キー / Authorization: Bearer <利用者の JWT>)
//     200                                         → .valid    認証サーバーはこのログインを受け付けている(401 は自分たちのサーバーの側の問題)
//     403 / 404 + user_not_found / session_not_found → .rejected ユーザーが居ない・セッションが取り消された(確かに使えない)
//     それ以外(通信の失敗・5xx・ほかの 401 / 403 …)     → .unknown  たしかめられなかった。何も決めない
//
// - 確かに使えないと分かるのは、ユーザーまたはセッションが「居ない」と認証サーバーが答えたときだけ。
//   401 の期限切れなどは、端末の時計のずれでも出うるので、使えないとは決めない(.unknown)
// - アカウントの削除の応答だけ取りこぼしたときの確認(AppModel.deleteAccount)にも使う:
//   サーバーでは削除済みなら、認証サーバーも「ユーザーが居ない」と答える
// - URLSession ベース(supabase-swift 非依存)。トークンの取得は AuthServicing.accessToken と同じ供給元

import Foundation

enum SessionVerdict: Equatable, Sendable {
    /// 認証サーバーはこのログインを受け付けている
    case valid
    /// 認証サーバーが「ユーザー(またはセッション)が居ない」と答えた。このログインはもう使えない
    case rejected
    /// たしかめられなかった(通信の失敗・認証サーバーの不調・判断できない応答)
    case unknown
}

protocol SessionVerifying: AnyObject {
    /// 認証サーバーに直接たしかめる。失敗(通信など)は投げずに .unknown で返す
    func verify() async -> SessionVerdict
}

final class GoTrueSessionVerifier: SessionVerifying {
    /// 確認は短く切り上げる(起動直後の同期を長く引き延ばさない。たしかめられなければ .unknown で次の機会に)
    static let requestTimeout: TimeInterval = 10

    /// 「ユーザー/セッションが居ない」を表す error_code(GoTrue の `ErrorCode`)
    static let rejectedErrorCodes: Set<String> = ["user_not_found", "session_not_found"]

    private let baseURL: URL
    private let apiKey: String
    private let tokenProvider: () async throws -> String
    private let session: URLSession

    init(
        baseURL: URL,
        apiKey: String,
        tokenProvider: @escaping () async throws -> String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func verify() async -> SessionVerdict {
        let token: String
        do {
            token = try await tokenProvider()
        } catch {
            // トークンを用意できない(未サインイン・更新の失敗)。ここでは判断しない
            // (SDK がセッションを破棄したなら、AppModel が別に検知して後始末する)
            return .unknown
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/v1/user"))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let status: Int
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            data = body
            status = http.statusCode
        } catch {
            return .unknown
        }
        return Self.verdict(status: status, body: data)
    }

    /// 応答から判定する(純粋関数。テストが直接呼ぶ)
    static func verdict(status: Int, body: Data) -> SessionVerdict {
        if status == 200 { return .valid }
        guard status == 403 || status == 404 else { return .unknown }
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let code = object["error_code"] as? String
        else { return .unknown }
        return rejectedErrorCodes.contains(code) ? .rejected : .unknown
    }
}
