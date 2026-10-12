// snapshot_test.ts — snapshot.ts の deno test(外部モジュール非依存・ネットワーク不要)
// 正本: docs/DESIGN.md §3.4(スキーマ)/ §5.4(プレビュー)/ docs/REQUIREMENTS.md §3.9(植物)
//       / docs/GROWTH.md §3(段階表・ラチェット)・§7.2(行から数え直す)・§7.3(昨日の仮判定)

import {
  addDaysLocal,
  buildPairSnapshot,
  buildSoloSnapshot,
  CLOSE_DAY_SETTLE_HOUR,
  countBothDays,
  countConsecutiveMissedDays,
  dateLocalInTimeZone,
  derivePlantMood,
  derivePlantProgress,
  derivePlantStage,
  isAtOrAfterLocalHour,
  loadSnapshotForUser,
  localDateAndHour,
  needsProvisionalYesterday,
  type PairSnapshot,
  PLANT_STAGE_THRESHOLDS,
  provisionalYesterdayRow,
  resolveTodayLocal,
  type SnapshotCheckinRow,
  type SnapshotPairRow,
  type SnapshotPlantRow,
  type SnapshotPromiseRow,
  type SnapshotRepo,
  type SnapshotUserRow,
} from "./snapshot.ts";
import type { StreakDayRecord } from "./streak.ts";

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

// ---- 植物: 成長段階(GROWTH §3.3: 10段階 1/3/7/14/21/30/45/66/100 回) ----

/** 段階表(GROWTH §3.3)。from = その段階に入る成長回数 */
const STAGE_TABLE: ReadonlyArray<
  { stage: number; name: string; from: number }
> = [
  { stage: 0, name: "たね", from: 0 },
  { stage: 1, name: "ふたば", from: 1 },
  { stage: 2, name: "めばえ", from: 3 },
  { stage: 3, name: "わかば", from: 7 },
  { stage: 4, name: "よりそい", from: 14 },
  { stage: 5, name: "つぼみ", from: 21 },
  { stage: 6, name: "いろづき", from: 30 },
  { stage: 7, name: "ほころび", from: 45 },
  { stage: 8, name: "ふたりざき", from: 66 },
  { stage: 9, name: "みのり", from: 100 },
];

Deno.test("derivePlantStage: 10段階のすべての境目(ちょうどの回数で上がり、1回前はまだ手前の段階)", () => {
  for (const { stage, name, from } of STAGE_TABLE) {
    assertEquals(derivePlantStage(from), stage, `${from}回 = ${name}`);
    if (from > 0) {
      assertEquals(
        derivePlantStage(from - 1),
        stage - 1,
        `${from - 1}回はまだ ${STAGE_TABLE[stage - 1].name}`,
      );
    }
  }
});

Deno.test("derivePlantStage: 段階の途中の回数(間の値)は手前の段階のまま", () => {
  assertEquals(derivePlantStage(2), 1, "2回=ふたば");
  assertEquals(derivePlantStage(4), 2, "4回=めばえ");
  assertEquals(derivePlantStage(10), 3, "10回=わかば");
  assertEquals(derivePlantStage(50), 7, "50回=ほころび");
  assertEquals(derivePlantStage(99), 8, "99回=ふたりざき");
});

Deno.test("derivePlantStage: みのり(100回)以降も後退せず、段階も増えない(花壇は v1.0.1 で別途)", () => {
  for (const grown of [100, 101, 125, 200, 365, 10_000]) {
    assertEquals(derivePlantStage(grown), 9, `${grown}回=みのり`);
  }
});

Deno.test("derivePlantStage: 不正値は throw", () => {
  assertThrows(() => derivePlantStage(-1));
  assertThrows(() => derivePlantStage(1.5));
  assertThrows(() => derivePlantStage(Number.NaN));
  assertThrows(() => derivePlantStage(Number.POSITIVE_INFINITY));
});

Deno.test("PLANT_STAGE_THRESHOLDS: 段階表(GROWTH §3.3)と一致する", () => {
  assertEquals([...PLANT_STAGE_THRESHOLDS], STAGE_TABLE.map((r) => r.from));
});

// ---- ラチェットテスト(GROWTH §3.6): 閾値は下げる方向にだけ、段階は末尾にだけ ----
//
// 閾値を上げると、到達済みのペアの植物が戻って見える。これを機械的に禁じる。
// FROZEN_THRESHOLDS は v1.0 で公開した値の**凍結基準**。この定数自体は書き換えない
// (閾値を下げたくなったら PLANT_STAGE_THRESHOLDS だけを下げる。基準は据え置く)。

const FROZEN_THRESHOLDS: readonly number[] = Object.freeze(
  [0, 1, 3, 7, 14, 21, 30, 45, 66, 100],
);

/** 凍結基準に対する違反の一覧(空 = 合格)。ラチェットの4点をそのまま書いたもの */
function ratchetViolations(
  thresholds: readonly number[],
  frozen: readonly number[],
): string[] {
  const violations: string[] = [];
  // ① 段階番号が連番になっている: 各閾値が自分の添字の段階に対応する(欠番・重複がない)。先頭は 0 回
  if (thresholds[0] !== 0) violations.push("先頭の閾値が 0 ではない");
  const stageOf = (grown: number): number => {
    let stage = 0;
    for (let i = 0; i < thresholds.length; i++) {
      if (grown >= thresholds[i]) stage = i;
    }
    return stage;
  };
  thresholds.forEach((t, i) => {
    if (stageOf(t) !== i) {
      violations.push(
        `段階 ${i} の閾値 ${t} が段階 ${stageOf(t)} になる(連番でない)`,
      );
    }
  });
  // ② どの閾値も基準値以下(上げない)
  frozen.forEach((base, i) => {
    if (thresholds[i] === undefined) return; // ③ で報告する
    if (thresholds[i] > base) {
      violations.push(
        `段階 ${i} の閾値 ${thresholds[i]} が基準値 ${base} より大きい(上げた)`,
      );
    }
  });
  // ③ 段階の数が基準値の数以上(減らさない・追加は末尾のみ)
  if (thresholds.length < frozen.length) {
    violations.push(
      `段階の数 ${thresholds.length} が基準値の数 ${frozen.length} より少ない`,
    );
  }
  // ④ 閾値が増える一方になっている
  for (let i = 1; i < thresholds.length; i++) {
    if (thresholds[i] <= thresholds[i - 1]) {
      violations.push(
        `段階 ${i} の閾値 ${thresholds[i]} が手前の ${
          thresholds[i - 1]
        } 以下(増える一方でない)`,
      );
    }
  }
  return violations;
}

Deno.test("ラチェット: 凍結基準は [0,1,3,7,14,21,30,45,66,100](公開した値。書き換えない)", () => {
  assertEquals([...FROZEN_THRESHOLDS], [0, 1, 3, 7, 14, 21, 30, 45, 66, 100]);
});

Deno.test("ラチェット: 現在の PLANT_STAGE_THRESHOLDS は4点すべてを満たす", () => {
  assertEquals(
    ratchetViolations(PLANT_STAGE_THRESHOLDS, FROZEN_THRESHOLDS),
    [],
  );
});

Deno.test("ラチェット: ① 段階番号が連番(各閾値がちょうどその段階の入口になる)", () => {
  PLANT_STAGE_THRESHOLDS.forEach((t, i) => {
    assertEquals(derivePlantStage(t), i, `閾値 ${t} は段階 ${i} の入口`);
  });
});

Deno.test("ラチェット: ② どの閾値も基準値以下", () => {
  FROZEN_THRESHOLDS.forEach((base, i) => {
    assertEquals(
      PLANT_STAGE_THRESHOLDS[i] <= base,
      true,
      `段階 ${i}: ${PLANT_STAGE_THRESHOLDS[i]} <= ${base}`,
    );
  });
});

Deno.test("ラチェット: ③ 段階の数が基準値の数以上", () => {
  assertEquals(
    PLANT_STAGE_THRESHOLDS.length >= FROZEN_THRESHOLDS.length,
    true,
  );
});

