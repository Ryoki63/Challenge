// pair_rows_test.ts — pair_rows.ts の deno test(外部モジュール非依存・ネットワーク不要)
// 正本: docs/DESIGN.md §3.4(ticketBalance)/ issue #19

import {
  ACTIVE_PAIR_SELECT,
  type PairDbRow,
  toSnapshotPair,
} from "./pair_rows.ts";
import type { SnapshotUserRow } from "./snapshot.ts";

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

const partner: SnapshotUserRow = {
  id: "user-b",
  nickname: "ゆうき",
  timezone: "Asia/Tokyo",
  pushToken: "token-b",
};

const pairRow = (ticketBalance: number | null): PairDbRow => ({
  id: "pair-1",
  started_on: "2026-06-01",
  ticket_balance: ticketBalance,
});

Deno.test("ACTIVE_PAIR_SELECT: 現役のペアの select に ticket_balance を含む(読み忘れ防止)", () => {
  assertEquals(
    ACTIVE_PAIR_SELECT,
    "pair_id, pairs!inner(id, status, started_on, ticket_balance)",
  );
});

Deno.test("toSnapshotPair: pairs 行 → SnapshotPairRow(ticket_balance は ticketBalance になる。0 枚も 0)", () => {
  assertEquals(toSnapshotPair(pairRow(2), partner), {
    pairId: "pair-1",
    startedOn: "2026-06-01",
    partner,
    ticketBalance: 2,
  });
  assertEquals(toSnapshotPair(pairRow(0), partner).ticketBalance, 0);
});

Deno.test("toSnapshotPair: null・不正な残数は載せない(snapshot では null = バッジを出さない。誤った 0 枚を見せない)", () => {
  for (const bad of [null, -1, 1.5, Number.NaN]) {
    const row = toSnapshotPair(pairRow(bad), partner);
    assertEquals("ticketBalance" in row, false, String(bad));
  }
  // 列を読み忘れた(undefined)場合も同じ
  const missing = toSnapshotPair(
    { id: "pair-1", started_on: "2026-06-01" } as unknown as PairDbRow,
    partner,
  );
  assertEquals("ticketBalance" in missing, false);
});
