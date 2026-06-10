// snapshot_test.ts — snapshot.ts の deno test(外部モジュール非依存・ネットワーク不要)
// 正本: docs/DESIGN.md §3.4(スキーマ)/ §5.4(プレビュー)/ docs/REQUIREMENTS.md §3.9(植物)

import {
  addDaysLocal,
  buildPairSnapshot,
  buildSoloSnapshot,
  countConsecutiveMissedDays,
  dateLocalInTimeZone,
  derivePlantMood,
  derivePlantStage,
  loadSnapshotForUser,
  type PairSnapshot,
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

// ---- 植物: 成長段階(REQUIREMENTS §3.9: 0種/3芽/7双葉/14若葉/30つぼみ/60開花) ----

Deno.test("derivePlantStage: しきい値の全境界", () => {
  assertEquals(derivePlantStage(0), 0, "0日=種");
  assertEquals(derivePlantStage(2), 0, "2日=種のまま");
  assertEquals(derivePlantStage(3), 1, "3日=芽");
  assertEquals(derivePlantStage(6), 1, "6日=芽のまま");
  assertEquals(derivePlantStage(7), 2, "7日=双葉");
  assertEquals(derivePlantStage(13), 2, "13日=双葉のまま");
  assertEquals(derivePlantStage(14), 3, "14日=若葉");
  assertEquals(derivePlantStage(29), 3, "29日=若葉のまま");
  assertEquals(derivePlantStage(30), 4, "30日=つぼみ");
  assertEquals(derivePlantStage(59), 4, "59日=つぼみのまま");
  assertEquals(derivePlantStage(60), 5, "60日=開花");
  assertEquals(derivePlantStage(365), 5, "それ以上も開花(後退しない)");
});

Deno.test("derivePlantStage: 不正値は throw", () => {
  assertThrows(() => derivePlantStage(-1));
  assertThrows(() => derivePlantStage(1.5));
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

Deno.test("derivePlantMood: 2日連続未達成+今日も両者未完 = sad", () => {
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

const days = (...dates: string[]): StreakDayRecord[] =>
  dates.map((d) => ({ dateLocal: d, kind: "both" as const }));

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

// ---- snapshot 組み立て(DESIGN §3.4。キー名一字一句一致) ----

/** DESIGN §3.4 schemaVersion=1 の全16キー */
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
  "plantMood",
  "plantName",
  "hasPartnerPhotoToday",
].sort();

function baseInput() {
  return {
    pairId: "pair-1",
    updatedAtIso: "2026-06-10T03:00:00.000Z",
    todayLocal: "2026-06-10",
    startedOn: "2026-06-01",
    streakDays: days(
      "2026-06-05",
      "2026-06-06",
      "2026-06-07",
      "2026-06-08",
      "2026-06-09",
    ),
    todayMeDone: true,
    todayPartnerDone: false,
    myPromise: { title: "筋トレ", emoji: "💪" },
    partnerName: "ゆうき",
    partnerPromise: { title: "ランニング", emoji: "🏃" },
    plantGrownDays: 13,
    plantName: "みどり",
    hasPartnerPhotoToday: false,
  };
}

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

Deno.test("buildPairSnapshot: 自分だけ完了 = 確定ストリーク表示+fidget", () => {
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
    plantStage: 2, // 累計13日=双葉
    plantMood: "fidget",
    plantName: "みどり",
    hasPartnerPhotoToday: false,
  };
  assertEquals(snapshot, expected);
});

Deno.test("buildPairSnapshot: 両者完了 = プレビュー+1(streak 6・累計14日で若葉昇格・happy)", () => {
  const snapshot = buildPairSnapshot({
    ...baseInput(),
    todayPartnerDone: true,
    hasPartnerPhotoToday: true,
  });
  assertEquals(snapshot.streakCurrent, 6, "確定5+今日両者完了で6");
  assertEquals(snapshot.streakBest, 6, "best も現在値を下回らない");
  assertEquals(snapshot.plantStage, 3, "13+1=14日で若葉");
  assertEquals(snapshot.plantMood, "happy");
  assertEquals(snapshot.hasPartnerPhotoToday, true);
});

Deno.test("buildPairSnapshot: 2日途切れ+今日未着手 = current 0・best は財産として残る・sad", () => {
  const snapshot = buildPairSnapshot({
    ...baseInput(),
    streakDays: days("2026-06-05", "2026-06-06", "2026-06-07"),
    todayMeDone: false,
    todayPartnerDone: false,
  });
  assertEquals(snapshot.streakCurrent, 0);
  assertEquals(snapshot.streakBest, 3, "最高記録は維持(REQUIREMENTS §3.5)");
  assertEquals(snapshot.plantMood, "sad");
  assertEquals(snapshot.plantStage, 2, "枯れない・後退しない(13日のまま双葉)");
});

Deno.test("buildSoloSnapshot: ソロ状態は pairId null・土だけ・約束は自分のもののみ", () => {
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
    plantMood: "normal",
    plantName: null,
    hasPartnerPhotoToday: false,
  };
  assertEquals(snapshot, expected);
});

// ---- loadSnapshotForUser(fake repo で受信者視点の組み立てを検証) ----

function makeFakeRepo(world: {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>;
  pair:
    | { pairId: string; startedOn: string; memberIds: [string, string] }
    | null;
  checkins: Record<string, SnapshotCheckinRow>; // key: `${userId}|${dateLocal}`
  streakDays: StreakDayRecord[];
  plant: SnapshotPlantRow | null;
}): SnapshotRepo {
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
    getCheckin: (id, dateLocal) =>
      Promise.resolve(world.checkins[`${id}|${dateLocal}`] ?? null),
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

Deno.test("loadSnapshotForUser: 受信者視点で me/partner が組み上がる(反転しない)", async () => {
  const repo = makeFakeRepo({
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
    checkins: {
      "user-a|2026-06-10": { photoPath: "pairs/pair-1/2026-06-10/a.jpg" },
    },
    streakDays: days("2026-06-08", "2026-06-09"),
    plant: { grownDays: 4, name: "みどり" },
  });
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
  assertEquals(forB.plantStage, 1, "累計4日=芽");
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
  assertEquals(snapshot.todayMeDone, false);
  assertEquals(snapshot.partnerName, null);
});

Deno.test("loadSnapshotForUser: todayLocalOverride が「今日」を上書きする", async () => {
  const repo = makeFakeRepo({
    users: [userA, userB],
    promises: {},
    pair: {
      pairId: "pair-1",
      startedOn: "2026-06-01",
      memberIds: ["user-a", "user-b"],
    },
    checkins: { "user-a|2026-06-10": { photoPath: null } },
    streakDays: [],
    plant: null,
  });
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