Deno.test("ラチェット: ④ 閾値が増える一方", () => {
  for (let i = 1; i < PLANT_STAGE_THRESHOLDS.length; i++) {
    assertEquals(
      PLANT_STAGE_THRESHOLDS[i] > PLANT_STAGE_THRESHOLDS[i - 1],
      true,
      `段階 ${i}`,
    );
  }
});

Deno.test("ラチェット(検査自体の検査): 許される変更は通り、禁じる変更は検出される", () => {
  // 許される: 閾値を下げる / 末尾に足す
  assertEquals(
    ratchetViolations([0, 1, 3, 7, 14, 21, 30, 45, 60, 100], FROZEN_THRESHOLDS),
    [],
    "66 → 60 に下げる",
  );
  assertEquals(
    ratchetViolations(
      [0, 1, 3, 7, 14, 21, 30, 45, 66, 100, 125],
      FROZEN_THRESHOLDS,
    ),
    [],
    "末尾に 125 回の段階を足す",
  );
  // 禁じる: 閾値を上げる(到達済みのペアの植物が戻って見える)
  assertEquals(
    ratchetViolations([0, 1, 3, 7, 14, 21, 30, 45, 66, 120], FROZEN_THRESHOLDS)
      .length > 0,
    true,
    "みのりを 100 → 120 に延ばす",
  );
  assertEquals(
    ratchetViolations([0, 1, 3, 8, 14, 21, 30, 45, 66, 100], FROZEN_THRESHOLDS)
      .length > 0,
    true,
    "わかばを 7 → 8 に上げる",
  );
  // 禁じる: 段階を減らす・先頭以外を差し込む・順序を乱す・重複させる・先頭が 0 でない
  assertEquals(
    ratchetViolations([0, 1, 3, 7, 14, 21, 30, 45, 66], FROZEN_THRESHOLDS)
      .length > 0,
    true,
    "末尾の段階を消す",
  );
  assertEquals(
    ratchetViolations(
      [0, 1, 3, 7, 14, 21, 30, 45, 66, 100, 90],
      FROZEN_THRESHOLDS,
    )
      .length > 0,
    true,
    "増える一方でない",
  );
  assertEquals(
    ratchetViolations([0, 1, 1, 7, 14, 21, 30, 45, 66, 100], FROZEN_THRESHOLDS)
      .length > 0,
    true,
    "同じ回数の段階が2つ(欠番になる)",
  );
  assertEquals(
    ratchetViolations(
      [1, 3, 7, 14, 21, 30, 45, 66, 100, 150],
      FROZEN_THRESHOLDS,
    )
      .length > 0,
    true,
    "先頭が 0 回でない",
  );
});

// ---- 植物: 進み具合(snapshot の plantStage / plantGrownDays / plantStageFloor / plantNextStageAt) ----

Deno.test("derivePlantProgress: 各段階の入口で floor = その段階の閾値・next = 次の段階の閾値", () => {
  for (const { stage, from } of STAGE_TABLE) {
    const next = STAGE_TABLE[stage + 1]?.from ?? null;
    assertEquals(
      derivePlantProgress(from),
      { grownDays: from, stage, stageFloor: from, nextStageAt: next },
      `段階 ${stage}(${from}回)`,
    );
  }
});

Deno.test("derivePlantProgress: 段階の途中 — GROWTH §12.2 の例(9回 → 段階3・floor 7・next 14)", () => {
  assertEquals(derivePlantProgress(9), {
    grownDays: 9,
    stage: 3,
    stageFloor: 7,
    nextStageAt: 14,
  });
  assertEquals(derivePlantProgress(0), {
    grownDays: 0,
    stage: 0,
    stageFloor: 0,
    nextStageAt: 1,
  });
});

Deno.test("derivePlantProgress: みのり以降は next が null(ゲージは「ふたりで N回 そろったよ」)", () => {
  assertEquals(derivePlantProgress(100).nextStageAt, null);
  assertEquals(derivePlantProgress(128), {
    grownDays: 128,
    stage: 9,
    stageFloor: 100,
    nextStageAt: null,
  });
});

Deno.test("derivePlantProgress: 不正値は throw", () => {
  assertThrows(() => derivePlantProgress(-1));
  assertThrows(() => derivePlantProgress(2.5));
});

// ---- 成長回数: streak_days の both の行数(GROWTH §7.2) ----

const days = (...dates: string[]): StreakDayRecord[] =>
  dates.map((d) => ({ dateLocal: d, kind: "both" as const }));

Deno.test("countBothDays: kind='both' の行だけを数える(ticket の日は数えない)", () => {
  const rows: StreakDayRecord[] = [
    { dateLocal: "2026-06-01", kind: "both" },
    { dateLocal: "2026-06-02", kind: "ticket" },
    { dateLocal: "2026-06-03", kind: "ticket" },
    { dateLocal: "2026-06-04", kind: "both" },
    { dateLocal: "2026-06-05", kind: "both" },
  ];
  assertEquals(countBothDays(rows), 3);
  assertEquals(countBothDays([]), 0);
  assertEquals(
    countBothDays([{ dateLocal: "2026-06-02", kind: "ticket" }]),
    0,
    "ticket だけなら 0(ストリークは守られるが植物は育たない)",
  );
});

Deno.test("countBothDays: 同じ日付は1日と数える(順不同・重複に強い)", () => {
  assertEquals(
    countBothDays(days("2026-06-05", "2026-06-03", "2026-06-05", "2026-06-03")),
    2,
  );
});

Deno.test("countBothDays: asOfDateLocal を渡すと、その日(含む)までの行だけを数える", () => {
  const rows = days("2026-06-07", "2026-06-08", "2026-06-09", "2026-06-10");
  assertEquals(countBothDays(rows, "2026-06-09"), 3, "6/9 まで");
  assertEquals(countBothDays(rows, "2026-06-07"), 1, "6/7 まで(その日を含む)");
  assertEquals(countBothDays(rows, "2026-06-06"), 0);
  assertEquals(countBothDays(rows, "2026-12-31"), 4);
});

Deno.test("countBothDays: 不正な日付は throw", () => {
  assertThrows(() => countBothDays([{ dateLocal: "2026-6-1", kind: "both" }]));
  assertThrows(() => countBothDays([], "2026-02-30"));
});

// ---- 植物: 表情(normal / happy / fidget / sad。枯れ状態は存在しない) ----

Deno.test("derivePlantMood: 両者完了 = happy", () => {
  assertEquals(
    derivePlantMood({
      todayMeDone: true,
      todayPartnerDone: true,
      consecutiveMissedDays: 0,
    }),
    "happy",
  );
});

Deno.test("derivePlantMood: 片方未完 = fidget(どちら側でも)", () => {
  assertEquals(
    derivePlantMood({
      todayMeDone: true,
      todayPartnerDone: false,
      consecutiveMissedDays: 0,
    }),
    "fidget",
  );
  assertEquals(
    derivePlantMood({
      todayMeDone: false,
      todayPartnerDone: true,
      consecutiveMissedDays: 0,
    }),
    "fidget",
  );
});

Deno.test("derivePlantMood: 2日連続未達成+今日も両者未完 = sad(アプリでは「すやすや」)", () => {
  assertEquals(
    derivePlantMood({
      todayMeDone: false,
      todayPartnerDone: false,
      consecutiveMissedDays: 2,
    }),
    "sad",
  );
});

Deno.test("derivePlantMood: 未達成1日まで・今日未着手なら normal(まだ落ち込まない)", () => {
  assertEquals(
    derivePlantMood({
      todayMeDone: false,
      todayPartnerDone: false,
      consecutiveMissedDays: 0,
    }),
    "normal",
  );
  assertEquals(
    derivePlantMood({
      todayMeDone: false,
      todayPartnerDone: false,
      consecutiveMissedDays: 1,
    }),
    "normal",
  );
});

Deno.test("derivePlantMood: 連続未達成中でも両者完了したら happy(達成が優先)", () => {
  assertEquals(
    derivePlantMood({
      todayMeDone: true,
      todayPartnerDone: true,
      consecutiveMissedDays: 5,
    }),
    "happy",
  );
});

// ---- 連続未達成日数 ----

