// streak_test.ts — streak.ts の deno test(外部モジュール非依存・ネットワーク不要)
// 正本: docs/DESIGN.md §5.4 の例3件+エッジケース

import {
  type CloseDayDecision,
  decideCloseDay,
  deriveStreak,
  previewStreak,
  type StreakDayRecord,
} from "./streak.ts";

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

// ---- シナリオヘルパ: 日々の checkin 状況に close-day を順に適用する ----

type DayCheckins = Record<string, [a: boolean, b: boolean]>;

function runCloseDays(
  checkins: DayCheckins,
  opts: { startedOn: string; initialBalance: number },
): { days: StreakDayRecord[]; balance: number; resets: string[] } {
  const days: StreakDayRecord[] = [];
  const resets: string[] = [];
  let balance = opts.initialBalance;
  for (const date of Object.keys(checkins).sort()) {
    const [a, b] = checkins[date];
    const decision: CloseDayDecision = decideCloseDay({
      dateLocal: date,
      pairStatus: "active",
      startedOn: opts.startedOn,
      memberACheckedIn: a,
      memberBCheckedIn: b,
      ticketBalance: balance,
    });
    if (decision.action === "record") {
      days.push({ dateLocal: date, kind: decision.kind });
      balance = decision.ticketBalance;
    } else if (decision.action === "reset") {
      resets.push(date);
      balance = decision.ticketBalance;
    }
  }
  return { days, balance, resets };
}

// ---- DESIGN §5.4 の例3件 ----

Deno.test("§5.4 例1: 6/1〜6/3達成 + 6/4片方未達(チケット1枚) + 6/5達成 → current=5", () => {
  const { days, balance, resets } = runCloseDays({
    "2026-06-01": [true, true],
    "2026-06-02": [true, true],
    "2026-06-03": [true, true],
    "2026-06-04": [true, false],
    "2026-06-05": [true, true],
  }, { startedOn: "2026-06-01", initialBalance: 1 });

  assertEquals(
    days.find((d) => d.dateLocal === "2026-06-04")?.kind,
    "ticket",
    "(6/4 は kind=ticket)",
  );
  assertEquals(deriveStreak(days, "2026-06-05").current, 5);
  assertEquals(balance, 0, "(チケットは1枚消費)");
  assertEquals(resets, []);
});

Deno.test("§5.4 例2: 同上で 6/4 チケットなし → 6/5 時点 current=1(best=3 は残る)", () => {
  const { days, resets } = runCloseDays({
    "2026-06-01": [true, true],
    "2026-06-02": [true, true],
    "2026-06-03": [true, true],
    "2026-06-04": [true, false],
    "2026-06-05": [true, true],
  }, { startedOn: "2026-06-01", initialBalance: 0 });

  assertEquals(resets, ["2026-06-04"], "(6/4 はリセット)");
  const s = deriveStreak(days, "2026-06-05");
  assertEquals(s.current, 1);
  assertEquals(s.best, 3, "(最高記録はふたりの財産として残る)");
});

Deno.test("§5.4 例3: started_on=6/10 → 6/9以前は判定対象外(ソロ期間はストリークに影響しない)", () => {
  // ソロ期間(6/8〜6/9)に本人がチェックインしていても streak_days は作られない
  for (const date of ["2026-06-08", "2026-06-09"]) {
    const d = decideCloseDay({
      dateLocal: date,
      pairStatus: "active",
      startedOn: "2026-06-10",
      memberACheckedIn: true,
      memberBCheckedIn: true,
      ticketBalance: 2,
    });
    assertEquals(
      d,
      { action: "skip", reason: "before_started_on" },
      `(${date})`,
    );
  }
  // ペア成立日からは通常どおり積み上がる
  const { days } = runCloseDays({
    "2026-06-10": [true, true],
    "2026-06-11": [true, true],
  }, { startedOn: "2026-06-10", initialBalance: 2 });
  assertEquals(deriveStreak(days, "2026-06-11"), { current: 2, best: 2 });
});

// ---- エッジケース ----

Deno.test("エッジ: close-day 再実行の冪等性 — 既に確定済みの日は skip しチケットを二重消費しない", () => {
  const input = {
    dateLocal: "2026-06-04",
    pairStatus: "active" as const,
    startedOn: "2026-06-01",
    memberACheckedIn: true,
    memberBCheckedIn: false,
    ticketBalance: 2,
  };
  // 1回目: チケット消費で確定
  const first = decideCloseDay(input);
  assertEquals(first, {
    action: "record",
    kind: "ticket",
    ticketBalance: 1,
    consumedNow: true,
  });
  // 2回目(再実行): streak_days 行が既にあるので skip(残数はそのまま)
  const second = decideCloseDay({
    ...input,
    ticketBalance: 1,
    existingKind: "ticket",
  });
  assertEquals(second, { action: "skip", reason: "already_finalized" });
  // kind=both で確定済みの場合も同様
  const third = decideCloseDay({ ...input, existingKind: "both" });
  assertEquals(third, { action: "skip", reason: "already_finalized" });
});

