// AppGroupStore.swift — App Group コンテナの読み書き(DESIGN §3.3, §3.4, §3.7)
//
// コンテナ直下のファイル:
//   - pair_snapshot.json … 共有契約(スキーマは PairSnapshot.swift が正本)
//   - pending_ops.json   … 未送信キュー(キュー本体の型定義は T14)
//   - photo_thumb.jpg    … 相手の今日の写真サムネ(T17 で NSE が DL。200KB 上限)
//   - notification_prefs.json … 端末のローカル通知の設定(アプリ本体が読み書きし、NSE が読む。T16 #16。型は NotificationPreferences)
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
    static let notificationPrefsFileName = "notification_prefs.json"
    static let snapshotSyncFileName = "snapshot_sync.json"

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
    var notificationPrefsFileURL: URL { containerURL.appendingPathComponent(Self.notificationPrefsFileName) }

    // MARK: - pair_snapshot.json

    /// snapshot を読む。ファイル無し・壊れた JSON は nil(呼び出し側はプレースホルダ表示。
    /// アプリ本体はフォアグラウンド復帰時の GET /snapshot で自己修復する — DESIGN §4)
    func loadSnapshot() -> PairSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFileURL) else { return nil }
        return try? PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
    }

    /// snapshot をアトミックに書き込む(アプリ本体用)
    func saveSnapshot(_ snapshot: PairSnapshot) throws {
        try coordinateSnapshotWrite {
            let data = try PairSnapshot.makeJSONEncoder().encode(snapshot)
            try writeAtomically(data, to: snapshotFileURL)
        }
    }

    /// 生の JSON データを**検証してから**アトミックに書き込む(NSE がプッシュペイロードを渡す用)。
    /// デコードできないデータは保存せず throw する(壊れたペイロードで正常な snapshot を潰さない)
    @discardableResult
    func saveSnapshotData(_ data: Data) throws -> PairSnapshot {
        let snapshot = try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
        try saveSnapshot(snapshot)
        return snapshot
    }

    func applySnapshot(_ snapshot: PairSnapshot, ifUnchangedSince expected: PairSnapshot?) throws -> Bool {
        try coordinateSnapshotWrite {
            guard loadSnapshot() == expected else { return false }
            try writeAtomically(PairSnapshot.makeJSONEncoder().encode(snapshot), to: snapshotFileURL)
            return true
        }
    }

    func applyPushSnapshot(_ snapshot: PairSnapshot) throws -> (snapshot: PairSnapshot?, changed: Bool) {
        try coordinateSnapshotWrite {
            let previous = loadSnapshot()
            if FileManager.default.fileExists(atPath: pendingOpsFileURL.path) {
                guard let data = try? Data(contentsOf: pendingOpsFileURL),
                      let pending = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      pending.isEmpty else { return (previous, false) }
            }
            if let previous, previous.updatedAt >= snapshot.updatedAt { return (previous, false) }
            var normalized = snapshot
            normalized.updatedAt = previous?.updatedAt ?? snapshot.updatedAt
            try writeAtomically(PairSnapshot.makeJSONEncoder().encode(snapshot), to: snapshotFileURL)
            return (snapshot, normalized != previous)
        }
    }

    private func coordinateSnapshotWrite<Value>(_ write: () throws -> Value) throws -> Value {
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        NSFileCoordinator().coordinate(writingItemAt: snapshotFileURL, options: .forMerging, error: &coordinationError) { _ in
            result = Result { try write() }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
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

    // MARK: - notification_prefs.json(端末のローカル通知の設定 — T16 #16。型定義は NotificationPreferences)

    /// 設定を読む。ファイル無し・壊れた JSON は nil
    func loadNotificationPreferences<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: notificationPrefsFileURL) else { return nil }
        return try? PairSnapshot.makeJSONDecoder().decode(type, from: data)
    }

    /// 設定をアトミックに書き込む
    func saveNotificationPreferences<T: Encodable>(_ preferences: T) throws {
        let data = try PairSnapshot.makeJSONEncoder().encode(preferences)
        try writeAtomically(data, to: notificationPrefsFileURL)
    }

    /// 設定を消す。ファイルが無くても成功する
    func removeNotificationPreferences(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: notificationPrefsFileURL)
    }

    // MARK: - 「あるのに読めない」の見分け(T16 #16)

    /// snapshot のファイルが、**あるのに読めない**(中身が取り出せない・読めても snapshot として解釈できない)か。
    /// 「ファイルが無い」(まだ無い・サインアウトで消した)とは別の状態。再起動後の最初のアンロックの前は、データ保護で
    /// コンテナの中身が読めず(その間にバックグラウンドで起動されることがある)、将来のスキーマの変更や壊れた JSON でも
    /// 読めない。読めないだけのものを「無い」と取り違えて、予約済みのローカル通知をすべて消さないために使う(ReminderScheduler)
    func snapshotIsPresentButUnreadable(fileManager: FileManager = .default) -> Bool {
        isPresentButUnreadable(snapshotFileURL, fileManager: fileManager) { data in
            (try? PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)) != nil
        }
    }

    /// snapshot のファイルが、**あるのに中身を取り出せない**(データ保護で、再起動後の最初のアンロックの前は読めない)か。
    /// 壊れた JSON・将来のスキーマ(取り出せるがデコードできない)は含まない — そちらは待っても直らない。
    /// ウィジェットが、その間に「はじめよう」の表示を 1 日出しつづけず、少しあとに読み直す(WidgetTimelinePlan.lockedRetryInterval)ために使う
    func snapshotFileIsLocked(fileManager: FileManager = .default) -> Bool {
        isPresentButUnreadable(snapshotFileURL, fileManager: fileManager) { _ in true }
    }

    /// ローカル通知の設定のファイルが、**あるのに読めない**(中身が取り出せない)か。壊れた JSON は読めた扱い
    /// (設定は欠けた値を既定で埋めて読む — NotificationPreferences)
    func notificationPreferencesAreLocked(fileManager: FileManager = .default) -> Bool {
        isPresentButUnreadable(notificationPrefsFileURL, fileManager: fileManager) { _ in true }
    }

    private func isPresentButUnreadable(_ url: URL, fileManager: FileManager, accepts: (Data) -> Bool) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url) else { return true }
        return !accepts(data)
    }

    // MARK: - 全消去(アカウントの削除・サインアウト・セッション無効のあと — T23 #23)

    /// 端末に置いた記録をすべて消す(snapshot・未送信キュー・相手の写真のサムネ・ローカル通知の設定)。
    /// ウィジェットは次の reload で空の表示になる(呼び出し側が reload する)。ファイルが無くても成功する
    func eraseAll(fileManager: FileManager = .default) {
        for url in [snapshotFileURL, pendingOpsFileURL, photoThumbFileURL, notificationPrefsFileURL,
                    containerURL.appendingPathComponent(Self.snapshotSyncFileName)] {
            try? fileManager.removeItem(at: url) // 無いファイルの削除エラーは無視する
        }
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
