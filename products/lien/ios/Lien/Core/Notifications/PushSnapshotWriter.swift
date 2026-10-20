import Foundation

struct PushSnapshotWriter {
    let store: AppGroupStore
    var reloadWidgets: () -> Void = {}

    func receive(_ userInfo: [AnyHashable: Any]) throws -> PairSnapshot? {
        guard let lien = userInfo["lien"] as? [String: Any],
              let object = lien["snapshot"],
              JSONSerialization.isValidJSONObject(object) else { return nil }
        let data = try JSONSerialization.data(withJSONObject: object)
        let snapshot = try PairSnapshot.makeJSONDecoder().decode(PairSnapshot.self, from: data)
        let applied = try store.applyPushSnapshot(snapshot)
        if applied.changed { reloadWidgets() }
        return applied.snapshot
    }
}

final class NotificationDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered else { return false }
        delivered = true
        return true
    }
}