Deno.test("countConsecutiveMissedDays: 直近2日が未達成なら 2", () => {
  assertEquals(
    countConsecutiveMissedDays({
      days: days("2026-06-05", "2026-06-06", "2026-06-07"),
      asOfDateLocal: "2026-06-09",
      startedOn: "2026-06-01",
    }),
    2,
  );
});

Deno.test("countConsecutiveMissedDays: 昨日まで継続中なら 0", () => {
  assertEquals(
    countConsecutiveMissedDays({
      days: days("2026-06-08", "2026-06-09"),
      asOfDateLocal: "2026-06-09",
      startedOn: "2026-06-01",
    }),
    0,
  );
});

Deno.test("countConsecutiveMissedDays: started_on より前は数えない", () => {
  assertEquals(
    countConsecutiveMissedDays({
      days: [],
      asOfDateLocal: "2026-06-09",
      startedOn: "2026-06-09",
    }),
    1,
    "成立日当日のみ未達成",
  );
  assertEquals(
    countConsecutiveMissedDays({
      days: [],
      asOfDateLocal: "2026-06-09",
      startedOn: "2026-06-10",
    }),
    0,
    "今日成立したペアに未達成日はない",
  );
});

// ---- date_local ヘルパ ----

Deno.test("addDaysLocal: 前日・翌日・月跨ぎ", () => {
  assertEquals(addDaysLocal("2026-06-01", -1), "2026-05-31");
  assertEquals(addDaysLocal("2026-02-28", 1), "2026-03-01", "2026年は平年");
  assertEquals(addDaysLocal("2024-02-28", 1), "2024-02-29", "うるう年");
  assertThrows(() => addDaysLocal("2026-6-1", 1), "形式不正");
});

Deno.test("dateLocalInTimeZone: Asia/Tokyo の日付跨ぎ(UTC 16:00 = JST 翌1:00)", () => {
  assertEquals(
    dateLocalInTimeZone(new Date("2026-06-10T16:00:00Z"), "Asia/Tokyo"),
    "2026-06-11",
  );
  assertEquals(
    dateLocalInTimeZone(new Date("2026-06-10T14:59:00Z"), "Asia/Tokyo"),
    "2026-06-10",
    "JST 23:59 はまだ当日",
  );
  assertEquals(
    dateLocalInTimeZone(new Date("2026-06-10T16:00:00Z"), "UTC"),
    "2026-06-10",
  );
});

Deno.test("dateLocalInTimeZone: 不正TZは既定 Asia/Tokyo にフォールバック", () => {
  assertEquals(
    dateLocalInTimeZone(new Date("2026-06-10T16:00:00Z"), "Mars/Olympus"),
    "2026-06-11",
  );
});

// ---- 確定の窓(close-day が昨日を確定し終えるまで): 現地の日付と時・窓の判定・実効の今日 ----

Deno.test("localDateAndHour: ユーザーTZの現地の日付と時(0時は 24 でなく 0)", () => {
  const at = (iso: string, tz: string) => localDateAndHour(new Date(iso), tz);
  assertEquals(at("2026-06-10T15:00:00Z", "Asia/Tokyo"), {
    dateLocal: "2026-06-11",
    hour: 0,
  });
  assertEquals(at("2026-06-10T15:05:00Z", "Asia/Tokyo"), {
    dateLocal: "2026-06-11",
    hour: 0,
  });
  assertEquals(at("2026-06-10T14:59:59Z", "Asia/Tokyo"), {
    dateLocal: "2026-06-10",
    hour: 23,
  });
  assertEquals(at("2026-06-10T16:00:00Z", "Asia/Tokyo"), {
    dateLocal: "2026-06-11",
    hour: 1,
  });
  // 日付がずれる TZ(ホノルル = UTC-10)
  assertEquals(at("2026-06-10T03:00:00Z", "Pacific/Honolulu"), {
    dateLocal: "2026-06-09",
    hour: 17,
  });
  assertEquals(at("2026-06-10T10:00:00Z", "Pacific/Honolulu"), {
    dateLocal: "2026-06-10",
    hour: 0,
  });
  // 不正な TZ は既定 Asia/Tokyo
  assertEquals(at("2026-06-10T15:05:00Z", "Mars/Olympus"), {
    dateLocal: "2026-06-11",
    hour: 0,
  });
});

Deno.test("isAtOrAfterLocalHour: ちょうどの時刻から true。日付をまたいだ比較にも対応", () => {
  const check = (iso: string, dateLocal: string, hour = 1) =>
    isAtOrAfterLocalHour({
      now: new Date(iso),
      timeZone: "Asia/Tokyo",
      dateLocal,
      hour,
    });
  // 2026-06-11 の 1:00 JST = 2026-06-10T16:00:00Z
  assertEquals(check("2026-06-10T15:59:59Z", "2026-06-11"), false, "0:59:59");
  assertEquals(check("2026-06-10T16:00:00Z", "2026-06-11"), true, "1:00:00");
  assertEquals(check("2026-06-10T15:00:00Z", "2026-06-11"), false, "0:00");
  assertEquals(check("2026-06-11T03:00:00Z", "2026-06-11"), true, "12:00");
  assertEquals(check("2026-06-11T03:00:00Z", "2026-06-12"), false, "前日");
  assertEquals(check("2026-06-12T15:00:00Z", "2026-06-11"), true, "翌々日");
  assertEquals(
    check("2026-06-10T15:00:00Z", "2026-06-11", 0),
    true,
    "0 時ちょうど",
  );
  assertEquals(CLOSE_DAY_SETTLE_HOUR, 1, "窓は 1:00(close-day は 00:10 JST)");
});

Deno.test("resolveTodayLocal: override が無ければ実際の今日、確定前の日の override はそのまま、確定を過ぎた override は捨てる", () => {
  const today = (iso: string, override?: string, timeZone = "Asia/Tokyo") =>
    resolveTodayLocal({ now: new Date(iso), timeZone, override });
  // JST 2026-06-11 12:00(= 03:00Z)
  assertEquals(today("2026-06-11T03:00:00Z"), "2026-06-11", "override なし");
  assertEquals(today("2026-06-11T03:00:00Z", "2026-06-11"), "2026-06-11");
  // 時計が進んだ端末(翌日付け)は使う
  assertEquals(today("2026-06-11T03:00:00Z", "2026-06-12"), "2026-06-12");
  // 昨日付け: JST 6/11 0:30 はまだ昨日(6/10)の確定前 → 使う(時計の遅れ・直前のキュー再送)
  assertEquals(today("2026-06-10T15:30:00Z", "2026-06-10"), "2026-06-10");
  assertEquals(
    today("2026-06-10T15:59:59Z", "2026-06-10"),
    "2026-06-10",
    "0:59:59",
  );
  // 1:00 を過ぎたら 6/10 は確定済み → 捨てて本当の今日(6/11)
  assertEquals(
    today("2026-06-10T16:00:00Z", "2026-06-10"),
    "2026-06-11",
    "1:00:00",
  );
  assertEquals(today("2026-06-11T03:00:00Z", "2026-06-10"), "2026-06-11", "昼");
  // 古い override(キューに溜まった数日前の分)も捨てる
  assertEquals(today("2026-06-11T03:00:00Z", "2026-06-07"), "2026-06-11");
  // TZ が違えば窓も変わる(ホノルル: 2026-06-11 の 1:00 HST = 11:00Z)
  assertEquals(
    today("2026-06-11T10:59:59Z", "2026-06-10", "Pacific/Honolulu"),
    "2026-06-10",
  );
  assertEquals(
    today("2026-06-11T11:00:00Z", "2026-06-10", "Pacific/Honolulu"),
    "2026-06-11",
  );
  assertThrows(() => today("2026-06-11T03:00:00Z", "2026-6-10"), "形式不正");
});

// ---- snapshot 組み立て(DESIGN §3.4。キー名一字一句一致) ----

/** DESIGN §3.4 schemaVersion=1 の全19キー(成長ルール v2 でキー3つを足した: 16 → 19) */
const SNAPSHOT_KEYS = [
  "schemaVersion",
  "pairId",
  "updatedAt",
  "streakCurrent",
  "streakBest",
  "todayMeDone",
  "todayPartnerDone",
  "myPromiseTitle",
  "myPromiseEmoji",
  "partnerName",
  "partnerPromiseTitle",
  "partnerPromiseEmoji",
  "plantStage",
  "plantGrownDays",
  "plantStageFloor",
  "plantNextStageAt",
  "plantMood",
  "plantName",
  "hasPartnerPhotoToday",
].sort();

