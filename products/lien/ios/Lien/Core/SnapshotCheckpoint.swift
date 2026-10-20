import Foundation

struct SnapshotCheckpoint: Codable {
    let snapshot: PairSnapshot
    let etag: String

    static func load(from store: AppGroupStore?) -> SnapshotCheckpoint? {
        guard let store,
              let data = try? Data(contentsOf: store.containerURL.appendingPathComponent(AppGroupStore.snapshotSyncFileName)) else {
            return nil
        }
        return try? PairSnapshot.makeJSONDecoder().decode(Self.self, from: data)
    }

    func save(to store: AppGroupStore) throws {
        try PairSnapshot.makeJSONEncoder().encode(self).write(
            to: store.containerURL.appendingPathComponent(AppGroupStore.snapshotSyncFileName), options: .atomic
        )
    }
}
