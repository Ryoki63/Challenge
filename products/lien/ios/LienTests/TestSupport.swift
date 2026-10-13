// TestSupport.swift — issue #55 のテストが共有する道具
//
//   - StubURLProtocol : URLSession をネットワーク無しで差し替える(リクエストの記録+応答の注入)
//   - SnapshotFactory : PairSnapshot の最小ファクトリ(ソロ / ペア / 約束なし)
//   - ContractFixtures: products/lien/contracts/*.json(テストバンドルのリソース)の読み込み
//   - TempStore       : temp dir の AppGroupStore

import Foundation
import XCTest
@testable import Lien

// MARK: - URLProtocol スタブ

/// 記録されたリクエスト(URLProtocol には httpBody でなく httpBodyStream で渡るため本文を別に保持する)
struct CapturedRequest {
    let request: URLRequest
    let body: Data?

    var url: URL? { request.url }
    var method: String? { request.httpMethod }
    func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }

    /// 本文を JSON オブジェクト(辞書)として読む
    var jsonObject: [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

final class StubURLProtocol: URLProtocol {
    /// リクエスト → (ステータス, 本文)。throw すると通信エラー(応答なし)になる
    static var handler: ((URLRequest) throws -> (status: Int, body: Data))?
    private(set) static var captured: [CapturedRequest] = []

    static func reset() {
        handler = nil
        captured = []
    }

    /// このスタブだけを使う URLSession
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured.append(CapturedRequest(request: request, body: Self.readBody(of: request)))
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        do {
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - snapshot ファクトリ

enum SnapshotFactory {
    static let fixedDate = Date(timeIntervalSince1970: 1_781_166_600) // 2026-06-11T08:30:00Z

    /// 約束あり・ペアなし(ソロのホーム)
    static func solo(todayMeDone: Bool = false, updatedAt: Date = fixedDate) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: nil,
            updatedAt: updatedAt,
            streakCurrent: 0,
            streakBest: 0,
            todayMeDone: todayMeDone,
            todayPartnerDone: false,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: nil,
            partnerPromiseTitle: nil,
            partnerPromiseEmoji: nil,
            plantStage: 0,
            plantMood: .normal,
            plantName: nil,
            hasPartnerPhotoToday: false
        )
    }

    /// 約束なし・ペアなし(オンボ直後にサーバーが返す形)
    static func noPromise(updatedAt: Date = fixedDate) -> PairSnapshot {
        PairSnapshot.emptySolo(updatedAt: updatedAt)
    }

    /// 約束あり・ペア成立
    static func paired(
        todayMeDone: Bool = false,
        todayPartnerDone: Bool = false,
        updatedAt: Date = fixedDate
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
            updatedAt: updatedAt,
            streakCurrent: 23,
            streakBest: 40,
            todayMeDone: todayMeDone,
            todayPartnerDone: todayPartnerDone,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: 3,
            plantMood: .normal,
            plantName: "みどり",
            hasPartnerPhotoToday: false
        )
    }
}

// MARK: - 呼び出し回数カウンタ・待機

/// ウィジェット reload などの呼び出し回数(@MainActor 上のクロージャから更新する)
@MainActor
final class ReloadCounter {
    var value = 0
}

/// 条件が成り立つまで(最大 timeout 秒)待つ。Task { ... } で投げ捨てた非同期処理の完了待ち用。
/// 成り立てば即座に返るので、上限は CI ランナーの一時的な遅さに耐えられる長さにしてある
@MainActor
func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

// MARK: - 非同期処理を途中で止めておく門

/// テストが、非同期処理を途中(通信の最中など)で止めておくための門。open() するまで wait() が返らない。
/// 止まっている間の状態を観測してから open() で先へ進める(割り込みの再入のテストなど)。
/// wait() が止まる前に open() が呼ばれても、取りこぼさず、すぐ返る(ロックで守っている)
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}

// MARK: - temp dir ストア

struct TempStore {
    let store: AppGroupStore
    let directory: URL

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LienTests-\(UUID().uuidString)", isDirectory: true)
        store = AppGroupStore(containerURL: directory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - 契約フィクスチャ(products/lien/contracts/*.json — project.yml が LienTests のリソースに含める)

enum ContractFixtures {
    enum LoadError: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let name):
                return "契約フィクスチャ \(name).json がテストバンドルに無い(products/lien/contracts/ と project.yml の LienTests sources を確認)"
            }
        }
    }

    private final class BundleToken {}

    /// 拡張子 .json を除いた名前(例: "snapshot.paired")で読み込む。
    /// 探す順: ① テストバンドルのリソース(project.yml が ../contracts/*.json を含める)
    ///        ② 環境変数 LIEN_CONTRACTS_DIR のディレクトリ(Xcode 外で swiftc から直接実行する手元の検証用)
    ///        ③ このソースファイルから辿ったリポジトリ内の contracts/(シミュレータはホストのファイルを読める)
    static func data(_ name: String, file: StaticString = #filePath) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        if let dir = ProcessInfo.processInfo.environment["LIEN_CONTRACTS_DIR"] {
            return try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(name).json"))
        }
        // LienTests/TestSupport.swift → ios/ → lien/ → lien/contracts/
        let sourceRelative = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // LienTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // lien
            .appendingPathComponent("contracts")
            .appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: sourceRelative) {
            return data
        }
        throw LoadError.missing(name)
    }

    /// JSON オブジェクト(辞書)として読む
    static func object(_ name: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data(name))
        guard let dict = value as? [String: Any] else { throw LoadError.missing(name) }
        return dict
    }

    /// 2xx 応答の本文を型へデコードする(アプリの本番デコーダと同じ設定)
    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try PairSnapshot.makeJSONDecoder().decode(type, from: data(name))
    }
}
