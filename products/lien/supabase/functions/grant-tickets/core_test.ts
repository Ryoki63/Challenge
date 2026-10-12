// core_test.ts — grant-tickets/core.ts の deno test(リポジトリはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.3(free: min(2, b+2) / premium: min(10, b+5))
//        / docs/REQUIREMENTS.md §3.6(繰越なし上限2 / 繰越あり上限10)/ §5(premium_until から導出)

import {
  type ApplyGrantOutcome,
  derivePairPlan,
  type GrantTicketsPairRow,
  type GrantTicketsRepo,
  handleGrantTickets,
  monthStartOf,
  nextMonthStartOf,
  parseGrantTicketsRequest,
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
  /** 実行記録(ticket_grant_runs)。key: `${pairId}|${monthStart}` → 記録した delta */
  runs: Map<string, number>;
  /** applyMonthlyGrant に渡された生の引数 */
  applied: Array<{
    pairId: string;
    monthStart: string;
    dateLocal: string;
    delta: number;
  }>;
  /** このユーザーIDの getPremiumUntil を throw させる(エラー隔離テスト用) */
  failUserIds: Set<string>;
  /** このペアIDの applyMonthlyGrant を throw させる(エラー隔離・再実行テスト用) */
  failApplyPairIds: Set<string>;
  /** true なら hasMonthlyGrantInMonth を常に false にする(競合: 事前チェックをすり抜けた実行) */
  skipPrecheck: boolean;
}

function makeWorld(overrides: Partial<World> = {}): World {
  return {
    pairs: [],
    premiumUntil: {},
    ledger: [],
    runs: new Map(),
    applied: [],
    failUserIds: new Set(),
    failApplyPairIds: new Set(),
    skipPrecheck: false,
    ...overrides,
  };
}

/**
 * 本番の RPC apply_monthly_ticket_grant(migration 0006)と同じ意味のフェイク:
 * 実行記録が無ければ記録 → delta が 0 なら 'unchanged'、そうでなければ残高に足して ledger に書く
 */
