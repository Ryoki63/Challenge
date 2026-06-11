// CheckinAPIClient.swift — チェックイン API(checkin / checkin-cancel / 写真アップロード)のクライアント抽象(T14)
//
// - View から直接呼ばない。利用者は CheckinService(楽観更新+オフラインキューの持ち主)
// - live 実装(EdgeFunctionCheckinClient)は URLSession ベース。baseURL と認証トークンを
//   プロバイダ注入にする(T12 EdgeFunctionPromiseClient と同じイディオム。
//   実 Supabase との疎通検証は G0 デプロイ後の実機 E2E — issue #14)
// - 写真は署名付きアップロードURL方式(DESIGN §5.6 — issue #48):
//   checkin(requestPhotoUpload: true) で原寸+サムネ2本の { path, token } を受け取り、
//   Storage へ直接 PUT する(Edge Function でバイナリを中継しない)
// - エラーコード文字列の正本: checkin/core.ts / checkin-cancel/core.ts / 各 index.ts

import Foundation

// MARK: - 応答モデル(契約の正本はサーバー実装。デコードは PairSnapshot.makeJSONDecoder())

/// 署名付きアップロードURLの1本分(checkin/core.ts PhotoUploadTarget)。
/// path はそのまま photoPath として checkin 再送に使う
struct PhotoUploadTarget: Equatable, Sendable, Codable {
    let path: String
    let token: String
}

/// 原寸+サムネの2本セット(checkin/core.ts PhotoUploadUrls。サムネは NSE 用 200KB 上限)
struct PhotoUploadURLs: Equatable, Sendable, Codable {
    let photo: PhotoUploadTarget
    let thumb: PhotoUploadTarget
}

/// POST /checkin の 200 応答(checkin/core.ts CheckinResult)
struct CheckinResponse: Equatable, Sendable, Codable {
    /// true = 同日重複リクエスト(サーバーは 200 冪等 — DESIGN §5.5)
    let alreadyCheckedIn: Bool
    /// 受信者(自分)視点の snapshot。これが状態の正(DESIGN §3.3)
    let snapshot: PairSnapshot
    /// requestPhotoUpload: true のときのみ存在
    let photoUpload: PhotoUploadURLs?
}

/// POST /checkin-cancel の 200 応答(checkin-cancel/core.ts CheckinCancelResult)
struct CheckinCancelResponse: Equatable, Sendable, Codable {
    /// true = 該当 checkin が既に無かった(冪等リトライ・日付跨ぎ直後の取消で起きる)
    let alreadyCanceled: Bool
    let snapshot: PairSnapshot
}

// MARK: - エラー

/// サーバーの error 文字列 → クライアントのエラー型。
/// 文字列はサーバー実装からコピーしたもの(変更時は両方を直すこと — T11/T12 と同じ契約整合方針)
enum CheckinClientError: Error, Equatable {
    /// "invalid_date_local" — 400(形式不正)
    case invalidDateLocal
    /// "date_local_out_of_range" — 400(checkin: 今日から±1日超 = 遡及不可 §3.4)
    case dateOutOfRange
    /// "date_local_not_today" — 400(checkin-cancel: 取り消しは当日中のみ §3.4)
    case notToday
    /// "no_promise" — 409(現役の約束が無い。約束設定 → チェックインの順)
    case noPromise
    /// "no_pair" — 400(requestPhotoUpload をソロ状態で要求 — DESIGN §5.6)
    case noPair
    /// "invalid_photo_path" — 400(パス規約 'pairs/<pair_id>/...' 違反)
    case invalidPhotoPath
    /// "user_not_found" — 404
    case userNotFound
    /// "unauthorized" — 401(トークン失効等)
    case unauthorized
    /// 上記以外のサーバーエラー("internal_error" / "invalid_json" 等)
    case server(code: String)
    /// 通信エラー(オフライン・タイムアウト等)。キュー保持して再送する唯一のケース
    case network