/**
 * 確定済みの連続5日(6/5〜6/9)+ 途切れた前の1日(6/2)= ふたり達成 6 回
 * (めばえ。わかば(7回)の一歩手前なので、今日の先取りで昇格を試せる)。ストリークは 5。
 */
const BASE_DAYS = days(
  "2026-06-02",
  "2026-06-05",
  "2026-06-06",
  "2026-06-07",
  "2026-06-08",
  "2026-06-09",
);

function baseInput() {
  return {
    pairId: "pair-1",
    updatedAtIso: "2026-06-10T03:00:00.000Z",
    todayLocal: "2026-06-10",
    startedOn: "2026-06-01",
    streakDays: BASE_DAYS,
    todayMeDone: true,
    todayPartnerDone: false,
    myPromise: { title: "筋トレ", emoji: "💪" },
    partnerName: "ゆうき",
    partnerPromise: { title: "ランニング", emoji: "🏃" },
    plantName: "みどり",
    hasPartnerPhotoToday: false,
  };
}

Deno.test("SNAPSHOT_KEYS は 19 個", () => {
  assertEquals(SNAPSHOT_KEYS.length, 19);
});

Deno.test("buildPairSnapshot: キー集合が §3.4 と一字一句一致する", () => {
  const snapshot = buildPairSnapshot(baseInput());
  assertEquals(Object.keys(snapshot).sort(), SNAPSHOT_KEYS);
});

Deno.test("buildSoloSnapshot: キー集合が §3.4 と一字一句一致する", () => {
  const snapshot = buildSoloSnapshot({
    updatedAtIso: "2026-06-10T03:00:00.000Z",
    todayMeDone: false,
    myPromise: null,
  });
  assertEquals(Object.keys(snapshot).sort(), SNAPSHOT_KEYS);
});

Deno.test("buildPairSnapshot: 自分だけ完了 = 確定ストリーク表示+fidget+成長回数は行の数", () => {
  const snapshot = buildPairSnapshot(baseInput());
  const expected: PairSnapshot = {
    schemaVersion: 1,
    pairId: "pair-1",
    updatedAt: "2026-06-10T03:00:00.000Z",
    streakCurrent: 5,
    streakBest: 5,
    todayMeDone: true,
    todayPartnerDone: false,
    myPromiseTitle: "筋トレ",
    myPromiseEmoji: "💪",
    partnerName: "ゆうき",
    partnerPromiseTitle: "ランニング",
    partnerPromiseEmoji: "🏃",
    plantStage: 2, // ふたり達成 6 回 = めばえ
    plantGrownDays: 6,
    plantStageFloor: 3,
    plantNextStageAt: 7,
    plantMood: "fidget",
    plantName: "みどり",
    hasPartnerPhotoToday: false,
  };
  assertEquals(snapshot, expected);
});

Deno.test("buildPairSnapshot: 両者完了 = プレビュー+1(streak 6・6+1=7回でわかばに昇格・happy)", () => {
  const snapshot = buildPairSnapshot({
    ...baseInput(),
    todayPartnerDone: true,
    hasPartnerPhotoToday: true,
  });
  assertEquals(snapshot.streakCurrent, 6, "確定5+今日両者完了で6");
  assertEquals(snapshot.streakBest, 6, "best も現在値を下回らない");
  assertEquals(snapshot.plantStage, 3, "6+1=7回でわかば");
  assertEquals(snapshot.plantGrownDays, 7);
  assertEquals(snapshot.plantStageFloor, 7);
  assertEquals(snapshot.plantNextStageAt, 14);
  assertEquals(snapshot.plantMood, "happy");
  assertEquals(snapshot.hasPartnerPhotoToday, true);
});

Deno.test("buildPairSnapshot: 片方だけ完了では先取りしない(ふたり達成でなければ育たない)", () => {
  const me = buildPairSnapshot(baseInput()); // 自分だけ
  assertEquals(me.plantGrownDays, 6);
  const partner = buildPairSnapshot({
    ...baseInput(),
    todayMeDone: false,
    todayPartnerDone: true,
  });
  assertEquals(partner.plantGrownDays, 6);
  assertEquals(partner.streakCurrent, 5);
});

Deno.test("buildPairSnapshot: 2日途切れ+今日未着手 = current 0・best は残る・sad(すやすや)・回数は縮まない", () => {
  const snapshot = buildPairSnapshot({
    ...baseInput(),
    streakDays: days(
      "2026-06-03",
      "2026-06-04",
      "2026-06-05",
      "2026-06-06",
      "2026-06-07",
    ),
    todayMeDone: false,
    todayPartnerDone: false,
  });
  assertEquals(snapshot.streakCurrent, 0);
  assertEquals(snapshot.streakBest, 5, "最高記録は維持(REQUIREMENTS §3.5)");
  assertEquals(snapshot.plantMood, "sad");
  assertEquals(
    snapshot.plantGrownDays,
    5,
    "ストリークが途切れても回数は減らない",
  );
  assertEquals(snapshot.plantStage, 2, "枯れない・後退しない(5回のままめばえ)");
});

Deno.test("buildPairSnapshot: ticket の日はストリークに数えるが成長回数には数えない", () => {
  const rows: StreakDayRecord[] = [
    { dateLocal: "2026-06-06", kind: "both" },
    { dateLocal: "2026-06-07", kind: "ticket" },
    { dateLocal: "2026-06-08", kind: "ticket" },
    { dateLocal: "2026-06-09", kind: "both" },
  ];
  const snapshot = buildPairSnapshot({ ...baseInput(), streakDays: rows });
  assertEquals(snapshot.streakCurrent, 4, "ticket の日も継続日");
  assertEquals(snapshot.plantGrownDays, 2, "ふたり達成は 2 回だけ");
  assertEquals(snapshot.plantStage, 1, "2回 = ふたば");
});

Deno.test("buildPairSnapshot: 今日以降の行は成長回数に数えない(今日の先取りと二重にならない)", () => {
  // クライアントの時計が遅れていて、確定済みの行(6/10)が「今日」に見える場合など:
  // 今日(6/10)の行がすでにあり、両者完了でもある → 6 回(昨日まで)+ 先取り 1 = 7 回。8 回にならない
  const snapshot = buildPairSnapshot({
    ...baseInput(),
    streakDays: [...BASE_DAYS, { dateLocal: "2026-06-10", kind: "both" }],
    todayPartnerDone: true,
  });
  assertEquals(snapshot.plantGrownDays, 7);
  assertEquals(snapshot.plantStage, 3);
});

Deno.test("buildPairSnapshot: 新しい3キーは JSON にしたとき必ず残る(next が null でもキーは落ちない)", () => {
  const solo = JSON.parse(JSON.stringify(buildSoloSnapshot({
    updatedAtIso: "2026-06-10T03:00:00.000Z",
    todayMeDone: false,
    myPromise: null,
  })));
  assertEquals(solo.plantGrownDays, 0);
  assertEquals(solo.plantStageFloor, 0);
  assertEquals(
    "plantNextStageAt" in solo,
    true,
    "undefined ではなく null で出す",
  );
  assertEquals(solo.plantNextStageAt, null);

  const top = JSON.parse(JSON.stringify(buildPairSnapshot({
    ...baseInput(),
    streakDays: days(
      ...Array.from({ length: 100 }, (_, i) => addDaysLocal("2026-01-01", i)),
    ),
  })));
  assertEquals(top.plantGrownDays, 100);
  assertEquals(top.plantStage, 9);
  assertEquals(top.plantStageFloor, 100);
  assertEquals("plantNextStageAt" in top, true);
  assertEquals(top.plantNextStageAt, null, "みのりは次の段階が無い");
});

