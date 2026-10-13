// AccountAPIClient.swift — ペア解消(pair-dissolve)とアカウント削除(delete-account)のクライアント(T23 #23)
//
// - View から直接呼ばない。AppModel(AccountOperating)が使う。テストはモック注入
// - 実 HTTP 実装は EdgeFunctionAccountClient(EdgeFunctionTransport を使う他のクライアントと同じ形)。
//   Config の有無による Live / スタブの切替は AppServices(App/AppServices.swift)が行う
// - 応答・エラー文字列の正本: supabase/functions/pair-dissolve/ と delete-account/ の core.ts / index.ts
//   (契約フィクスチャ products/lien/contracts/pair-dissolve.*.json・delete-account.ok.json・errors.json を
//   ContractFixtureTests が読む)
//
//   pair-dissolve : 200 { dissolved, snapshot }(snapshot は解消後 = ソロの形。すでにペアが無くても 200 —
//                   冪等)/ 404 user_not_found / 401 unauthorized / 405 / 500 internal_error
//   delete-account: 200 { deleted: true } / 401 unauthorized / 405 / 500 internal_error
//                   (途中で失敗しても 500 のままやり直せる。auth ユーザーを最後に消すため — DESIGN §5.3)

import Foundation

/// POST /pair-dissolve の 200 応答(pair-dissolve/core.ts)
struct PairDissolveResponse: Equatable, Sendable, Codable {
    /// このリクエストでペアを解消したか(false = すでにペアが無かった。どちらもクライアントは「ソロに戻った」と扱ってよい)
    let dissolved: Bool
    /// 呼び出し本人視点・解消後(ソロの形)
    let snapshot: PairSnapshot
}

/// POST /delete-account の 200 応答(delete-account/core.ts)
struct AccountDeleteResponse: Equatable, Sendable, Codable {
    let deleted: Bool
}

/// サーバーの error 文字列 → クライアントのエラー型(変更時はサーバー実装と両方を直す)
enum AccountClientError: Error, Equatable {
    /// "user_not_found" — 404(pair-dissolve。自分の users 行が無い)
    case userNotFound
    /// "unauthorized" — 401(トークン失効、またはアカウントがすでに無い)
    case unauthorized
    /// 上記以外のサーバーエラー("internal_error" 等。削除の途中失敗も含む — やり直せる)
    case server(code: String)
    /// 通信エラー(オフライン・タイムアウト等)
    case network
    /// この構成ではアカウント操作の口が無い(AppServices.accountClient が nil)
    case unavailable

    init(serverCode: String) {
        switch serverCode {
        case "user_not_found": self = .userNotFound
        case "unauthorized": self = .unauthorized
        default: self = .server(code: serverCode)
        }
    }
}

protocol AccountAPIClient: AnyObject {
    /// POST /pair-dissolve — 現役のペアを解消する(冪等)。応答は解消後(ソロ)の自分視点 snapshot
    func dissolvePair() async throws -> PairSnapshot

    /// POST /delete-account — アカウントと関連データ(写真を含む)を完全に削除する。
    /// 失敗したときは、同じ呼び出しをやり直せる。成功のあとは、このセッションはもう使えない
    func deleteAccount() async throws
}

// MARK: - live 実装(URLSession。supabase-swift 非依存)

final class EdgeFunctionAccountClient: AccountAPIClient {
    /// ペア解消は短い DB 更新だけ
    static let dissolveTimeout: TimeInterval = 30
    /// アカウント削除は Storage の写真の回収を含むので長めに待つ(失敗してもやり直せる)
    static let deleteTimeout: TimeInterval = 90

    private let transport: EdgeFunctionTransport

    init(
        baseURL: URL,
        tokenProvider: @escaping () async throws -> String,
        session: URLSession = .shared
    ) {
        transport = EdgeFunctionTransport(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            session: session
        )
    }

    func dissolvePair() async throws -> PairSnapshot {
        // 本文は読まない(解消するペアは JWT の userId から決まる)
        var request = try await transport.functionRequest("pair-dissolve", method: "POST")
        request.timeoutInterval = Self.dissolveTimeout
        let response: PairDissolveResponse = try await perform(request)
        return response.snapshot
    }

    func deleteAccount() async throws {
        var request = try await transport.functionRequest("delete-account", method: "POST")
        request.timeoutInterval = Self.deleteTimeout
        let response: AccountDeleteResponse = try await perform(request)
        guard response.deleted else {
            throw AccountClientError.server(code: "not_deleted")
        }
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let result: (data: Data, status: Int)
        do {
            result = try await transport.send(request)
        } catch {
            throw AccountClientError.network
        }
        guard result.status == 200 else {
            if let code = EdgeFunctionTransport.errorCode(in: result.data) {
                throw AccountClientError(serverCode: code)
            }
            throw AccountClientError.server(code: "http_\(result.status)")
        }
        do {
            return try PairSnapshot.makeJSONDecoder().decode(Response.self, from: result.data)
        } catch {
            throw AccountClientError.server(code: "invalid_response")
        }
    }
}

// MARK: - スタブ(Config 未設定のアプリ実行用。StubInviteClient と同じ役割)

/// サーバーが無い環境の解消・削除。解消は端末の snapshot を、サーバーの解消後と同じソロの形にして返す
/// (約束と今日の自分のチェックインは残り、ペア・相手・ストリーク・植物は無くなる)。削除は何もしない
final class StubAccountClient: AccountAPIClient {
    private let store: AppGroupStore?
    private let now: () -> Date

    init(store: AppGroupStore?, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func dissolvePair() async throws -> PairSnapshot {
        let local = store?.loadSnapshot() ?? PairSnapshot.emptySolo(updatedAt: now())
        return local.dissolved(updatedAt: now())
    }

    func deleteAccount() async throws {}
}

extension PairSnapshot {
    /// ペアを解消した後の自分視点の形(snapshot.ts の buildSoloSnapshot と同じ):
    /// ペア・相手・ストリーク・植物は無くなり、自分の約束と今日の自分のチェックインは残る
    func dissolved(updatedAt: Date) -> PairSnapshot {
        var solo = PairSnapshot.emptySolo(updatedAt: updatedAt)
        solo.todayMeDone = todayMeDone
        solo.myPromiseTitle = myPromiseTitle
        solo.myPromiseEmoji = myPromiseEmoji
        return solo
    }
}
