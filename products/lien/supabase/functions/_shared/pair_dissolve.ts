// _shared/pair_dissolve.ts — ペアの解消(pair-dissolve と delete-account が共有する本体)
//
// 正本: docs/REQUIREMENTS.md §3.2「ペア解消」・§8(通報導線とブロック = ペア解消)/ docs/DESIGN.md §5.3
//        / issue #23(T23 審査対応一式)
//
// 解消の中身(REQUIREMENTS §3.2。DB の整合は migration 0001 の pairs_dissolved_at_consistency):
//   - pairs.status を 'dissolved' にし、dissolved_at を同時に打刻する(CHECK で status ⇔ dissolved_at が強制される)
//   - 自分のチェックイン履歴は残る / 共有していた写真は相互に非表示になる / 植物・ストリークはアーカイブされる
//     (復縁時も復活しない)。これらは行を消さずに status を変えるだけで成り立つ:
//       * 写真・相手の約束・相手のチェックイン・リアクション: RLS が「現役(active)ペア」だけを相互に読ませる
//         (shares_active_pair_with / is_active_pair_member — migration 0001)ので、解消の瞬間に読めなくなる
//       * 植物・ストリーク・チケット台帳: pair スコープのまま残り、メンバーなら読める(アーカイブ閲覧)。
//         snapshot は現役ペアだけを見る(getActivePair)ので、解消後はソロの形に戻る
//   - 冪等: 現役のペアが無ければ何もしない(dissolved: false)。再送・同時に相手が先に解消した場合も安全
//
// このファイルは I/O を持たない(リポジトリを注入)。push の送信は各 core.ts が行う
// (push を送る Function は core.ts の中で sendOptionsFor を付けて pusher.send を呼ぶ、という
// scripts/ops/push_env_static_test.ts の約束を、各 core.ts に残すため)。

import type { SnapshotRepo, SnapshotUserRow } from "./snapshot.ts";

export interface PairDissolveRepo extends SnapshotRepo {
  /**
   * 現役のペアを解消済みにする:
   *   UPDATE pairs SET status = 'dissolved', dissolved_at = <dissolvedAtIso>
   *   WHERE id = <pairId> AND status = 'active'
   * 解消できたら true。すでに解消済みだった(同時に相手が先に解消した等)なら false
   */
  dissolvePair(pairId: string, dissolvedAtIso: string): Promise<boolean>;
}

export interface DissolveOutcome {
  /** このリクエストでペアを解消したか(現役のペアが無かった・先に解消されていた場合は false) */
  dissolved: boolean;
  /** 解消したペアの id(解消していなければ null) */
  pairId: string | null;
  /** 解消したときの相手(サイレント更新の送り先。push_token と push_env を持つ)。解消していなければ null */
  partner: SnapshotUserRow | null;
}

/**
 * userId が属する現役のペアを解消する。現役のペアが無ければ何もしない。
 * 書き込みは UPDATE 1 本(条件つき)なので、同時に両者が解消を送っても、解消を記録するのは 1 回だけ
 */
export async function dissolveActivePair(
  repo: PairDissolveRepo,
  params: { userId: string; now: Date },
): Promise<DissolveOutcome> {
  const pair = await repo.getActivePair(params.userId);
  if (!pair) return { dissolved: false, pairId: null, partner: null };

  const dissolved = await repo.dissolvePair(
    pair.pairId,
    params.now.toISOString(),
  );
  if (!dissolved) return { dissolved: false, pairId: null, partner: null };

  return { dissolved: true, pairId: pair.pairId, partner: pair.partner };
}
