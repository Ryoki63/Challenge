// _shared/pair_rows.ts — 現役のペア(pairs の行)の読み出しを各 Function で揃える
//
// 正本: docs/DESIGN.md §3.4(snapshot の ticketBalance)/ §5.3 / issue #19
//
// snapshot を組み立てる Function は、自分の現役のペアを getActivePair で読む。そのとき
// **pairs.ticket_balance を必ず一緒に読む**(snapshot の ticketBalance。読み忘れると、ホームのバッジが
// 黙って出なくなる)。select の列と行の変換をここに集めて、各 index.ts の読み忘れを起こさない
// (user_rows.ts の USER_COLUMNS / PARTNER_SELECT / toSnapshotUser と同じ考え方)。
// ひとつの問い合わせ(pair_members → pairs の結合)で済ませ、往復は増やさない。
//
// supabase-js はここでは import しない(テストをネットワーク不要に保つ — DESIGN §8)。

import type { SnapshotPairRow, SnapshotUserRow } from "./snapshot.ts";

/** pair_members から、自分の現役のペアを引く select(`pairs` の列は PairDbRow。`eq("pairs.status", "active")` と組で使う) */
export const ACTIVE_PAIR_SELECT =
  "pair_id, pairs!inner(id, status, started_on, ticket_balance)";

/** ACTIVE_PAIR_SELECT で読んだ pairs 行(DB の列名のまま) */
export interface PairDbRow {
  id: string;
  started_on: string;
  ticket_balance: number | null;
}

/**
 * DB の行 → SnapshotPairRow。ticket_balance は 0 以上の整数だけ ticketBalance にする
 * (null・不正な値は載せない = snapshot では null。本番では NOT NULL・CHECK(>= 0) なので来ない)
 */
export function toSnapshotPair(
  pair: PairDbRow,
  partner: SnapshotUserRow,
): SnapshotPairRow {
  const balance = pair.ticket_balance;
  const row: SnapshotPairRow = {
    pairId: pair.id,
    startedOn: pair.started_on,
    partner,
  };
  if (
    typeof balance === "number" && Number.isInteger(balance) && balance >= 0
  ) {
    row.ticketBalance = balance;
  }
  return row;
}
