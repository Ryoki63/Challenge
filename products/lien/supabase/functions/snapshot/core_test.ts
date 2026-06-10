// core_test.ts — snapshot/core.ts の deno test(リポジトリはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.3「snapshot: 自分視点の PairSnapshot(自己修復用)」

import { handleSnapshot } from "./core.ts";
import type {
  SnapshotPairRow,
  SnapshotPlantRow,
  SnapshotPromiseRow,
  SnapshotRepo,
  SnapshotUserRow,
} from "../_shared/snapshot.ts";
import type { StreakDayRecord } from "../_shared/streak.ts";

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

// ---- fake repo ----

interface World {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>;
  pair:
    | { pairId: string; startedOn: string; memberIds: [string, string] }
    | null;
  checkins: Record<string, { photoPath: string | null }>; // `${userId}|${dateLocal}`
  streakDays: StreakDayRecord[];
  plant: SnapshotPlantRow | null;
}

function makeRepo(world: World): SnapshotRepo {
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

/** JST 2026-06-10 12:00 → todayLocal = 2026-06-10 */
const NOW = new Date("2026-06-10T03:00:00Z");

// ---- テスト ----

Deno.test("snapshot: 自分視点で返る(相手完了済み・写真あり → 自分は未完)", async () => {
  const repo = makeRepo({
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
    streakDays: [
      { dateLocal: "2026-06-08", kind: "both" },
      { dateLocal: "2026-06-09", kind: "ticket" },
    ],
    plant: { grownDays: 7, name: "みどり" },
  });

  const result = await handleSnapshot({ repo, now: () => NOW }, {
    userId: "user-b",
  });
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  const s = result.body.snapshot;
  assertEquals(s.pairId, "pair-1");
  assertEquals(s.todayMeDone, false, "B 自身は未完");
  assertEquals(s.todayPartnerDone, true, "相手(A)は完了済み");
  assertEquals(s.myPromiseTitle, "ランニング");
  assertEquals(s.partnerName, "あきら");
  assertEquals(s.partnerPromiseTitle, "筋トレ");
  assertEquals(s.hasPartnerPhotoToday, true);
  assertEquals(s.streakCurrent, 2, "ticket の日も継続日(DESIGN §5.4)");
  assertEquals(s.plantStage, 2, "累計7日=双葉");
  assertEquals(s.plantMood, "fidget");
  assertEquals(s.updatedAt, "2026-06-10T03:00:00.000Z");
});

Deno.test("snapshot: ソロ状態は pairId null・土だけ", async () => {
  const repo = makeRepo({
    users: [userA],
    promises: { "user-a": { id: "prom-a", title: "筋トレ", emoji: "💪" } },
    pair: null,
    checkins: { "user-a|2026-06-10": { photoPath: null } },
    streakDays: [],
    plant: null,
  });
  const result = await handleSnapshot({ repo, now: () => NOW }, {
    userId: "user-a",
  });
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.snapshot.pairId, null);
  assertEquals(result.body.snapshot.todayMeDone, true);
  assertEquals(result.body.snapshot.plantStage, 0);
  assertEquals(result.body.snapshot.plantMood, "normal");
});

Deno.test("snapshot: ユーザー不在は 404", async () => {
  const repo = makeRepo({
    users: [],
    promises: {},
    pair: null,
    checkins: {},
    streakDays: [],
    plant: null,
  });
  const result = await handleSnapshot({ repo, now: () => NOW }, {
    userId: "user-zzz",
  });
  assertEquals(result.status, 404);
  if (result.status !== 404) throw new Error("unreachable");
  assertEquals(result.body.error, "user_not_found");
});

Deno.test("snapshot: 日付はユーザーTZで判定(JST 翌日 0:05 には今日扱いが切り替わる)", async () => {
  const repo = makeRepo({
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
  // UTC 15:05 = JST 2026-06-11 0:05 → 06-10 のチェックインは「今日」ではない
  const result = await handleSnapshot(
    { repo, now: () => new Date("2026-06-10T15:05:00Z") },
    { userId: "user-a" },
  );
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.snapshot.todayMeDone, false);
});
