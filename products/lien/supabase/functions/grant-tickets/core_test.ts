// core_test.ts — grant-tickets/core.ts の deno test(リポジトリはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.3(free: min(2, b+2) / premium: min(10, b+5))
//        / docs/REQUIREMENTS.md §3.6(繰越なし上限2 / 繰越あり上限10)/ §5(premium_until から導出)

import {
  derivePairPlan,
  type GrantTicketsPairRow,
  type GrantTicketsRepo,
  handleGrantTickets,
  monthStartOf,
  nextMonthStartOf,
} from "./core.ts";

// ---- 自作 assert ヘルパ(外部モジュールを使わない) ----

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

// ---- 純粋ヘルパ ----

const NOW = new Date("2026-06-30T15:05:00Z"); // JST 2026-07-01 00:05(毎月1日 cron)

Deno.test("derivePairPlan: メンバーの premium_until から導出(REQUIREMENTS §5)", () => {
  // どちらかが未来なら premium
  assertEquals(derivePairPlan(["2026-08-01T00:00:00Z", null], NOW), "premium");
  assertEquals(derivePairPlan([null, "2027-01-01T00:00:00Z"], NOW), "premium");
  // 両方 null / 期限切れ / ちょうど now は free
  assertEquals(derivePairPlan([null, null], NOW), "free");
  assertEquals(derivePairPlan(["2026-06-01T00:00:00Z", null], NOW), "free");
  assertEquals(derivePairPlan([NOW.toISOString(), null], NOW), "free");
  // 不正な日時文字列は free 扱い(防御的)
  assertEquals(derivePairPlan(["not-a-date", null], NOW), "free");
});

Deno.test("monthStartOf / nextMonthStartOf: 月初と翌月初(12月の年跨ぎ含む)", () => {
  assertEquals(monthStartOf("2026-07-15"), "2026-07-01");
  assertEquals(monthStartOf("2026-07-01"), "2026-07-01");
  assertEquals(nextMonthStartOf("2026-07-01"), "2026-08-01");
  assertEquals(nextMonthStartOf("2026-12-31"), "2027-01-01");
  assertEquals(nextMonthStartOf("2026-01-05"), "2026-02-01");
});

// ---- fake repo ----

interface World {
  pairs: GrantTicketsPairRow[];
  premiumUntil: Record<string, string | null>;
  ledger: Array<{
    pairId: string;
    delta: number;
    reason: string;
    dateLocal: string;
  }>;
  /** このペアIDの getPremiumUntil を throw させる(エラー隔離テスト用) */
  failUserIds: Set<string>;
}

function makeWorld(overrides: Partial<World> = {}): World {
  return {
    pairs: [],
    premiumUntil: {},
    ledger: [],
    failUserIds: new Set(),
    ...overrides,
  };
}

function makeRepo(world: World): GrantTicketsRepo {
  return {
    listActivePairs: () => Promise.resolve([...world.pairs]),
    getPremiumUntil: (userId) => {
      if (world.failUserIds.has(userId)) {
        return Promise.reject(new Error("db down"));
      }
      return Promise.resolve(world.premiumUntil[userId] ?? null);
    },
    hasMonthlyGrantInMonth: (pairId, monthStart, nextMonthStart) =>
      Promise.resolve(
        world.ledger.some(
          (l) =>
            l.pairId === pairId &&
            l.reason === "monthly" &&
            l.dateLocal >= monthStart &&
            l.dateLocal < nextMonthStart,
        ),
      ),
    updateTicketBalance: (pairId, balance) => {
      world.pairs.find((p) => p.pairId === pairId)!.ticketBalance = balance;
      return Promise.resolve();
    },
    insertTicketLedger: (params) => {
      world.ledger.push({ ...params });
      return Promise.resolve();
    },
  };
}

function pair(
  pairId: string,
  ticketBalance: number,
  memberIds: [string, string] = ["user-a", "user-b"],
): GrantTicketsPairRow {
  return { pairId, ticketBalance, memberIds };
}

function deps(world: World) {
  return { repo: makeRepo(world), now: () => NOW };
}

// ---- 本体テスト ----

Deno.test("grant-tickets: free は min(2, balance+2)・ledger に monthly 記録(DESIGN §5.3)", async () => {
  const world = makeWorld({
    pairs: [pair("pair-0", 0), pair("pair-1", 1, ["user-c", "user-d"])],
  });

  const result = await handleGrantTickets(deps(world), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.dateLocal, "2026-07-01", "JST の実行日が付与日");
  assertEquals(result.body.granted, 2);
  assertEquals(world.pairs[0].ticketBalance, 2, "0 → 2");
  assertEquals(world.pairs[1].ticketBalance, 2, "1 → 2(繰越なし・上限2)");
  assertEquals(world.ledger, [
    { pairId: "pair-0", delta: 2, reason: "monthly", dateLocal: "2026-07-01" },
    { pairId: "pair-1", delta: 1, reason: "monthly", dateLocal: "2026-07-01" },
  ]);
});