    /// サーバー応答 body の error 文字列からマップする(出典: checkin / checkin-cancel の core.ts / index.ts)
    init(serverCode: String) {
        switch serverCode {
        case "invalid_date_local": self = .invalidDateLocal
        case "date_local_out_of_range": self = .dateOutOfRange
        case "date_local_not_today": self = .notToday
        case "no_promise": self = .noPromise
        case "no_pair": self = .noPair
        case "invalid_photo_path": self = .invalidPhotoPath
        case "user_not_found": self = .userNotFound
        case "unauthorized": self = .unauthorized
        default: self = .server(code: serverCode)
        }
    }

    /// 再送(キュー残存)すべき一時エラーか。
    /// network のみ true。4xx/5xx の応答が返ったものは再送しても結果が変わらないため破棄し、
    /// snapshot 自己修復(フォアグラウンド復帰時の再同期 — DESIGN §4)に委ねる
    var isRetryable: Bool { self == .network }
}

// MARK: - プロトコル

/// チェックイン API(DESIGN §5.3 checkin / checkin-cancel、§5.6 写真)
protocol CheckinAPIClient: AnyObject {
    /// POST /checkin — 冪等 upsert。photoPath で写真添付/差し替え、
    /// requestPhotoUpload で署名付きアップロードURLを同時取得
    func checkin(
        dateLocal: String,
        photoPath: String?,
        requestPhotoUpload: Bool
    ) async throws -> CheckinResponse

    /// POST /checkin-cancel — 当日のみ削除(冪等。行が無くても 200)
    func cancelCheckin(dateLocal: String) async throws -> CheckinCancelResponse

    /// 署名付きアップロードURLへ JPEG を直接 PUT する(DESIGN §5.6)
    func uploadPhoto(_ data: Data, to target: PhotoUploadTarget) async throws
}

// MARK: - live 実装(URLSession。supabase-swift 非依存 — T12 と同じイディオム)

/// Edge Function `checkin` / `checkin-cancel` と Storage 署名URLアップロードを直接叩く実装。
/// baseURL(https://<ref>.supabase.co)と JWT のプロバイダを注入する
/// (トークンの取得元 = supabase-swift セッションへの結線はアプリ組み立て側の責務)
final class EdgeFunctionCheckinClient: CheckinAPIClient {
    /// リクエスト body(キー名は checkin/index.ts の payload と一致)。
    /// nil のフィールドは JSON から省かれる(synthesized Encodable = encodeIfPresent)
    private struct CheckinRequestBody: Encodable {
        let dateLocal: String
        let photoPath: String?
        let requestPhotoUpload: Bool?
    }

    private struct CancelRequestBody: Encodable {
        let dateLocal: String
    }

    private struct ErrorBody: Decodable {
        let error: String
    }

    /// 写真バケット名(0001_init.sql §6 の photos バケット)
    static let photosBucket = "photos"

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

    func checkin(
        dateLocal: String,
        photoPath: String?,
        requestPhotoUpload: Bool
    ) async throws -> CheckinResponse {
        try await postFunction(
            "checkin",
            body: CheckinRequestBody(
                dateLocal: dateLocal,
                photoPath: photoPath,
                requestPhotoUpload: requestPhotoUpload ? true : nil
            )
        )
    }

    func cancelCheckin(dateLocal: String) async throws -> CheckinCancelResponse {
        try await postFunction("checkin-cancel", body: CancelRequestBody(dateLocal: dateLocal))
    }

