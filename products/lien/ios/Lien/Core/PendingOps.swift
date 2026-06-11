// PendingOps.swift — チェックイン操作のオフラインキュー(T14 / DESIGN §3.7)
//
// - 操作はまず pending_ops.json(App Group)に積み、即座に UI 反映(楽観更新)。
//   送信成功でキューから削除。再送はアプリ起動時+フォアグラウンド復帰時
// - サーバー側が冪等(checkin: 同 user×date 重複は 200 / checkin-cancel: 行不在も 200)
//   なので再送は安全
// - キューの正規化(enqueue 時):
//   * 同日 checkin の重複はマージ(photoPath は新しい非 nil が勝ち、nil なら既存を維持 = 昇格)
//   * 同日の checkin → checkinCancel は相殺(両方消える。未送信のチェックインの取消は
//     サーバーに何も伝える必要がない)
//   * checkinCancel の同日重複は1件に集約
//   * 日付が違う op 同士は互いに干渉しない(日付跨ぎ後も前日分はそのまま再送 —
//     checkin はサーバーが±1日許容、cancel は 400 date_local_not_today で破棄される)
// - 壊れた JSON は空キュー扱い(AppGroupStore.loadPendingOps が nil を返す)

import Foundation

/// 未送信のチェックイン操作1件(pending_ops.json の要素)
enum PendingOp: Equatable, Codable {
    /// POST /checkin(photoPath 付きは写真添付の再送)
    case checkin(dateLocal: String, photoPath: String?)
    /// POST /checkin-cancel
    case checkinCancel(dateLocal: String)

    var dateLocal: String {
        switch self {
        case .checkin(let dateLocal, _): return dateLocal
        case .checkinCancel(let dateLocal): return dateLocal
        }
    }

    var isCheckin: Bool {
        if case .checkin = self { return true }
        return false
    }
}

/// pending_ops.json の読み書き+正規化。
/// 保存は都度ファイルへ(read-modify-write)。呼び出しは MainActor(HomeViewModel 経由)前提
final class PendingOpsQueue {
    private let store: AppGroupStore

    init(store: AppGroupStore) {
        self.store = store
    }

    /// 現在のキュー(送信順)。ファイル無し・壊れた JSON は空キュー
    func load() -> [PendingOp] {
        store.loadPendingOps([PendingOp].self) ?? []
    }

    var isEmpty: Bool { load().isEmpty }

    /// 同日の未送信 checkin が積まれているか(相殺判定用 — CheckinService)
    func containsCheckin(dateLocal: String) -> Bool {
        load().contains { $0.isCheckin && $0.dateLocal == dateLocal }
    }

    func contains(_ op: PendingOp) -> Bool {
        load().contains(op)
    }

    /// 正規化しつつ末尾に積む(ルールはファイル冒頭コメント)
    func enqueue(_ op: PendingOp) {
        var ops = load()
        switch op {
        case .checkin(let dateLocal, let photoPath):
            if let index = ops.firstIndex(where: { $0.isCheckin && $0.dateLocal == dateLocal }) {
                // 同日 checkin のマージ: photoPath は新しい非 nil が勝ち、nil なら既存を維持(昇格)
                if case .checkin(_, let existingPhotoPath) = ops[index] {
                    ops[index] = .checkin(
                        dateLocal: dateLocal,
                        photoPath: photoPath ?? existingPhotoPath
                    )
                }
            } else {
                // 同日の cancel が先に積まれていても消さない(cancel → checkin の順送信が正しい網結果)
                ops.append(op)
            }
        case .checkinCancel(let dateLocal):
            let hadPendingCheckin = ops.contains { $0.isCheckin && $0.dateLocal == dateLocal }
            ops.removeAll { $0.isCheckin && $0.dateLocal == dateLocal }
            // 相殺: 未送信の checkin があった = サーバーは元から未記録なので cancel も送らない。
            // (まれに「送信成功直後のクラッシュで op だけ残っていた」場合はサーバーに行が残るが、
            //  フォアグラウンド復帰時の snapshot 自己修復で表示が正に揃う — DESIGN §4)
            if !hadPendingCheckin && !ops.contains(op) {
                ops.append(op)
            }
        }
        save(ops)
    }

    /// flush 後の残りを書き戻す(全送信成功なら空 = ファイル削除)
    func replaceAll(_ ops: [PendingOp]) {
        save(ops)
    }

    // MARK: private

    private func save(_ ops: [PendingOp]) {
        if ops.isEmpty {
            // 空キューはファイルごと破棄(AppGroupStore のコメントどおり全件送信成功時の形)
            try? store.clearPendingOps()
        } else {
            // 書き込み失敗(ディスク満杯等)は握りつぶす: キューは最適化であって正ではない。
            // 失われても snapshot 自己修復+ユーザーの再操作で回復できる
            try? store.savePendingOps(ops)
        }
    }
}