Deno.test("buildSoloSnapshot: ソロ状態は pairId null・土だけ・約束は自分のもののみ・進み具合は 0 / 0 / null", () => {
  const snapshot = buildSoloSnapshot({
    updatedAtIso: "2026-06-10T03:00:00.000Z",
    todayMeDone: true,
    myPromise: { title: "読書", emoji: "📚" },
  });
  const expected: PairSnapshot = {
    schemaVersion: 1,
    pairId: null,
    updatedAt: "2026-06-10T03:00:00.000Z",
    streakCurrent: 0,
    streakBest: 0,
    todayMeDone: true,
    todayPartnerDone: false,
    myPromiseTitle: "読書",
    myPromiseEmoji: "📚",
    partnerName: null,
    partnerPromiseTitle: null,
    partnerPromiseEmoji: null,
    plantStage: 0,
    plantGrownDays: 0,
    plantStageFloor: 0,
    plantNextStageAt: null,
    plantMood: "normal",
    plantName: null,
    hasPartnerPhotoToday: false,
  };
  assertEquals(snapshot, expected);
});

// ---- 昨日の仮判定(GROWTH §7.3 の最小版。純粋関数) ----
//
// 窓: 実効の今日(yesterdayLocal の翌日)の 1:00(ユーザーTZ)より前だけ。
// 昨日 = 2026-06-10 のとき、今日 = 6/11。JST 6/11 1:00 = 2026-06-10T16:00:00Z

/** JST 2026-06-11 0:05。close-day(0:10)の前 = 窓の中 */
const IN_WINDOW = {
  now: new Date("2026-06-10T15:05:00Z"),
  timeZone: "Asia/Tokyo",
};

Deno.test("needsProvisionalYesterday: 窓の中で、昨日の行が無く、昨日が成立日以降のときだけ true", () => {
  const base = {
    yesterdayLocal: "2026-06-10",
    startedOn: "2026-06-01",
    ...IN_WINDOW,
  };
  assertEquals(
    needsProvisionalYesterday({ ...base, days: days("2026-06-09") }),
    true,
    "昨日の行が無い",
  );
  assertEquals(
    needsProvisionalYesterday({ ...base, days: days("2026-06-10") }),
    false,
    "both の行がある = 確定済み",
  );
  assertEquals(
    needsProvisionalYesterday({
      ...base,
      days: [{ dateLocal: "2026-06-10", kind: "ticket" }],
    }),
    false,
    "ticket の行がある = 確定済み",
  );
  assertEquals(
    needsProvisionalYesterday({ ...base, days: [], startedOn: "2026-06-11" }),
    false,
    "昨日はペア成立前",
  );
  assertEquals(
    needsProvisionalYesterday({ ...base, days: [], startedOn: "2026-06-10" }),
    true,
    "成立日当日は対象(started_on 以降)",
  );
});

Deno.test("needsProvisionalYesterday: 窓の境目 — 0:00〜0:59:59 は true、1:00:00 以降は false(行が無くても)", () => {
  const at = (iso: string, timeZone = "Asia/Tokyo") =>
    needsProvisionalYesterday({
      days: [],
      yesterdayLocal: "2026-06-10",
      startedOn: "2026-06-01",
      now: new Date(iso),
      timeZone,
    });
  assertEquals(at("2026-06-10T15:00:00Z"), true, "JST 0:00:00");
  assertEquals(at("2026-06-10T15:10:00Z"), true, "JST 0:10(close-day の起動)");
  assertEquals(at("2026-06-10T15:59:59Z"), true, "JST 0:59:59");
  assertEquals(at("2026-06-10T16:00:00Z"), false, "JST 1:00:00");
  assertEquals(at("2026-06-11T03:00:00Z"), false, "JST 昼");
  assertEquals(at("2026-06-11T14:00:00Z"), false, "JST 夜");
  assertEquals(at("2026-06-12T15:05:00Z"), false, "2日後の 0:05 でも窓の外");
  // 時計が進んだ端末: サーバーの now が実効の今日(6/11)より前でも true
  assertEquals(at("2026-06-10T14:59:30Z"), true, "JST 6/10 23:59:30");
  // 窓はユーザーのタイムゾーンで決まる
  assertEquals(
    at("2026-06-11T04:59:59Z", "America/New_York"),
    true,
    "NY 6/11 0:59:59",
  );
  assertEquals(
    at("2026-06-11T05:00:00Z", "America/New_York"),
    false,
    "NY 6/11 1:00:00",
  );
  assertEquals(
    at("2026-06-11T10:59:59Z", "Pacific/Honolulu"),
    true,
    "ホノルル 6/11 0:59:59",
  );
  assertEquals(
    at("2026-06-11T11:00:00Z", "Pacific/Honolulu"),
    false,
    "ホノルル 6/11 1:00:00",
  );
});

Deno.test("provisionalYesterdayRow: 窓の中で2人とも昨日チェックイン済みなら both の行を返す", () => {
  assertEquals(
    provisionalYesterdayRow({
      days: [],
      yesterdayLocal: "2026-06-10",
      startedOn: "2026-06-01",
      ...IN_WINDOW,
      meCheckedInYesterday: true,
      partnerCheckedInYesterday: true,
    }),
    { dateLocal: "2026-06-10", kind: "both" },
  );
});

Deno.test("provisionalYesterdayRow: 片方だけ・どちらもなら null(ふたり達成とみなさない)", () => {
  for (const [me, partner] of [[true, false], [false, true], [false, false]]) {
    assertEquals(
      provisionalYesterdayRow({
        days: [],
        yesterdayLocal: "2026-06-10",
        startedOn: "2026-06-01",
        ...IN_WINDOW,
        meCheckedInYesterday: me,
        partnerCheckedInYesterday: partner,
      }),
      null,
      `me=${me} partner=${partner}`,
    );
  }
});

Deno.test("provisionalYesterdayRow: 行があるときは足さない(二重に数えない)・成立前も null", () => {
  assertEquals(
    provisionalYesterdayRow({
      days: days("2026-06-10"),
      yesterdayLocal: "2026-06-10",
      startedOn: "2026-06-01",
      ...IN_WINDOW,
      meCheckedInYesterday: true,
      partnerCheckedInYesterday: true,
    }),
    null,
  );
  assertEquals(
    provisionalYesterdayRow({
      days: [],
      yesterdayLocal: "2026-06-10",
      startedOn: "2026-06-11",
      ...IN_WINDOW,
      meCheckedInYesterday: true,
      partnerCheckedInYesterday: true,
    }),
    null,
  );
});

Deno.test("provisionalYesterdayRow: 窓の外(1:00 以降)は、2人とも昨日チェックイン済みでも null(行が無い昨日はリセット済みかもしれない)", () => {
  for (
    const iso of [
      "2026-06-10T16:00:00Z", // JST 1:00:00
      "2026-06-11T03:00:00Z", // JST 昼
      "2026-06-11T14:59:00Z", // JST 23:59
    ]
  ) {
    assertEquals(
      provisionalYesterdayRow({
        days: [],
        yesterdayLocal: "2026-06-10",
        startedOn: "2026-06-01",
        now: new Date(iso),
        timeZone: "Asia/Tokyo",
        meCheckedInYesterday: true,
        partnerCheckedInYesterday: true,
      }),
      null,
      iso,
    );
  }
});

// ---- loadSnapshotForUser(fake repo で受信者視点の組み立てを検証) ----

interface FakeWorld {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>;
  pair:
    | { pairId: string; startedOn: string; memberIds: [string, string] }
    | null;
  checkins: Record<string, SnapshotCheckinRow>; // key: `${userId}|${dateLocal}`
  streakDays: StreakDayRecord[];
  plant: SnapshotPlantRow | null;
}

/** getCheckin の呼び出し(userId|dateLocal)を記録する。昨日の仮判定が余計な問い合わせをしないことの検査用 */
function makeFakeRepo(
  world: FakeWorld,
  calls: string[] = [],
): SnapshotRepo {
  return {
    getUser: (id) =>
      Promise.resolve(world.users.find((u) => u.id === id) ?? null),
    getActivePromise: (id) => Promise.resolve(world.promises[id] ?? null),
    getActivePair: (id): Promise<SnapshotPairRow | null> => {
      if (!world.pair || !world.pair.memberIds.includes(id)) {
        return Promise.resolve(null);
      }
      const partnerId = world.pair.memberIds.find((m) => m !== id)!;
      const partner = world.users.find((u) => u.id === partnerId)!;
      return Promise.resolve({
        pairId: world.pair.pairId,
        startedOn: world.pair.startedOn,
        partner,
      });
    },
    getCheckin: (id, dateLocal) => {
      calls.push(`${id}|${dateLocal}`);
      return Promise.resolve(world.checkins[`${id}|${dateLocal}`] ?? null);
    },
    listStreakDays: () => Promise.resolve([...world.streakDays]),
    getPlant: () => Promise.resolve(world.plant),
  };
}