Deno.test("grant-tickets: free 上限到達(balance=2)は付与なし・ledger 記録なし", async () => {
  const world = makeWorld({ pairs: [pair("pair-1", 2)] });

  const result = await handleGrantTickets(deps(world), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.granted, 0);
  assertEquals(result.body.unchanged, 1);
  assertEquals(world.pairs[0].ticketBalance, 2);
  assertEquals(world.ledger.length, 0, "delta=0 は記録しない(DB制約 delta<>0)");
});

Deno.test("grant-tickets: premium は min(10, balance+5)・繰越あり(REQUIREMENTS §3.6)", async () => {
  const world = makeWorld({
    pairs: [
      pair("pair-3", 3, ["user-a", "user-b"]),
      pair("pair-7", 7, ["user-c", "user-d"]),
      pair("pair-10", 10, ["user-e", "user-f"]),
    ],
    premiumUntil: {
      "user-a": "2026-08-01T00:00:00Z", // 片方 premium で十分
      "user-c": "2026-08-01T00:00:00Z",
      "user-e": "2026-08-01T00:00:00Z",
    },
  });

  const result = await handleGrantTickets(deps(world), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(world.pairs[0].ticketBalance, 8, "3 → 8(繰越あり)");
  assertEquals(world.pairs[1].ticketBalance, 10, "7 → 10(上限で切り詰め +3)");
  assertEquals(world.pairs[2].ticketBalance, 10, "上限到達は変化なし");
  assertEquals(result.body.granted, 2);
  assertEquals(result.body.unchanged, 1);
  assertEquals(world.ledger, [
    { pairId: "pair-3", delta: 5, reason: "monthly", dateLocal: "2026-07-01" },
    { pairId: "pair-7", delta: 3, reason: "monthly", dateLocal: "2026-07-01" },
  ]);
});

Deno.test("grant-tickets: premium 失効ペアは free 扱い — 残高は上限2へ切り詰め(繰越なし)", async () => {
  const world = makeWorld({
    pairs: [pair("pair-1", 8)],
    premiumUntil: { "user-a": "2026-06-01T00:00:00Z" }, // 失効済み
  });

  const result = await handleGrantTickets(deps(world), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(world.pairs[0].ticketBalance, 2, "min(2, 8+2) = 2");
  assertEquals(world.ledger, [
    { pairId: "pair-1", delta: -6, reason: "monthly", dateLocal: "2026-07-01" },
  ]);
});

Deno.test("grant-tickets: 再実行は冪等 — 同月の monthly ledger があればスキップ", async () => {
  const world = makeWorld({ pairs: [pair("pair-1", 0)] });
  const d = deps(world);

  const first = await handleGrantTickets(d, {});
  assertEquals(first.status, 200);
  if (first.status !== 200) throw new Error("unreachable");
  assertEquals(first.body.granted, 1);
  assertEquals(world.pairs[0].ticketBalance, 2);

  // 付与後に close-day がチケットを消費した状況(00:05 付与 → 00:10 消費 → 再実行)
  world.pairs[0].ticketBalance = 1;
  world.ledger.push({
    pairId: "pair-1",
    delta: -1,
    reason: "consume",
    dateLocal: "2026-06-30",
  });

  const second = await handleGrantTickets(d, {});
  assertEquals(second.status, 200);
  if (second.status !== 200) throw new Error("unreachable");
  assertEquals(second.body.granted, 0);
  assertEquals(second.body.alreadyGranted, 1);
  assertEquals(world.pairs[0].ticketBalance, 1, "二重付与しない");
  assertEquals(
    world.ledger.filter((l) => l.reason === "monthly").length,
    1,
    "monthly は月1回だけ",
  );
});

Deno.test("grant-tickets: 前月の monthly ledger は冪等キーにならない(翌月は付与される)", async () => {
  const world = makeWorld({ pairs: [pair("pair-1", 0)] });
  world.ledger.push({
    pairId: "pair-1",
    delta: 2,
    reason: "monthly",
    dateLocal: "2026-06-01", // 前月分
  });

  const result = await handleGrantTickets(deps(world), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.granted, 1);
  assertEquals(world.pairs[0].ticketBalance, 2);
});

Deno.test("grant-tickets: 1ペアの失敗は隔離 — 他ペアは処理されエラーは報告される", async () => {
  const world = makeWorld({
    pairs: [
      pair("pair-ng", 0, ["user-x", "user-y"]),
      pair("pair-ok", 0, ["user-a", "user-b"]),
    ],
    failUserIds: new Set(["user-x"]),
  });

  const result = await handleGrantTickets(deps(world), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.granted, 1);
  assertEquals(result.body.errors.length, 1);
  assertEquals(result.body.errors[0].pairId, "pair-ng");
  assertEquals(
    world.pairs.find((p) => p.pairId === "pair-ok")!.ticketBalance,
    2,
  );
});

Deno.test("grant-tickets: dateLocal 指定で任意月の付与・不正な日付は 400", async () => {
  const world = makeWorld({ pairs: [pair("pair-1", 0)] });

  const result = await handleGrantTickets(deps(world), {
    dateLocal: "2026-08-01",
  });
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.dateLocal, "2026-08-01");
  assertEquals(world.ledger[0].dateLocal, "2026-08-01");

  const bad = await handleGrantTickets(deps(world), {
    dateLocal: "2026-13-01",
  });
  assertEquals(bad.status, 400);
});