    func uploadPhoto(_ data: Data, to target: PhotoUploadTarget) async throws {
        guard let url = Self.signedUploadURL(baseURL: baseURL, target: target) else {
            throw CheckinClientError.server(code: "invalid_upload_url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        // 同日の差し替え(DESIGN §5.6 upsert)。トークン側も upsert: true で発行されている
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.httpBody = data

        let (responseData, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw CheckinClientError.network
        }
        guard (200..<300).contains(http.statusCode) else {
            if let body = try? JSONDecoder().decode(ErrorBody.self, from: responseData) {
                throw CheckinClientError.server(code: body.error)
            }
            throw CheckinClientError.server(code: "http_\(http.statusCode)")
        }
    }

    /// 署名付きアップロードURL(storage-js uploadToSignedUrl と同じエンドポイント):
    /// PUT {base}/storage/v1/object/upload/sign/{bucket}/{path}?token={token}
    static func signedUploadURL(baseURL: URL, target: PhotoUploadTarget) -> URL? {
        let url = baseURL
            .appendingPathComponent("storage/v1/object/upload/sign")
            .appendingPathComponent(Self.photosBucket)
            .appendingPathComponent(target.path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: target.token)]
        return components?.url
    }

    // MARK: private

    private func postFunction<Body: Encodable, Response: Decodable>(
        _ name: String,
        body: Body
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent("functions/v1/\(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await tokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw CheckinClientError.network
        }
        guard http.statusCode == 200 else {
            // 失敗応答は { "error": "<code>" }(checkin/index.ts json())
            if let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw CheckinClientError(serverCode: errorBody.error)
            }
            throw CheckinClientError.server(code: "http_\(http.statusCode)")
        }
        return try PairSnapshot.makeJSONDecoder().decode(Response.self, from: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            // 応答が返らない失敗(オフライン・タイムアウト等)だけが network = 再送対象
            throw CheckinClientError.network
        }
    }
}

// MARK: - スタブ(実サーバー疎通前のアプリ実行・プレビュー用。StubPromiseAPIClient と同じ役割)

/// メモリ内で成功応答だけ返すスタブ。サーバーの冪等性(同日重複は 200)と
/// 「checkin → snapshot 反映」の不変条件を最小限に再現する
final class StubCheckinAPIClient: CheckinAPIClient {
    /// サーバー側状態の代わり(受信者視点の snapshot)。テスト・プレビューが初期値を与える
    private(set) var snapshot: PairSnapshot
    private(set) var uploadedTargets: [PhotoUploadTarget] = []
    private let now: () -> Date

    init(snapshot: PairSnapshot, now: @escaping () -> Date = Date.init) {
        self.snapshot = snapshot
        self.now = now
    }

    func checkin(
        dateLocal: String,
        photoPath: String?,
        requestPhotoUpload: Bool
    ) async throws -> CheckinResponse {
        let already = snapshot.todayMeDone
        snapshot.todayMeDone = true
        if snapshot.todayPartnerDone {
            snapshot.plantMood = .happy
        }
        snapshot.updatedAt = now()

        var photoUpload: PhotoUploadURLs?
        if requestPhotoUpload {
            guard let pairId = snapshot.pairId else { throw CheckinClientError.noPair }
            // パス規約はサーバー(checkin/core.ts photoUploadPaths)と一致させる
            let dir = "pairs/\(pairId)/\(dateLocal)"
            photoUpload = PhotoUploadURLs(
                photo: PhotoUploadTarget(path: "\(dir)/photo.jpg", token: "stub-token-photo"),
                thumb: PhotoUploadTarget(path: "\(dir)/photo_thumb.jpg", token: "stub-token-thumb")
            )
        }
        return CheckinResponse(alreadyCheckedIn: already, snapshot: snapshot, photoUpload: photoUpload)
    }

    func cancelCheckin(dateLocal: String) async throws -> CheckinCancelResponse {
        let already = !snapshot.todayMeDone
        snapshot.todayMeDone = false
        if snapshot.plantMood == .happy {
            snapshot.plantMood = snapshot.todayPartnerDone ? .fidget : .normal
        }
        snapshot.updatedAt = now()
        return CheckinCancelResponse(alreadyCanceled: already, snapshot: snapshot)
    }

    func uploadPhoto(_ data: Data, to target: PhotoUploadTarget) async throws {
        uploadedTargets.append(target)
    }
}
