// StoragePhotoURLSigner.swift — photos バケットの署名付き URL をクライアントで作る(PV / issue #59)
//
// 相手の今日の写真を読むための、短寿命の署名付き URL を、利用者の JWT で Storage に作らせる:
//   POST {base}/storage/v1/object/sign/photos/{photo_path}   body {"expiresIn": 3600}
//   200 → {"signedURL": "/object/sign/photos/<photo_path>?token=<署名>"}   (契約: contracts/storage-sign.ok.json)
//
// 新しい Edge Function は増やさない(migration 0001 の想定「配布の主経路は Function が発行する署名付き URL」は
// v1.0 では採らない — TASKPLAN §9.4 PV)。読み取りの可否は DB の RLS が決める:
//   - photos_select_pair_member : パスの第2セグメントが自分の「現役」ペアの pair_id のオブジェクトだけ
//     (パスの深さを問わない。migration 0004 の `<user_id>/` 区画でも読める)
//   - ペア解消後は select ポリシーが弾くので署名付き URL を作れず、画像は見えない(DESIGN §5.7 の3番)
//
// - 認証: `Authorization: Bearer <ユーザー JWT>` と `apikey`(anon / publishable キー。storage-js と同じ)
// - 署名付き URL は短寿命(3600 秒)。App Group にも永続領域にも保存しない。使う直前に作る
// - 応答の `signedURL` は Storage のルート相対('/object/sign/…')。`{base}/storage/v1` を前に付けて絶対 URL にする
//   (storage-js の createSignedUrl と同じ。'/storage/v1/…' で始まる形が返っても二重に付けない)

import Foundation

// MARK: - 抽象

/// 署名付き URL(`expiresAt` までの間だけ読める)
struct SignedPhotoURL: Equatable, Sendable {
    let url: URL
    let expiresAt: Date
}

protocol PhotoURLSigning: AnyObject {
    /// photos バケットのオブジェクトの署名付き URL を作る。
    /// 規約に合わないパスは `PartnerPhotoError.invalidPath`。未サインインは `AuthServiceError.notSignedIn`(そのまま throw)
    func signedURL(forPath path: String) async throws -> SignedPhotoURL
}

// MARK: - 応答

/// POST /storage/v1/object/sign/{bucket}/{path} の 200 応答(contracts/storage-sign.ok.json)
struct StorageSignResponse: Equatable, Sendable {
    /// Storage のルート相対の署名付き URL('/object/sign/photos/…?token=…')
    let signedURL: String
}

extension StorageSignResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case signedURL
        case signedUrl // 版によって綴りが違う場合に備える(storage-js のドキュメントは signedURL)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .signedURL) {
            signedURL = value
        } else {
            signedURL = try container.decode(String.self, forKey: .signedUrl)
        }
    }
}

// MARK: - live 実装(URLSession。supabase-swift 非依存)

final class StoragePhotoURLSigner: PhotoURLSigning {
    /// 写真のバケット名(0001_init.sql §6)
    static let bucket = "photos"
    /// 署名付き URL の寿命(秒)
    static let expiresInSeconds = 3600
    /// 署名の要求は短く切り上げる(通信が不安定でもホームの表示を待たせない。失敗したら写真を出さないだけ)
    static let requestTimeout: TimeInterval = 15

    private struct RequestBody: Encodable {
        let expiresIn: Int
    }

    private let baseURL: URL
    private let apiKey: String
    private let tokenProvider: () async throws -> String
    private let session: URLSession
    private let now: () -> Date

    init(
        baseURL: URL,
        apiKey: String,
        tokenProvider: @escaping () async throws -> String,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tokenProvider = tokenProvider
        self.session = session
        self.now = now
    }

    func signedURL(forPath path: String) async throws -> SignedPhotoURL {
        guard PartnerPhotoPath.isSafeObjectPath(path) else { throw PartnerPhotoError.invalidPath }

        var url = baseURL
            .appendingPathComponent("storage/v1/object/sign")
            .appendingPathComponent(Self.bucket)
        for segment in path.split(separator: "/") {
            url = url.appendingPathComponent(String(segment))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        let token = try await tokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(RequestBody(expiresIn: Self.expiresInSeconds))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PartnerPhotoError.mapping(error)
        }
        guard let http = response as? HTTPURLResponse else { throw PartnerPhotoError.network }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw PartnerPhotoError.unauthorized
        case 404:
            throw PartnerPhotoError.notFound
        default:
            throw PartnerPhotoError.server(status: http.statusCode)
        }

        guard
            let decoded = try? JSONDecoder().decode(StorageSignResponse.self, from: data),
            let signed = Self.absoluteURL(baseURL: baseURL, signedPath: decoded.signedURL)
        else { throw PartnerPhotoError.invalidResponse }

        return SignedPhotoURL(url: signed, expiresAt: now().addingTimeInterval(TimeInterval(Self.expiresInSeconds)))
    }

    // MARK: URL の組み立て

    /// 応答の `signedURL` を、ダウンロードに使う絶対 URL にする。
    /// - ルート相対('/object/sign/…')→ `{base}/storage/v1` を前に付ける
    /// - '/storage/v1/…' で始まる形 → `{base}` だけを前に付ける(二重に付けない)
    /// - 絶対 URL → 接続先(base)と同じホストのものだけ受け付ける(よそのホストへ読みに行かない)
    static func absoluteURL(baseURL: URL, signedPath: String) -> URL? {
        let trimmed = signedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: URL?
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            candidate = URL(string: trimmed)
        } else {
            let base = baseURL.absoluteString.hasSuffix("/")
                ? String(baseURL.absoluteString.dropLast())
                : baseURL.absoluteString
            let relative = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
            let prefix = relative.hasPrefix("/storage/v1/") ? "" : "/storage/v1"
            candidate = URL(string: base + prefix + relative)
        }

        guard
            let url = candidate,
            let host = url.host, host == baseURL.host,
            url.scheme == baseURL.scheme
        else { return nil }
        return url
    }
}