Deno.test("エッジ: 2人とも未達の日もチケットは1日1枚で守る(人数では数えない)", () => {
  const d = decideCloseDay({
    dateLocal: "2026-06-04",
    pairStatus: "active",
    startedOn: "2026-06-01",
    memberACheckedIn: false,
    memberBCheckedIn: false,
    ticketBalance: 2,
  });
  assertEquals(d, {
    action: "record",
    kind: "ticket",
    ticketBalance: 1, // 2枚あっても消費は1枚だけ
    consumedNow: true,
  });
});

Deno.test("エッジ: お休み宣言済みの日は残数0でも守られ、追加消費しない(宣言時に予約済み)", () => {
  const d = decideCloseDay({
    dateLocal: "2026-06-04",
    pairStatus: "active",
    startedOn: "2026-06-01",
    memberACheckedIn: false,
    memberBCheckedIn: true,
    ticketBalance: 0,
    restDeclared: true,
  });
  assertEquals(d, {
    action: "record",
    kind: "ticket",
    ticketBalance: 0,
    consumedNow: false,
  });
});

Deno.test("エッジ: お休み宣言があっても両者達成なら kind=both で確定する", () => {
  const d = decideCloseDay({
    dateLocal: "2026-06-04",
    pairStatus: "active",
    startedOn: "2026-06-01",
    memberACheckedIn: true,
    memberBCheckedIn: true,
    ticketBalance: 1,
    restDeclared: true,
  });
  assertEquals(d, { action: "record", kind: "both", ticketBalance: 1 });
});

Deno.test("エッジ: 解消済み(dissolved)ペアは判定対象外", () => {
  const d = decideCloseDay({
    dateLocal: "2026-06-04",
    pairStatus: "dissolved",
    startedOn: "2026-06-01",
    memberACheckedIn: true,
    memberBCheckedIn: true,
    ticketBalance: 1,
  });
  assertEquals(d, { action: "skip", reason: "pair_not_active" });
});

Deno.test("deriveStreak: 空履歴は current=0 / best=0", () => {
  assertEquals(deriveStreak([], "2026-06-05"), { current: 0, best: 0 });
});

Deno.test("deriveStreak: asOf 当日に行がなければ current=0(best は履歴から計算)", () => {
  const days: StreakDayRecord[] = [
    { dateLocal: "2026-06-01", kind: "both" },
    { dateLocal: "2026-06-02", kind: "ticket" },
    { dateLocal: "2026-06-03", kind: "both" },
  ];
  assertEquals(deriveStreak(days, "2026-06-05"), { current: 0, best: 3 });
});

Deno.test("deriveStreak: kind=ticket の日も both と同様に継続日として数える", () => {
  const days: StreakDayRecord[] = [
    { dateLocal: "2026-06-01", kind: "ticket" },
    { dateLocal: "2026-06-02", kind: "ticket" },
    { dateLocal: "2026-06-03", kind: "both" },
  ];
  assertEquals(deriveStreak(days, "2026-06-03"), { current: 3, best: 3 });
});

Deno.test("deriveStreak: 月跨ぎ(6/30→7/1)も連続として数える", () => {
  const days: StreakDayRecord[] = [
    { dateLocal: "2026-06-29", kind: "both" },
    { dateLocal: "2026-06-30", kind: "both" },
    { dateLocal: "2026-07-01", kind: "both" },
  ];
  assertEquals(deriveStreak(days, "2026-07-01"), { current: 3, best: 3 });
});

Deno.test("deriveStreak: 重複行(upsert 再実行相当)は1日として数える", () => {
  const days: StreakDayRecord[] = [
    { dateLocal: "2026-06-01", kind: "both" },
    { dateLocal: "2026-06-01", kind: "both" },
    { dateLocal: "2026-06-02", kind: "both" },
  ];
  assertEquals(deriveStreak(days, "2026-06-02"), { current: 2, best: 2 });
});

Deno.test("previewStreak: 今日両者完了なら +1、未完なら確定値のまま", () => {
  assertEquals(previewStreak(5, true), 6);
  assertEquals(previewStreak(5, false), 5);
  assertEquals(previewStreak(0, true), 1);
  assertEquals(previewStreak(0, false), 0);
});

Deno.test("入力検証: 不正な date_local / 残数は throw する", () => {
  assertThrows(() => deriveStreak([], "2026/06/05"), "(区切り文字違い)");
  assertThrows(() => deriveStreak([], "2026-02-30"), "(実在しない日付)");
  assertThrows(
    () =>
      decideCloseDay({
        dateLocal: "2026-06-04",
        pairStatus: "active",
        startedOn: "2026-06-01",
        memberACheckedIn: true,
        memberBCheckedIn: true,
        ticketBalance: -1,
      }),
    "(負の残数)",
  );
  assertThrows(() => previewStreak(-1, true), "(負の current)");
});