function makeRepo(world: World): GrantTicketsRepo {
  return {
    listActivePairs: () => Promise.resolve([...world.pairs]),
    getPremiumUntil: (userId) => {
      if (world.failUserIds.has(userId)) {
        return Promise.reject(new Error("db down"));
      }
      return Promise.resolve(world.premiumUntil[userId] ?? null);
    },
    hasMonthlyGrantInMonth: (pairId, monthStart, nextMonthStart) => {
      if (world.skipPrecheck) return Promise.resolve(false);
      const recorded = world.runs.has(`${pairId}|${monthStart}`);
      const legacyLedger = world.ledger.some(
        (l) =>
          l.pairId === pairId &&
          l.reason === "monthly" &&
          l.dateLocal >= monthStart &&
          l.dateLocal < nextMonthStart,
      );
      return Promise.resolve(recorded || legacyLedger);
    },
    applyMonthlyGrant: (params): Promise<ApplyGrantOutcome> => {
      world.applied.push({ ...params });
      if (world.failApplyPairIds.has(params.pairId)) {
        return Promise.reject(new Error("rpc down"));
      }
      const key = `${params.pairId}|${params.monthStart}`;
      if (world.runs.has(key)) return Promise.resolve("already");
      world.runs.set(key, params.delta);
      if (params.delta === 0) return Promise.resolve("unchanged");
      world.pairs.find((p) => p.pairId === params.pairId)!.ticketBalance +=
        params.delta;
      world.ledger.push({
        pairId: params.pairId,
        delta: params.delta,
        reason: "monthly",
        dateLocal: params.dateLocal,
      });
      return Promise.resolve("granted");
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
  assertEquals(
    world.runs.get("pair-1|2026-07-01"),
    0,
    "ledger は書けないが、実行記録(ペア×月)は delta=0 で残す",
  );
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

Deno.test("grant-tickets: 再実行は冪等 — 同月の実行記録があればスキップ", async () => {
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

Deno.test("grant-tickets: 上限到達で 0 付与だったペアも、月の途中の再実行で再付与しない(issue #60 の二重付与)", async () => {
  // 月初: free の上限(残数 2)。付与額 0 → ledger は書けないが、実行記録は残る
  const world = makeWorld({ pairs: [pair("pair-cap", 2)] });
  const d = deps(world);

  const first = await handleGrantTickets(d, {});
  assertEquals(first.status, 200);
  if (first.status !== 200) throw new Error("unreachable");
  assertEquals(first.body.unchanged, 1);
  assertEquals(world.ledger.length, 0);

  // 月の途中で close-day がチケットを1枚使った(残数 2 → 1)。ここで再実行しても付与しない
  world.pairs[0].ticketBalance = 1;
  const rerun = await handleGrantTickets(d, {});
  assertEquals(rerun.status, 200);
  if (rerun.status !== 200) throw new Error("unreachable");
  assertEquals(rerun.body.granted, 0);
  assertEquals(rerun.body.alreadyGranted, 1, "処理済みとして数える");
  assertEquals(rerun.body.unchanged, 0);
  assertEquals(world.pairs[0].ticketBalance, 1, "使った1枚を取り戻さない");
  assertEquals(world.ledger.length, 0);
  assertEquals(world.applied.length, 1, "再実行では RPC を呼ばない");
});

Deno.test("grant-tickets: 旧来の印(同月の ledger monthly 行。実行記録を入れる前の付与)も処理済みと見る", async () => {
  const world = makeWorld({ pairs: [pair("pair-1", 1)] });
  world.ledger.push({
    pairId: "pair-1",
    delta: 1,
    reason: "monthly",
    dateLocal: "2026-07-01",
  });

  const result = await handleGrantTickets(deps(world), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyGranted, 1);
  assertEquals(world.applied.length, 0);
  assertEquals(world.pairs[0].ticketBalance, 1);
});

Deno.test("grant-tickets: 事前チェックをすり抜けた並行実行も RPC が 'already' で止める(二重に増えない)", async () => {
  const world = makeWorld({ pairs: [pair("pair-1", 0)] });
  const d = deps(world);

  const first = await handleGrantTickets(d, {});
  assertEquals(first.status, 200);
  assertEquals(world.pairs[0].ticketBalance, 2);

  // 2つ目の実行が、1つ目の書き込み前に事前チェックを通り抜けた状況
  world.skipPrecheck = true;
  world.pairs[0].ticketBalance = 1;
  const second = await handleGrantTickets(d, {});
  assertEquals(second.status, 200);
  if (second.status !== 200) throw new Error("unreachable");
  assertEquals(second.body.granted, 0);
  assertEquals(second.body.alreadyGranted, 1);
  assertEquals(world.pairs[0].ticketBalance, 1, "二重付与しない");
  assertEquals(world.ledger.length, 1);
});

Deno.test("grant-tickets: RPC には月初・ledger の日付・delta を渡す", async () => {
  const world = makeWorld({
    pairs: [pair("pair-0", 0), pair("pair-cap", 2)],
  });

  await handleGrantTickets(deps(world), { dateLocal: "2026-07-01" });

  assertEquals(world.applied, [
    {
      pairId: "pair-0",
      monthStart: "2026-07-01",
      dateLocal: "2026-07-01",
      delta: 2,
    },
    {
      pairId: "pair-cap",
      monthStart: "2026-07-01",
      dateLocal: "2026-07-01",
      delta: 0,
    },
  ]);
});

Deno.test("grant-tickets: 前月の実行記録・ledger は冪等キーにならない(翌月は付与される)", async () => {
  const world = makeWorld({ pairs: [pair("pair-1", 0)] });
  world.runs.set("pair-1|2026-06-01", 2); // 前月分
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

Deno.test("grant-tickets: dateLocal 指定で過去の月の付与(取りこぼしの埋め直し)・不正な日付は 400", async () => {
  const world = makeWorld({ pairs: [pair("pair-1", 0)] });

  // NOW は JST 2026-07-01 00:05。前月(6月)の付与を取りこぼした想定
  const result = await handleGrantTickets(deps(world), {
    dateLocal: "2026-06-01",
  });
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.dateLocal, "2026-06-01");
  assertEquals(world.ledger[0].dateLocal, "2026-06-01");

  const bad = await handleGrantTickets(deps(world), {
    dateLocal: "2026-13-01",
  });
  assertEquals(bad.status, 400);
});

Deno.test("grant-tickets: RPC が失敗したペアは記録が残らず、次の実行で付与される(他ペアは処理される)", async () => {
  const world = makeWorld({
    pairs: [pair("pair-ng", 0), pair("pair-ok", 0, ["user-c", "user-d"])],
    failApplyPairIds: new Set(["pair-ng"]),
  });
  const d = deps(world);

  const first = await handleGrantTickets(d, {});
  assertEquals(first.status, 200);
  if (first.status !== 200) throw new Error("unreachable");
  assertEquals(first.body.granted, 1);
  assertEquals(first.body.errors.length, 1);
  assertEquals(first.body.errors[0].pairId, "pair-ng");
  assertEquals(
    world.runs.has("pair-ng|2026-07-01"),
    false,
    "失敗したペアに印は残らない",
  );

  // 障害が直った後の再実行: 付与済みの pair-ok はスキップ、pair-ng は付与される
  world.failApplyPairIds.clear();
  const second = await handleGrantTickets(d, {});
  assertEquals(second.status, 200);
  if (second.status !== 200) throw new Error("unreachable");
  assertEquals(second.body.granted, 1);
  assertEquals(second.body.alreadyGranted, 1);
  assertEquals(world.pairs[0].ticketBalance, 2);
  assertEquals(world.pairs[1].ticketBalance, 2, "pair-ok は二重に増えない");
});

Deno.test("grant-tickets: 未来の月は 400 future_month(実行記録が残って本当の cron を空振りさせないため)", async () => {
  const world = makeWorld({ pairs: [pair("pair-1", 0)] });

  // NOW は JST 2026-07-01 00:05
  for (const dateLocal of ["2026-08-01", "2026-08-15", "2027-01-01"]) {
    const result = await handleGrantTickets(deps(world), { dateLocal });
    assertEquals(result.status, 400, dateLocal);
    assertEquals(
      result.status === 400 ? result.body : null,
      { error: "future_month" },
      dateLocal,
    );
  }
  assertEquals(world.applied.length, 0);
  assertEquals(world.runs.size, 0);

  // 当月(1日以外の日付でも月は当月)と過去の月は付与できる
  const sameMonth = await handleGrantTickets(deps(world), {
    dateLocal: "2026-07-20",
  });
  assertEquals(sameMonth.status, 200);
  const past = await handleGrantTickets(deps(world), {
    dateLocal: "2026-06-01",
  });
  assertEquals(past.status, 200);
  assertEquals([...world.runs.keys()].sort(), [
    "pair-1|2026-06-01",
    "pair-1|2026-07-01",
  ]);
});

Deno.test("parseGrantTicketsRequest: 許すキーは dateLocal だけ・型違いは 400", () => {
  assertEquals(parseGrantTicketsRequest({}), { ok: true, value: {} });
  assertEquals(parseGrantTicketsRequest({ dateLocal: "2026-07-01" }), {
    ok: true,
    value: { dateLocal: "2026-07-01" },
  });
  assertEquals(parseGrantTicketsRequest({ dateLocal: 20260701 }), {
    ok: false,
    error: "invalid_date_local",
  });
  assertEquals(parseGrantTicketsRequest({ datelocal: "2026-07-01" }), {
    ok: false,
    error: "unknown_field",
  });
  assertEquals(parseGrantTicketsRequest({ notify: false }), {
    ok: false,
    error: "unknown_field",
  });
});
