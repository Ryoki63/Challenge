// tickets_test.ts — tickets.ts の deno test(外部モジュール非依存・ネットワーク不要)
// 正本: docs/DESIGN.md §5.3(grant-tickets)/ docs/REQUIREMENTS.md §3.6

import { consumeTicket, declareRest, grantMonthlyTickets } from "./tickets.ts";

// ---- 自作 assert ヘルパ(外部モジュールを使わない) ----

function deepEqual(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (
    typeof a !== "object" || typeof b !== "object" || a === null || b === null
  ) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ra = a as Record<string, unknown>;
  const rb = b as Record<string, unknown>;
  const ka = Object.keys(ra).sort();
  const kb = Object.keys(rb).sort();
  if (ka.length !== kb.length || ka.some((k, i) => k !== kb[i])) return false;
  return ka.every((k) => deepEqual(ra[k], rb[k]));
}

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  if (!deepEqual(actual, expected)) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${
        JSON.stringify(actual)
      }\n  expected: ${JSON.stringify(expected)}`,
    );
  }
}

function assertThrows(fn: () => unknown, msg = ""): void {
  let threw = false;
  try {
    fn();
  } catch {
    threw = true;
  }
  if (!threw) {
    throw new Error(`assertThrows failed: 例外が発生しなかった ${msg}`);
  }
}

// ---- 月次付与(grant-tickets: free min(2, b+2) / premium min(10, b+5)) ----

Deno.test("月次付与 free: 0枚 → 2枚(満額付与)", () => {
  assertEquals(grantMonthlyTickets(0, "free"), { newBalance: 2, granted: 2 });
});

Deno.test("月次付与 free: 月跨ぎで1枚残っていても上限2(付与は1枚だけ)", () => {
  assertEquals(grantMonthlyTickets(1, "free"), { newBalance: 2, granted: 1 });
});

Deno.test("月次付与 free: 2枚残(上限)なら付与0(繰越なし・上限2)", () => {
  assertEquals(grantMonthlyTickets(2, "free"), { newBalance: 2, granted: 0 });
});

Deno.test("月次付与 premium: 0枚 → 5枚", () => {
  assertEquals(grantMonthlyTickets(0, "premium"), {
    newBalance: 5,
    granted: 5,
  });
});

Deno.test("月次付与 premium: 繰越7枚 + 5枚 → 上限10で頭打ち(付与は3枚)", () => {
  assertEquals(grantMonthlyTickets(7, "premium"), {
    newBalance: 10,
    granted: 3,
  });
});

Deno.test("月次付与 premium: 上限10のときは付与0", () => {
  assertEquals(grantMonthlyTickets(10, "premium"), {
    newBalance: 10,
    granted: 0,
  });
});

Deno.test("月次付与: 何ヶ月連続で付与しても上限を超えない(冪等な上限)", () => {
  let balance = 0;
  for (let month = 0; month < 6; month++) {
    balance = grantMonthlyTickets(balance, "premium").newBalance;
  }
  assertEquals(balance, 10);
  let freeBalance = 0;
  for (let month = 0; month < 6; month++) {
    freeBalance = grantMonthlyTickets(freeBalance, "free").newBalance;
  }
  assertEquals(freeBalance, 2);
});

// ---- 消費 ----

Deno.test("消費: 残数2 → 1枚消費して残1", () => {
  assertEquals(consumeTicket(2), { consumed: true, newBalance: 1 });
});

Deno.test("消費: 残数0 は消費できない(残数そのまま・負にならない)", () => {
  assertEquals(consumeTicket(0), { consumed: false, newBalance: 0 });
});

Deno.test("消費: 残数ぶんだけ消費でき、それ以上は失敗する", () => {
  let balance = 2;
  for (let i = 0; i < 2; i++) {
    const r = consumeTicket(balance);
    assertEquals(r.consumed, true, `(${i + 1}回目)`);
    balance = r.newBalance;
  }
  assertEquals(consumeTicket(balance), { consumed: false, newBalance: 0 });
});

// ---- お休み宣言(declare) ----

Deno.test("宣言: 明日を指定 → 残数-1 で予約し ledger(declare) を返す", () => {
  assertEquals(
    declareRest({
      balance: 2,
      todayLocal: "2026-06-10",
      targetDateLocal: "2026-06-11",
    }),
    {
      ok: true,
      newBalance: 1,
      ledger: { delta: -1, reason: "declare", dateLocal: "2026-06-11" },
    },
  );
});

Deno.test("宣言: 残数0では宣言できない(no_ticket)", () => {
  assertEquals(
    declareRest({
      balance: 0,
      todayLocal: "2026-06-10",
      targetDateLocal: "2026-06-11",
    }),
    { ok: false, reason: "no_ticket" },
  );
});

Deno.test("宣言: 同じ日への二重宣言はできない(already_declared)", () => {
  assertEquals(
    declareRest({
      balance: 2,
      todayLocal: "2026-06-10",
      targetDateLocal: "2026-06-11",
      declaredDates: ["2026-06-11"],
    }),
    { ok: false, reason: "already_declared" },
  );
});

Deno.test("宣言: 今日・過去の日付は宣言できない(date_not_in_future。当日救済は自動消費の役割)", () => {
  for (const target of ["2026-06-10", "2026-06-09"]) {
    assertEquals(
      declareRest({
        balance: 2,
        todayLocal: "2026-06-10",
        targetDateLocal: target,
      }),
      { ok: false, reason: "date_not_in_future" },
      `(target=${target})`,
    );
  }
});

Deno.test("宣言: 月跨ぎの翌日(6/30→7/1)も宣言できる", () => {
  const r = declareRest({
    balance: 1,
    todayLocal: "2026-06-30",
    targetDateLocal: "2026-07-01",
  });
  assertEquals(r, {
    ok: true,
    newBalance: 0,
    ledger: { delta: -1, reason: "declare", dateLocal: "2026-07-01" },
  });
});

// ---- 入力検証 ----

Deno.test("入力検証: 負・非整数の残数、不正な date_local は throw する", () => {
  assertThrows(() => grantMonthlyTickets(-1, "free"), "(負の残数)");
  assertThrows(() => grantMonthlyTickets(1.5, "premium"), "(非整数)");
  assertThrows(() => consumeTicket(-1), "(負の残数)");
  assertThrows(
    () =>
      declareRest({
        balance: 1,
        todayLocal: "2026-6-10",
        targetDateLocal: "2026-06-11",
      }),
    "(ゼロ埋めなしの日付)",
  );
});