const userA: SnapshotUserRow = {
  id: "user-a",
  nickname: "あきら",
  timezone: "Asia/Tokyo",
  pushToken: "token-a",
};
const userB: SnapshotUserRow = {
  id: "user-b",
  nickname: "ゆうき",
  timezone: "Asia/Tokyo",
  pushToken: "token-b",
};

function pairWorld(overrides: Partial<FakeWorld> = {}): FakeWorld {
  return {
    users: [userA, userB],
    promises: {
      "user-a": { id: "prom-a", title: "筋トレ", emoji: "💪" },
      "user-b": { id: "prom-b", title: "ランニング", emoji: "🏃" },
    },
    pair: {
      pairId: "pair-1",
      startedOn: "2026-06-01",
      memberIds: ["user-a", "user-b"],
    },
    checkins: {},
    streakDays: [],
    plant: { grownDays: 0, name: null },
    ...overrides,
  };
}

Deno.test("loadSnapshotForUser: 受信者視点で me/partner が組み上がる(反転しない)", async () => {
  const repo = makeFakeRepo(pairWorld({
    checkins: {
      "user-a|2026-06-10": { photoPath: "pairs/pair-1/2026-06-10/a.jpg" },
    },
    streakDays: days("2026-06-08", "2026-06-09"),
    plant: { grownDays: 4, name: "みどり" },
  }));
  const now = new Date("2026-06-10T03:00:00Z"); // JST 12:00 → today = 2026-06-10

  // B 視点: 自分は未完・相手(A)は完了済み+写真あり
  const forB = await loadSnapshotForUser(repo, { userId: "user-b", now });
  assertEquals(forB.pairId, "pair-1");
  assertEquals(forB.todayMeDone, false);
  assertEquals(forB.todayPartnerDone, true);
  assertEquals(forB.myPromiseTitle, "ランニング");
  assertEquals(forB.partnerName, "あきら");
  assertEquals(forB.partnerPromiseTitle, "筋トレ");
  assertEquals(forB.hasPartnerPhotoToday, true, "相手(A)の今日の写真");
  assertEquals(forB.streakCurrent, 2);
  assertEquals(
    forB.plantStage,
    1,
    "ふたり達成 2 回(行の数。plants.grown_days=4 は読まない)= ふたば",
  );
  assertEquals(forB.plantGrownDays, 2);
  assertEquals(forB.plantMood, "fidget");

  // A 視点: 自分は完了済み・相手(B)は未完・相手の写真はない
  const forA = await loadSnapshotForUser(repo, { userId: "user-a", now });
  assertEquals(forA.todayMeDone, true);
  assertEquals(forA.todayPartnerDone, false);
  assertEquals(forA.partnerName, "ゆうき");
  assertEquals(forA.hasPartnerPhotoToday, false);
});

Deno.test("loadSnapshotForUser: ペア未成立はソロ snapshot", async () => {
  const repo = makeFakeRepo({
    users: [userA],
    promises: { "user-a": { id: "prom-a", title: "筋トレ", emoji: "💪" } },
    pair: null,
    checkins: {},
    streakDays: [],
    plant: null,
  });
  const snapshot = await loadSnapshotForUser(repo, {
    userId: "user-a",
    now: new Date("2026-06-10T03:00:00Z"),
  });
  assertEquals(snapshot.pairId, null);
  assertEquals(snapshot.plantStage, 0);
  assertEquals(snapshot.plantGrownDays, 0);
  assertEquals(snapshot.plantStageFloor, 0);
  assertEquals(snapshot.plantNextStageAt, null);
  assertEquals(snapshot.todayMeDone, false);
  assertEquals(snapshot.partnerName, null);
});

Deno.test("loadSnapshotForUser: todayLocalOverride が「今日」を上書きする", async () => {
  const repo = makeFakeRepo(pairWorld({
    checkins: { "user-a|2026-06-10": { photoPath: null } },
  }));
  // now は JST 2026-06-11 0:05 だが、override で 06-10 を「今日」として扱う
  const now = new Date("2026-06-10T15:05:00Z");
  const withOverride = await loadSnapshotForUser(repo, {
    userId: "user-a",
    now,
    todayLocalOverride: "2026-06-10",
  });
  assertEquals(withOverride.todayMeDone, true);
  const withoutOverride = await loadSnapshotForUser(repo, {
    userId: "user-a",
    now,
  });
  assertEquals(withoutOverride.todayMeDone, false, "TZ上はもう翌日");
});

// ---- 行から数え直す(GROWTH §7.2): plants.grown_days は読まない ----

Deno.test("loadSnapshotForUser: plants.grown_days が古くても(0 でも 999 でも)行の数から正しい回数になる", async () => {
  const rows = days(
    "2026-06-01",
    "2026-06-02",
    "2026-06-03",
    "2026-06-04",
    "2026-06-05",
  ); // ふたり達成 5 回 = めばえ
  const now = new Date("2026-06-10T03:00:00Z");
  for (const stale of [0, 1, 13, 999]) {
    const repo = makeFakeRepo(pairWorld({
      streakDays: rows,
      plant: { grownDays: stale, name: null },
    }));
    const snapshot = await loadSnapshotForUser(repo, { userId: "user-a", now });
    assertEquals(snapshot.plantGrownDays, 5, `grown_days=${stale} でも 5`);
    assertEquals(snapshot.plantStage, 2);
    assertEquals(snapshot.plantStageFloor, 3);
    assertEquals(snapshot.plantNextStageAt, 7);
  }
});

Deno.test("loadSnapshotForUser: plants の行が無くても行の数で数える(名前は null)", async () => {
  const repo = makeFakeRepo(pairWorld({
    streakDays: days("2026-06-08", "2026-06-09"),
    plant: null,
  }));
  const snapshot = await loadSnapshotForUser(repo, {
    userId: "user-a",
    now: new Date("2026-06-10T03:00:00Z"),
  });
  assertEquals(snapshot.plantGrownDays, 2);
  assertEquals(snapshot.plantName, null);
});

// ---- 昨日の仮判定(GROWTH §7.3): 0:00〜0:10 に昨日の行がまだ無いとき ----

/** JST 2026-06-11 0:05 = close-day(0:10)の前。today = 6/11、yesterday = 6/10 */
const AFTER_MIDNIGHT = new Date("2026-06-10T15:05:00Z");

