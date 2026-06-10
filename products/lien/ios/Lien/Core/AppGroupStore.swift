// AppGroupStore.swift — App Group コンテナの読み書き(DESIGN §3.3, §3.4, §3.7)
//
// コンテナ直下のファイル:
//   - pair_snapshot.json … 共有契約(スキーマは PairSnapshot.swift が正本)
//   - pending_ops.json   … 未送信キュー(キュー本体の型定義は T14)
//   - photo_thumb.jpg    … 相手の今日の写真サムネ(T17 で NSE が DL。200KB 上限)
//
// 原則(DESIGN §3.4):
//   - 書き込むのは**アプリ本体と NSE の2者だけ**。ウィジェットは読み取り専用
//   - 書き込みはアトミック(.atomic = 一時ファイル→rename。他プロセスに途中状態を見せない)
//   - コンテナ URL を注入できるため、単体テストでは temp dir を使う(FileManager 直書きに依存しない)
//
// このファイルは Lien / LienWidget / LienNSE の3ターゲットでソース共有される(project.yml 参照)。

import Foundation

struct AppGroupStore {
    enum StoreError: Error, Equatable {
        /// App Group コンテナが解決できない(entitlements 不一致など)
        case containerUnavailable(appGroupID: String)
    }

    static let snapshotFileName = "pair_snapshot.json"
    static let pendingOpsFileName = "pending_ops.json"
    static let photoThumbFileName = "photo_thumb.jpg"

    /// App Group ID を Info.plist から引くキー。
    /// 実体は Config/Base.xcconfig の LIEN_APP_GROUP_ID(project.yml が全ターゲットの Info.plist に埋め込む)
    static let appGroupIDInfoPlistKey = "LIEN_APP_GROUP_ID"

    /// 保存先コンテナ。実機/シミュレータでは App Group、テストでは temp dir
    let containerURL: URL

    /// テスト・プレビュー用: 任意のディレクトリをコンテナとして注入する
    init(containerURL: URL) {
        self.containerURL = containerURL
    }

    /// App Group ID からコンテナを解決する
    init(appGroupID: String, fileManager: FileManager = .default) throws {
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw StoreError.containerUnavailable(appGroupID: appGroupID)
        }
        self.init(containerURL: url)
    }

    /// アプリ / ウィジェット / NSE 共通の標準ストア。
    /// Info.plist に LIEN_APP_GROUP_ID が無い・コンテナ解決不能なら nil(呼び出し側はプレースホルダ等で継続)
    static func standard(bundle: Bundle = .main) -> AppGroupStore? {
        guard
            let appGroupID = bundle.object(forInfoDictionaryKey: appGroupIDInfoPlistKey) as? String,
            !appGroupID.isEmpty
        else { return nil }
        return try? AppGroupStore(appGroupID: appGroupID)
    }

    var snapshotFileURL: URL { containerURL.appendingPathComponent(Self.snapshotFileName) }
    var pendingOpsFileURL: URL { containerURL.appendingPathComponent(Self.pendingOpsFileName) }
    var photoThumbFileURL: URL { containerURL.appendingPathComponent(Self.photoThumbFileName) }

    // MARK: - pair_snapshot.json

    /// snapshot を読む。ファイル無し・壊れた JSON は nil(呼び出し側はプレースホルダ表示。
    /// アプリ本体はフォアグラウンド復帰時の GET /snapshot で自己修復する — DESIGN §4)
    func loadSnapshot() -> PairSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFileURL) else { return nil }
        return try? PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
    }

    /// snapshot をアトミックに書き込む(アプリ本体用)
    func saveSnapshot(_ snapshot: PairSnapshot) throws {
        let data = try PairSnapshot.makeJSONEncoder().encode(snapshot)
        try writeAtomically(data, to: snapshotFileURL)
    }

    /// 生の JSON データを**検証してから**アトミックに書き込む(NSE がプッシュペイロードを渡す用)。
    /// デコードできないデータは保存せず throw する(壊れたペイロードで正常な snapshot を潰さない)
    @discardableResult
    func saveSnapshotData(_ data: Data) throws -> PairSnapshot {
        let snapshot = try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
        try writeAtomically(data, to: snapshotFileURL)
        return snapshot
    }

    // MARK: - pending_ops.json(オフラインキュー — DESIGN §3.7。型定義は T14)

    /// キューを読む。ファイル無し・壊れた JSON は nil
    func loadPendingOps<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: pendingOpsFileURL) else { return nil }
        return try? PairSnapshot.makeJSONDecoder().decode(type, from: data)
    }

    /// キューをアトミックに書き込む
    func savePendingOps<T: Encodable>(_ ops: T) throws {
        let data = try PairSnapshot.makeJSONEncoder().encode(ops)
        try writeAtomically(data, to: pendingOpsFileURL)
    }

    /// キューを破棄する(全件送信成功時)
    func clearPendingOps(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: pendingOpsFileURL.path) else { return }
        try fileManager.removeItem(at: pendingOpsFileURL)
    }

    // MARK: - private

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }
}
