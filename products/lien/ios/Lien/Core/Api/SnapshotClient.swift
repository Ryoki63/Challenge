// SnapshotClient.swift — GET /snapshot のクライアント(DESIGN §4 自己修復 / issue #55)
//
// 状態の正はサーバー(DESIGN §3.3)。起動時・前面復帰時・push 受信時にこれで最新の PairSnapshot
// (受信者視点)を取得し、App Group を上書きする(SnapshotSynchronizer — 上書きの条件はそちら)。
// 招待した側がペア成立を知る経路、ペア解消(paired → solo)の反映、push の取りこぼしの回復を担う。
//
// - 応答の形は `{ "snapshot": { ...PairSnapshot } }`(snapshot/core.ts SnapshotResult。
//   products/lien/contracts/snapshot.*.json が契約フィクスチャ)
// - エラー文字列の正本: snapshot/core.ts 404 user_not_found / snapshot/index.ts 401 unauthorized /
//   405 method_not_allowed / 500 internal_error

import Foundation

/// GET /snapshot の 200 応答(snapshot/core.ts SnapshotResult.body)
struct SnapshotResponse: Equatable, Sendable, Codable {
    let snapshot: PairSnapshot
}

/// サーバーの error 文字列 → クライアントのエラー型(変更時はサーバー実装と両方を直す)
enum SnapshotClientError: Error, Equatable {
    /// "user_not_found" — 404(自分の users 行が無い。DB の初期化・アカウント削除直後など)
    case userNotFound
    /// "unauthorized" — 401(トークン失効等)
    case unauthorized
    /// 上記以外のサーバーエラー("internal_error" 等)
    case server(code: String)
    /// 通信エラー(オフライン・タイムアウト等)
    case network

    init(serverCode: String) {
        switch serverCode {
        case "user_not_found": self = .userNotFound
        case "unauthorized": self = .unauthorized
        default: self = .server(code: serverCode)
        }
    }
}

protocol SnapshotClient: AnyObject {
    /// GET /snapshot — 自分視点の最新 PairSnapshot
    func fetchSnapshot() async throws -> PairSnapshot
}

// MARK: - live 実装(URLSession。supabase-swift 非依存)

final class EdgeFunctionSnapshotClient: SnapshotClient {
    /// 自己修復の取得は短く切り上げる(通信が不安定でも起動直後の読み込み表示を長く引き延ばさない。
    /// 失敗しても端末の snapshot で表示を続け、次の前面復帰・push で取り直す)
    static let requestTimeout: TimeInterval = 15

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

    func fetchSnapshot() async throws -> PairSnapshot {
        var request = try await transport.functionRequest("snapshot", method: "GET")
        request.timeoutInterval = Self.requestTimeout
        let result: (data: Data, status: Int)
        do {
            result = try await transport.send(request)
        } catch {
            throw SnapshotClientError.network
        }
        guard result.status == 200 else {
            if let code = EdgeFunctionTransport.errorCode(in: result.data) {
                throw SnapshotClientError(serverCode: code)
            }
            throw SnapshotClientError.server(code: "http_\(result.status)")
        }
        do {
            return try PairSnapshot.makeJSONDecoder()
                .decode(SnapshotResponse.self, from: result.data)
                .snapshot
        } catch {
            throw SnapshotClientError.server(code: "invalid_response")
        }
    }
}

// MARK: - スタブ(Config 未設定環境用)

/// サーバーが無い環境の「同期」: 端末の App Group にある snapshot をそのまま返す(無ければ空のソロ)。
/// これにより、スタブ構成でも同期処理が端末内の状態を巻き戻さず、画面遷移だけを検証できる
final class StubSnapshotClient: SnapshotClient {
    private let store: AppGroupStore?
    private let now: () -> Date

    init(store: AppGroupStore?, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func fetchSnapshot() async throws -> PairSnapshot {
        if let local = store?.loadSnapshot() { return local }
        return PairSnapshot.emptySolo(updatedAt: now())
    }
}

extension PairSnapshot {
    /// サーバーが「約束もペアもない新規ユーザー」に返す snapshot と同じ形
    /// (snapshot.ts buildSoloSnapshot の約束なし版。ソロの植物の成長は 0 / 0 / null — DESIGN §3.4)
    static func emptySolo(updatedAt: Date) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: currentSchemaVersion,
            pairId: nil,
            updatedAt: updatedAt,
            streakCurrent: 0,
            streakBest: 0,
            todayMeDone: false,
            todayPartnerDone: false,
            myPromiseTitle: nil,
            myPromiseEmoji: nil,
            partnerName: nil,
            partnerPromiseTitle: nil,
            partnerPromiseEmoji: nil,
            plantStage: 0,
            plantGrownDays: 0,
            plantStageFloor: 0,
            plantNextStageAt: nil,
            plantMood: .normal,
            plantName: nil,
            hasPartnerPhotoToday: false
        )
    }
}
