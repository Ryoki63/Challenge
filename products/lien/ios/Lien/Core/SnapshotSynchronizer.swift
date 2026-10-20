// SnapshotSynchronizer.swift — GET /snapshot の結果を App Group へ反映する(DESIGN §4 自己修復 / issue #55)
//
// 状態の正はサーバー。起動時・前面復帰時・push 受信時に最新の snapshot を取得して
// pair_snapshot.json を上書きし、ウィジェットを reload する。
//   - 招待した側がペア成立を知る(solo → paired)
//   - ペア解消の反映(paired → solo)
//   - push の取りこぼし・日付跨ぎ・他端末での変更の回復
//
// ただし**端末側の方が新しい可能性があるときは上書きしない**(楽観更新を巻き戻さない):
//   1. 未送信キュー(pending_ops.json)が残っている — オフラインで記録したチェックインが
//      まだサーバーに届いていない。サーバーの snapshot は「未完」のままなので、上書きすると
//      画面が一瞬戻って見える。キューが空になった次回の同期で反映される
//   2. 取得中に端末の snapshot が変わった — ホームのチェックイン完了や NSE の書き込みが
//      この取得より後の状態を保存した。取得結果の方が古いので捨てる
//   3. アカウントの削除・サインアウトで端末の記録を消している最中(canApply が false)— 古いアカウントの
//      snapshot を、消したあとに書き戻さない(T23 #23)
// 取得に失敗したときは端末の snapshot をそのまま残す(オフラインでも表示は壊れない)。

import Foundation

@MainActor
final class SnapshotSynchronizer {
    enum Failure: Equatable {
        case unauthorized
        case userNotFound
        case network
        case server
        /// App Group への書き込みに失敗した
        case storage
    }

    enum Outcome: Equatable {
        /// サーバーの snapshot を端末へ反映した
        case applied(PairSnapshot)
        /// 未送信のチェックイン操作が残っているため反映しなかった
        case skippedPendingOps
        /// 取得中に端末の snapshot が更新されたため、取得結果を捨てた
        case skippedLocalChanged
        /// アカウントの削除・サインアウトで端末の記録を消している最中のため、取得結果を捨てた
        case skippedSessionEnded
        case failed(Failure)
    }

    private let client: SnapshotClient
    private let store: AppGroupStore?
    private let hasPendingOps: () -> Bool
    private let reloadWidgets: () -> Void
    private let canApply: @MainActor () -> Bool
    private let retryDelay: () async throws -> Void

    /// - canApply: false の間は、取得できても端末へ書かない(アカウントの削除・サインアウトの最中 — T23 #23)
    init(
        client: SnapshotClient,
        store: AppGroupStore?,
        hasPendingOps: @escaping () -> Bool = { false },
        reloadWidgets: @escaping () -> Void = {},
        canApply: @escaping @MainActor () -> Bool = { true },
        retryDelay: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }
    ) {
        self.client = client
        self.store = store
        self.hasPendingOps = hasPendingOps
        self.reloadWidgets = reloadWidgets
        self.canApply = canApply
        self.retryDelay = retryDelay
    }

    func sync() async -> Outcome {
        let first = await syncOnce()
        guard first == .failed(.network) || first == .failed(.server) || first == .failed(.storage),
              canApply(), !Task.isCancelled else { return first }
        do { try await retryDelay() } catch { return first }
        guard canApply(), !Task.isCancelled else { return .skippedSessionEnded }
        return await syncOnce()
    }

    private func syncOnce() async -> Outcome {
        let before = store?.loadSnapshot()
        let checkpoint = SnapshotCheckpoint.load(from: store)
        let etag = checkpoint?.snapshot == before ? checkpoint?.etag : nil

        let changes: SnapshotChanges
        do {
            changes = try await client.fetchChanges(etag: etag)
        } catch let error as SnapshotClientError {
            return .failed(Self.failure(for: error))
        } catch {
            // トークン取得の失敗(未サインイン・更新失敗)など。再送可能な一時エラーとして扱う
            return .failed(.network)
        }

        if !canApply() { return .skippedSessionEnded }
        if hasPendingOps() { return .skippedPendingOps }
        if store?.loadSnapshot() != before { return .skippedLocalChanged }

        let fetched: PairSnapshot
        let nextEtag: String?
        switch changes {
        case .snapshot(let snapshot, let etag):
            fetched = snapshot
            nextEtag = etag
        case .unchanged(let confirmedAt):
            guard var confirmed = before, let etag else { return .failed(.server) }
            confirmed.updatedAt = max(confirmed.updatedAt, confirmedAt)
            fetched = confirmed
            nextEtag = etag
        }

        if let store {
            do {
                guard try store.applySnapshot(fetched, ifUnchangedSince: before) else { return .skippedLocalChanged }
                if Self.hasVisibleChange(from: before, to: fetched) { reloadWidgets() }
                if let nextEtag { try SnapshotCheckpoint(snapshot: fetched, etag: nextEtag).save(to: store) }
            } catch {
                return .failed(.storage)
            }
        }
        return .applied(fetched)
    }

    private static func failure(for error: SnapshotClientError) -> Failure {
        switch error {
        case .unauthorized: return .unauthorized
        case .userNotFound: return .userNotFound
        case .network: return .network
        case .server: return .server
        }
    }

    /// updatedAt(サーバーが組み立てた時刻)以外に差があるか
    static func hasVisibleChange(from old: PairSnapshot?, to new: PairSnapshot) -> Bool {
        guard let old else { return true }
        var normalized = new
        normalized.updatedAt = old.updatedAt
        return normalized != old
    }
}
