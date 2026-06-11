// PromiseAPIClient.swift — 約束 API(promise-set)のクライアント抽象(T12)
//
// - View から直接呼ばない。ViewModel へは PromiseAPIClient プロトコルで注入する
//   (テストは PromiseSetupViewModelTests の MockPromiseAPIClient — InviteClient と同じイディオム)
// - live 実装(EdgeFunctionPromiseClient)は URLSession ベース。baseURL と認証トークンを
//   プロバイダ注入にして supabase-swift への依存を増やさない(issue #12 の戦略)。
//   実 Supabase との疎通検証は T08(G0 デプロイ後)・T20 実機 E2E で行う
// - エラーコード文字列の正本: promise-set/core.ts / index.ts(下記に出典コメント)

import Foundation

/// 約束の作成・編集(DESIGN §5.3 promise-set / REQUIREMENTS §3.3)
protocol PromiseAPIClient: AnyObject {
    /// POST /promise-set — 自分の現役の約束を upsert する。
    /// 編集は同一 promise_id への UPDATE(ストリーク非影響)。remindAt は "HH:MM" or nil
    func setPromise(title: String, emoji: String, remindAt: String?) async throws -> Promise
}

/// サーバーの error 文字列 → クライアントのエラー型。
/// 文字列はサーバー実装からコピーしたもの(変更時は両方を直すこと — T11 と同じ契約整合方針)
enum PromiseClientError: Error, Equatable {
    /// "invalid_title" — 400(trim 後 0 字 / 20 字超)
    case invalidTitle
    /// "invalid_emoji" — 400(欠落・長すぎ)
    case invalidEmoji
    /// "invalid_remind_at" — 400("HH:MM" 形式でない)
    case invalidRemindAt
    /// "user_not_found" — 404(自分の users 行が無い)
    case userNotFound
    /// "unauthorized" — 401(トークン失効等)
    case unauthorized
    /// 上記以外のサーバーエラー("internal_error" / "invalid_json" 等)
    case server(code: String)
    /// 通信エラー(オフライン・タイムアウト等)
    case network

    /// サーバー応答 body の error 文字列からマップする(出典: promise-set/core.ts / index.ts)
    init(serverCode: String) {
        switch serverCode {
        case "invalid_title": self = .invalidTitle
        case "invalid_emoji": self = .invalidEmoji
        case "invalid_remind_at": self = .invalidRemindAt
        case "user_not_found": self = .userNotFound
        case "unauthorized": self = .unauthorized
        default: self = .server(code: serverCode)
        }
    }
}

// MARK: - live 実装(URLSession。supabase-swift 非依存)

/// Edge Function `promise-set` を直接叩く実装。
/// baseURL(https://<ref>.supabase.co)と JWT のプロバイダを注入する
/// (トークンの取得元 = supabase-swift セッションへの結線は T13 ホーム画面の責務)。
final class EdgeFunctionPromiseClient: PromiseAPIClient {
    /// リクエスト body(キー名は promise-set/index.ts の payload と一致)
    private struct RequestBody: Encodable {
        let title: String
        let emoji: String
        let remindAt: String?
    }

    private struct ErrorBody: Decodable {
        let error: String
    }

    private let baseURL: URL
    /// 現在のユーザー JWT を返す(失効時の更新は提供側の責務)
    private let tokenProvider: () async throws -> String
    private let session: URLSession

    init(
        baseURL: URL,
        tokenProvider: @escaping () async throws -> String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func setPromise(title: String, emoji: String, remindAt: String?) async throws -> Promise {
        let url = baseURL
            .appendingPathComponent("functions/v1/promise-set")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await tokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(title: title, emoji: emoji, remindAt: remindAt)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PromiseClientError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw PromiseClientError.network
        }
        guard http.statusCode == 200 else {
            // 失敗応答は { "error": "<code>" }(promise-set/index.ts json())
            if let body = try? PairSnapshot.makeJSONDecoder().decode(ErrorBody.self, from: data) {
                throw PromiseClientError(serverCode: body.error)
            }
            throw PromiseClientError.server(code: "http_\(http.statusCode)")
        }
        return try PairSnapshot.makeJSONDecoder()
            .decode(PromiseSetResponse.self, from: data)
            .promise
    }
}

// MARK: - スタブ(実サーバー疎通前のアプリ実行用。StubInviteClient と同じ役割)

/// メモリ内で成功応答だけ返すスタブ。
/// 「編集しても id 不変」というサーバーの不変条件を再現する(再保存で id が変わらない)
final class StubPromiseAPIClient: PromiseAPIClient {
    private var currentID: String?

    func setPromise(title: String, emoji: String, remindAt: String?) async throws -> Promise {
        let id = currentID ?? UUID().uuidString.lowercased()
        currentID = id
        return Promise(id: id, title: title, emoji: emoji, remindAt: remindAt)
    }
}