Deno.test("昨日の仮判定: 2人とも昨日チェックイン済みなら、ストリーク・成長回数・すやすや判定のすべてに昨日を数える", async () => {
  // 確定済みの行は 6/9 まで。6/10(昨日)は両者チェックイン済みだが close-day が未実行
  const confirmed = days(
    "2026-06-05",
    "2026-06-06",
    "2026-06-07",
    "2026-06-08",
    "2026-06-09",
  );
  const repo = makeFakeRepo(pairWorld({
    checkins: {
      "user-a|2026-06-10": { photoPath: null },
      "user-b|2026-06-10": { photoPath: null },
    },
    streakDays: confirmed,
  }));

  const forA = await loadSnapshotForUser(repo, {
    userId: "user-a",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(forA.streakCurrent, 6, "昨日を数えるので 0 に見えない(5 → 6)");
  assertEquals(forA.plantGrownDays, 5 + 1, "成長回数にも昨日を足す");
  assertEquals(forA.plantMood, "normal", "昨日を未達成と数えて sad にしない");
  assertEquals(forA.todayMeDone, false, "今日はまだ誰もチェックインしていない");

  const forB = await loadSnapshotForUser(repo, {
    userId: "user-b",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(forB.streakCurrent, 6, "相手視点でも同じ");
  assertEquals(forB.plantGrownDays, 6);
});

Deno.test("昨日の仮判定: 0時台に、昨日の分で上がった段階が1つ戻って見えない", async () => {
  // ふたり達成 6 回 + 昨日(6/10)の分 = 7 回 → わかば。昨日の昼には「今日の先取り」でわかばに上がっていた
  const confirmed = days(
    "2026-06-02",
    "2026-06-05",
    "2026-06-06",
    "2026-06-07",
    "2026-06-08",
    "2026-06-09",
  );
  const world = pairWorld({
    checkins: {
      "user-a|2026-06-10": { photoPath: null },
      "user-b|2026-06-10": { photoPath: null },
    },
    streakDays: confirmed,
  });

  // 6/10 の昼(両者完了の先取り)
  const daytime = await loadSnapshotForUser(makeFakeRepo(world), {
    userId: "user-a",
    now: new Date("2026-06-10T03:00:00Z"),
  });
  assertEquals(daytime.plantStage, 3, "7 回でわかば(先取り)");

  // 6/11 の 0:05(close-day 前)。仮判定が無ければ 6 回に戻ってめばえに見える
  const afterMidnight = await loadSnapshotForUser(makeFakeRepo(world), {
    userId: "user-a",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(afterMidnight.plantStage, 3, "わかばのまま(1つ戻らない)");
  assertEquals(afterMidnight.plantGrownDays, 7);
  assertEquals(afterMidnight.plantStageFloor, 7);
  assertEquals(afterMidnight.plantNextStageAt, 14);

  // close-day が行を書いた後(0:10 以降)も同じ値(仮判定は確定結果と一致する)
  const confirmedWorld = pairWorld({
    checkins: world.checkins,
    streakDays: [...confirmed, { dateLocal: "2026-06-10", kind: "both" }],
  });
  const afterClose = await loadSnapshotForUser(makeFakeRepo(confirmedWorld), {
    userId: "user-a",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(afterClose.plantGrownDays, afterMidnight.plantGrownDays);
  assertEquals(afterClose.streakCurrent, afterMidnight.streakCurrent);
  assertEquals(afterClose.plantMood, afterMidnight.plantMood);
});

Deno.test("昨日の仮判定: 昨日を未達成と数えて sad(すやすや)が誤って出ない", async () => {
  // 6/9 は本当に達成していない(リセット済みで行なし)。6/10 は両者達成だが close-day 前。
  // 仮判定が無いと「6/9・6/10 が連続して未達成」= 2日 → 今日まだ誰も未チェックなら sad になってしまう
  const world = pairWorld({
    checkins: {
      "user-a|2026-06-10": { photoPath: null },
      "user-b|2026-06-10": { photoPath: null },
    },
    streakDays: days("2026-06-05", "2026-06-06", "2026-06-07", "2026-06-08"),
  });
  const snapshot = await loadSnapshotForUser(makeFakeRepo(world), {
    userId: "user-a",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(
    snapshot.plantMood,
    "normal",
    "昨日は達成しているので sad ではない",
  );
  assertEquals(
    snapshot.streakCurrent,
    1,
    "昨日だけが続いている(6/9 で途切れた)",
  );

  // 対照: 昨日も本当に未達成(片方だけ)なら、2日連続で sad
  const missed = pairWorld({
    checkins: { "user-a|2026-06-10": { photoPath: null } }, // B は昨日未チェックイン
    streakDays: days("2026-06-05", "2026-06-06", "2026-06-07", "2026-06-08"),
  });
  const sad = await loadSnapshotForUser(makeFakeRepo(missed), {
    userId: "user-a",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(
    sad.plantMood,
    "sad",
    "6/9・6/10 とも未達成 + 今日まだ誰もチェックインしていない",
  );
  assertEquals(sad.streakCurrent, 0);
});

Deno.test("昨日の仮判定: 片方だけが昨日チェックインしていても足さない(ふたり達成ではない)", async () => {
  for (const who of ["user-a", "user-b"]) {
    const repo = makeFakeRepo(pairWorld({
      checkins: { [`${who}|2026-06-10`]: { photoPath: null } },
      streakDays: days("2026-06-08", "2026-06-09"),
    }));
    const snapshot = await loadSnapshotForUser(repo, {
      userId: "user-a",
      now: AFTER_MIDNIGHT,
    });
    assertEquals(snapshot.plantGrownDays, 2, `${who} だけ → 足さない`);
    assertEquals(
      snapshot.streakCurrent,
      0,
      "昨日の行が無い = 0(ticket で守られる日は ticket_used 通知で直る — §7.3)",
    );
  }
});

Deno.test("昨日の仮判定: 昨日の行があるときは二重に足さず、昨日の checkin を問い合わせない", async () => {
  const calls: string[] = [];
  const repo = makeFakeRepo(
    pairWorld({
      checkins: {
        "user-a|2026-06-10": { photoPath: null },
        "user-b|2026-06-10": { photoPath: null },
      },
      streakDays: days("2026-06-08", "2026-06-09", "2026-06-10"),
    }),
    calls,
  );
  const snapshot = await loadSnapshotForUser(repo, {
    userId: "user-a",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(
    snapshot.plantGrownDays,
    3,
    "行 3 本 = 3 回(昨日を二重に数えない)",
  );
  assertEquals(snapshot.streakCurrent, 3);
  assertEquals(
    calls.filter((c) => c.endsWith("|2026-06-10")),
    [],
    "昨日の行がある日は、昨日の checkin を引かない(余計な問い合わせをしない)",
  );
  // 今日(6/11)の checkin は自分・相手の2回だけ
  assertEquals(calls.sort(), ["user-a|2026-06-11", "user-b|2026-06-11"]);
});

Deno.test("昨日の仮判定: 昨日の行が無いときだけ、昨日の checkin を2回(自分・相手)引く", async () => {
  const calls: string[] = [];
  const repo = makeFakeRepo(
    pairWorld({
      checkins: {
        "user-a|2026-06-10": { photoPath: null },
        "user-b|2026-06-10": { photoPath: null },
      },
      streakDays: days("2026-06-08", "2026-06-09"),
    }),
    calls,
  );
  await loadSnapshotForUser(repo, { userId: "user-a", now: AFTER_MIDNIGHT });
  assertEquals(
    calls.filter((c) => c.endsWith("|2026-06-10")).sort(),
    ["user-a|2026-06-10", "user-b|2026-06-10"],
  );
});

Deno.test("昨日の仮判定: 昨日がペア成立前なら対象外(問い合わせもしない)・成立当日なら対象", async () => {
  // 成立日 = 今日(6/11)。昨日(6/10)は成立前 → 両者がソロ期間にチェックインしていても数えない
  const calls: string[] = [];
  const before = makeFakeRepo(
    pairWorld({
      pair: {
        pairId: "pair-1",
        startedOn: "2026-06-11",
        memberIds: ["user-a", "user-b"],
      },
      checkins: {
        "user-a|2026-06-10": { photoPath: null },
        "user-b|2026-06-10": { photoPath: null },
      },
    }),
    calls,
  );
  const s1 = await loadSnapshotForUser(before, {
    userId: "user-a",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(s1.plantGrownDays, 0);
  assertEquals(s1.streakCurrent, 0);
  assertEquals(calls.filter((c) => c.endsWith("|2026-06-10")), []);

  // 成立日 = 昨日(6/10)。昨日は対象で、両者チェックイン済みなら数える
  const onStart = makeFakeRepo(pairWorld({
    pair: {
      pairId: "pair-1",
      startedOn: "2026-06-10",
      memberIds: ["user-a", "user-b"],
    },
    checkins: {
      "user-a|2026-06-10": { photoPath: null },
      "user-b|2026-06-10": { photoPath: null },
    },
  }));
  const s2 = await loadSnapshotForUser(onStart, {
    userId: "user-a",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(s2.plantGrownDays, 1);
  assertEquals(s2.plantStage, 1, "成立日の1回目でふたば");
  assertEquals(s2.streakCurrent, 1);
});

// ---- 窓の外では行だけを信じる(close-day の後に届いた遅れた checkin を数えない) ----

Deno.test("昨日の仮判定: 窓の境目 — JST 0:59:59 は昨日を数え、1:00:00 は数えない", async () => {
  // 昨日(6/10)の行は無く、2人とも 6/10 にチェックイン済み。確定済みの行は 6/9 まで
  const world = pairWorld({
    checkins: {
      "user-a|2026-06-10": { photoPath: null },
      "user-b|2026-06-10": { photoPath: null },
    },
    streakDays: days("2026-06-08", "2026-06-09"),
  });
  const inside = await loadSnapshotForUser(makeFakeRepo(world), {
    userId: "user-a",
    now: new Date("2026-06-10T15:59:59Z"), // JST 6/11 0:59:59
  });
  assertEquals(inside.plantGrownDays, 3, "窓の中 = 昨日を数える(2 + 1)");
  assertEquals(inside.streakCurrent, 3);

  const calls: string[] = [];
  const outside = await loadSnapshotForUser(makeFakeRepo(world, calls), {
    userId: "user-a",
    now: new Date("2026-06-10T16:00:00Z"), // JST 6/11 1:00:00
  });
  assertEquals(outside.plantGrownDays, 2, "窓の外 = 行だけ(昨日は数えない)");
  assertEquals(outside.streakCurrent, 0, "昨日の行が無い = 途切れ");
  assertEquals(
    calls.filter((c) => c.endsWith("|2026-06-10")),
    [],
    "窓の外では昨日の checkin を問い合わせもしない",
  );
});

Deno.test("昨日の仮判定: close-day の後に届いた遅れたチェックイン(リセット済みの昨日)は、その日いっぱい数えない", async () => {
  // 6/7 に A だけチェックイン → 6/8 0:10 の close-day でリセット(行なし)→ 6/8 8:00 に B の遅れた 6/7 付けが届いた状態。
  // 6/1〜6/6 の 6 回(めばえ)。窓(6/8 1:00)の後は、行が無い 6/7 を「ふたり達成」と見せない
  const world = pairWorld({
    pair: {
      pairId: "pair-1",
      startedOn: "2026-06-01",
      memberIds: ["user-a", "user-b"],
    },
    checkins: {
      "user-a|2026-06-07": { photoPath: null },
      "user-b|2026-06-07": { photoPath: null },
    },
    streakDays: days(
      "2026-06-01",
      "2026-06-02",
      "2026-06-03",
      "2026-06-04",
      "2026-06-05",
      "2026-06-06",
    ),
  });
  const times = {
    "6/8 08:00": "2026-06-07T23:00:00Z",
    "6/8 23:59": "2026-06-08T14:59:00Z",
    "6/9 12:00": "2026-06-09T03:00:00Z",
    "6/10 12:00": "2026-06-10T03:00:00Z",
  };
  for (const [label, iso] of Object.entries(times)) {
    const snapshot = await loadSnapshotForUser(makeFakeRepo(world), {
      userId: "user-a",
      now: new Date(iso),
    });
    assertEquals(snapshot.plantGrownDays, 6, `${label}: 回数は 6 のまま`);
    assertEquals(
      snapshot.plantStage,
      2,
      `${label}: めばえのまま(上がって戻らない)`,
    );
    assertEquals(snapshot.streakCurrent, 0, `${label}: 6/7 はリセット済み`);
  }
});

Deno.test("todayLocalOverride: 確定前の日は使い、その前日(確定済み)は仮判定しない", async () => {
  // JST 6/11 0:30。クライアントはまだ 6/10 のつもり(override = 6/10)。6/10 は close-day(0:10)が済んだ頃で
  // 窓(6/11 1:00)の中なので override を使う。その前日 6/9 は昨日の昼に確定済み(行が無ければリセット)
  // なので、2人とも 6/9 にチェックインしていても数えない
  const repo = makeFakeRepo(pairWorld({
    checkins: {
      "user-a|2026-06-09": { photoPath: null },
      "user-b|2026-06-09": { photoPath: null },
      "user-a|2026-06-10": { photoPath: null },
    },
    streakDays: days("2026-06-07", "2026-06-08"),
  }));
  const snapshot = await loadSnapshotForUser(repo, {
    userId: "user-a",
    now: new Date("2026-06-10T15:30:00Z"),
    todayLocalOverride: "2026-06-10",
  });
  assertEquals(snapshot.todayMeDone, true, "override の 6/10 を今日として読む");
  assertEquals(snapshot.todayPartnerDone, false);
  assertEquals(snapshot.plantGrownDays, 2, "6/9(行なし)は数えない");
  assertEquals(snapshot.streakCurrent, 0);
});

Deno.test("todayLocalOverride: 確定を過ぎた日は捨てて本当の今日を使う(遅れて届いた昨日付けの checkin に先取りの +1 を出さない)", async () => {
  // JST 6/11 12:00。キューから届いた B の 6/10 付けの checkin(override = 6/10)。6/10 は close-day で確定済み
  // (A だけだったのでリセット = 行なし)。override を使うと「今日 6/10 はふたり達成」の先取り +1 が出て、
  // 次の GET /snapshot(本当の今日 6/11)で消える → 捨てて本当の今日で組み立てる
  const world = pairWorld({
    checkins: {
      "user-a|2026-06-10": { photoPath: null },
      "user-b|2026-06-10": { photoPath: null }, // 遅れて届いた分
    },
    streakDays: days(
      "2026-06-02",
      "2026-06-03",
      "2026-06-04",
      "2026-06-05",
      "2026-06-06",
      "2026-06-07",
    ),
  });
  const now = new Date("2026-06-11T03:00:00Z");
  const withStaleOverride = await loadSnapshotForUser(makeFakeRepo(world), {
    userId: "user-b",
    now,
    todayLocalOverride: "2026-06-10",
  });
  const plain = await loadSnapshotForUser(makeFakeRepo(world), {
    userId: "user-b",
    now,
  });
  assertEquals(
    withStaleOverride,
    plain,
    "確定済みの override は無かったことになる",
  );
  assertEquals(withStaleOverride.todayMeDone, false, "本当の今日 6/11 はまだ");
  assertEquals(
    withStaleOverride.plantGrownDays,
    6,
    "先取りの +1 も昨日の仮判定も無い",
  );
  assertEquals(withStaleOverride.plantStage, 2);
  assertEquals(withStaleOverride.streakCurrent, 0);
});

Deno.test("todayLocalOverride: 時計が進んだ端末(翌日付け)は使い、サーバーの今日を「昨日」として仮判定する", async () => {
  // JST 6/10 23:59:30。端末の時計が少し進んでいて、checkin の dateLocal が 6/11(override = 6/11)。
  // 実効の今日 = 6/11 の窓(6/11 1:00)の中なので、昨日 = 6/10(サーバーの今日。まだ未確定)を仮判定する。
  // 6/10 は2人ともチェックイン済み → 数える
  const repo = makeFakeRepo(pairWorld({
    checkins: {
      "user-a|2026-06-10": { photoPath: null },
      "user-b|2026-06-10": { photoPath: null },
      "user-a|2026-06-11": { photoPath: null }, // いま入れたチェックイン
    },
    streakDays: days("2026-06-08", "2026-06-09"),
  }));
  const snapshot = await loadSnapshotForUser(repo, {
    userId: "user-a",
    now: new Date("2026-06-10T14:59:30Z"),
    todayLocalOverride: "2026-06-11",
  });
  assertEquals(snapshot.todayMeDone, true, "override の 6/11 を今日として読む");
  assertEquals(snapshot.todayPartnerDone, false);
  assertEquals(snapshot.plantGrownDays, 3, "6/8・6/9 + 仮判定の 6/10");
  assertEquals(snapshot.streakCurrent, 3);
});

Deno.test("昨日の仮判定: ソロは問い合わせない(ペアが無い)", async () => {
  const calls: string[] = [];
  const repo = makeFakeRepo(
    {
      users: [userA],
      promises: {},
      pair: null,
      checkins: { "user-a|2026-06-10": { photoPath: null } },
      streakDays: [],
      plant: null,
    },
    calls,
  );
  const snapshot = await loadSnapshotForUser(repo, {
    userId: "user-a",
    now: AFTER_MIDNIGHT,
  });
  assertEquals(snapshot.pairId, null);
  assertEquals(calls, ["user-a|2026-06-11"], "今日の自分の checkin だけ");
});
