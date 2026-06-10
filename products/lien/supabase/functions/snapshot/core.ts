// snapshot/core.ts — GET /snapshot の本体ロジック(I/O はリポジトリ注入)
//
// 正本: docs/DESIGN.md §5.3「snapshot: 自分視点の PairSnapshot(起動時の自己修復用)」/ §4
//   - アプリ本体はフォアグラウンド復帰時に必ずこれで最新を取得し App Group を上書きする
//   - 組み立ては _shared/snapshot.ts の loadSnapshotForUser(checkin と同じ一本道)

import {
  loadSnapshotForUser,
  type PairSnapshot,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";

export interface SnapshotDeps {
  repo: SnapshotRepo;
  now?: () => Date;
}

export type SnapshotResult =
  | { status: 200; body: { snapshot: PairSnapshot } }
  | { status: 404; body: { error: string } };

export async function handleSnapshot(
  deps: SnapshotDeps,
  req: { userId: string },
): Promise<SnapshotResult> {
  const now = deps.now ?? (() => new Date());
  const user = await deps.repo.getUser(req.userId);
  if (!user) {
    return { status: 404, body: { error: "user_not_found" } };
  }
  const snapshot = await loadSnapshotForUser(deps.repo, {
    userId: req.userId,
    now: now(),
  });
  return { status: 200, body: { snapshot } };
}
