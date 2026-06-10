// core_test.ts — checkin-cancel/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.3(checkin-cancel)/ §4(サイレントpush = content-available: 1)
//        / REQUIREMENTS §3.4「取り消しは当日中のみ可」

import {
  type CheckinCancelRepo,
  handleCheckinCancel,
  type Pusher,
} from "./core.ts";
import type {
  PairSnapshot,
  SnapshotCheckinRow,
  SnapshotPairRow,
  SnapshotPlantRow,
  SnapshotPromiseRow,
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

// ---- fake repo / pusher ----

interface World {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>; // userId → 現役の約束
  pair:
    | { pairId: string; startedOn: string; memberIds: [string, string] }
    | null;
  checkins: Map<string, { photoPath: string | null }>; // key: `${userId}|${dateLocal}`
  streakDays: StreakDayRecord[];
  plant: SnapshotPlantRow | null;
}

function makeRepo(world: World): CheckinCancelRepo {
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
    getCheckin: (id, dateLocal): Promise<SnapshotCheckinRow | null> =>
      Promise.resolve(world.checkins.get(`${id}|${dateLocal}`) ?? null),
    listStreakDays: () => Promise.resolve([...world.streakDays]),
    getPlant: () => Promise.resolve(world.plant),
    deleteCheckin: (params) => {
      const key = `${params.userId}|${params.dateLocal}`;
      const deleted = world.checkins.delete(key);
      return Promise.resolve({ deleted });
    },
  };
}

interface SentPush {
  deviceToken: string;
  payload: Record<string, unknown>;
  opts?: { pushType?: "alert" | "background"; priority?: number };
}

function makePusher(
  behavior: "ok" | "fail" | "throw" = "ok",
): { sent: SentPush[]; pusher: Pusher } {
  const sent: SentPush[] = [];
  return {
    sent,
    pusher: {
      send: (deviceToken, payload, opts) => {
        sent.push({ deviceToken, payload, opts });
        if (behavior === "throw") {
          return Promise.reject(new Error("apns down"));
        }
        return Promise.resolve({ ok: behavior === "ok" });
      },
    },
  };
}

// ---- 共通フィクスチャ(checkin/core_test.ts と同じ世界) ----

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

const bothDays = (...dates: string[]): StreakDayRecord[] =>
  dates.map((d) => ({ dateLocal: d, kind: "both" as const }));

/** JST 2026-06-10 12:00。todayLocal = 2026-06-10 */
const NOW = new Date("2026-06-10T03:00:00Z");
const TODAY = "2026-06-10";

function makeWorld(overrides: Partial<World> = {}): World {
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
    checkins: new Map(),
    streakDays: bothDays(
      "2026-06-05",
      "2026-06-06",
      "2026-06-07",
      "2026-06-08",
      "2026-06-09",
    ),
    plant: { grownDays: 13, name: "みどり" },
    ...overrides,
  };
}

function deps(world: World, pusher: Pusher) {
  return { repo: makeRepo(world), pusher, now: () => NOW };
}

// ---- 本体テスト ----

Deno.test("checkin-cancel: 当日削除成功 — 削除後snapshot返却+相手へサイレントpush(snapshot同梱)", async () => {
  const world = makeWorld();
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
  const { sent, pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyCanceled, false);
  assertEquals(world.checkins.has(`user-a|${TODAY}`), false, "行が消えている");

  const expectedMine: PairSnapshot = {
    schemaVersion: 1,
    pairId: "pair-1",
    updatedAt: "2026-06-10T03:00:00.000Z",
    streakCurrent: 5,
    streakBest: 5,
    todayMeDone: false,
    todayPartnerDone: false,
    myPromiseTitle: "筋トレ",
    myPromiseEmoji: "💪",
    partnerName: "ゆうき",
    partnerPromiseTitle: "ランニング",
    partnerPromiseEmoji: "🏃",
    plantStage: 2,
    plantMood: "normal",
    plantName: "みどり",
    hasPartnerPhotoToday: false,
  };
  assertEquals(result.body.snapshot, expectedMine, "自分用 snapshot(削除後)");

  // push: 受信者(B)視点の snapshot を同梱したサイレントプッシュ(DESIGN §4)
  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-b");
  const expectedPartner: PairSnapshot = {
    ...expectedMine,
    myPromiseTitle: "ランニング",
    myPromiseEmoji: "🏃",
    partnerName: "あきら",
    partnerPromiseTitle: "筋トレ",
    partnerPromiseEmoji: "💪",
  };
  assertEquals(sent[0].payload, {
    aps: { "content-available": 1 },
    lien: { type: "pair_update", snapshot: expectedPartner },
  });
  assertEquals(
    sent[0].opts,
    { pushType: "background", priority: 5 },
    "サイレントは apns-push-type: background / priority 5",
  );
});

Deno.test("checkin-cancel: 両者完了からの取消 — プレビュー+1とhappyが解除され相手視点はfidgetに戻る", async () => {
  const world = makeWorld();
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
  world.checkins.set(`user-b|${TODAY}`, { photoPath: null });
  const { sent, pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  const s = result.body.snapshot;
  assertEquals(s.todayMeDone, false);
  assertEquals(s.todayPartnerDone, true);
  assertEquals(s.streakCurrent, 5, "両者達成プレビュー(6)が確定値5に戻る");
  assertEquals(s.plantStage, 2, "プレビュー昇格(14日)が13日に戻り双葉のまま");
  assertEquals(s.plantMood, "fidget", "片方未完のそわそわに戻る");

  assertEquals(sent.length, 1);
  const partnerView = (sent[0].payload as { lien: { snapshot: PairSnapshot } })
    .lien.snapshot;
  assertEquals(partnerView.todayMeDone, true, "B 自身は完了のまま");
  assertEquals(partnerView.todayPartnerDone, false, "B 視点で相手(A)は未完に");
  assertEquals(partnerView.streakCurrent, 5);
  assertEquals(partnerView.plantMood, "fidget");
});

Deno.test("checkin-cancel: 過去日・未来日・形式不正は 400(取り消しは当日中のみ — §3.4)", async () => {
  const world = makeWorld();
  world.checkins.set("user-a|2026-06-09", { photoPath: null });
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  const past = await handleCheckinCancel(d, {
    userId: "user-a",
    dateLocal: "2026-06-09",
  });
  assertEquals(past.status, 400, "昨日(過去日)は拒否");
  if (past.status !== 400) throw new Error("unreachable");
  assertEquals(past.body.error, "date_local_not_today");
  assertEquals(
    world.checkins.has("user-a|2026-06-09"),
    true,
    "過去日の行は消えない",
  );

  const future = await handleCheckinCancel(d, {
    userId: "user-a",
    dateLocal: "2026-06-11",
  });
  assertEquals(future.status, 400, "明日(未来日)も拒否");
  if (future.status !== 400) throw new Error("unreachable");
  assertEquals(future.body.error, "date_local_not_today");

  const malformed = await handleCheckinCancel(d, {
    userId: "user-a",
    dateLocal: "2026-6-10",
  });
  assertEquals(malformed.status, 400);
  if (malformed.status !== 400) throw new Error("unreachable");
  assertEquals(malformed.body.error, "invalid_date_local");

  assertEquals(sent.length, 0, "拒否時は push しない");
});

Deno.test("checkin-cancel: 該当checkinが無い日も 200 冪等(alreadyCanceled: true)・push なし", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200, "削除済み扱いで成功(冪等 — DESIGN §5.5)");
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyCanceled, true);
  assertEquals(result.body.snapshot.todayMeDone, false);
  assertEquals(sent.length, 0, "状態が変わっていないので push しない");
});

Deno.test("checkin-cancel: 取消→再取消のリトライでも push は1回だけ", async () => {
  const world = makeWorld();
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  const first = await handleCheckinCancel(d, {
    userId: "user-a",
    dateLocal: TODAY,
  });
  const second = await handleCheckinCancel(d, {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(first.status, 200);
  assertEquals(second.status, 200);
  if (first.status !== 200 || second.status !== 200) {
    throw new Error("unreachable");
  }
  assertEquals(first.body.alreadyCanceled, false);
  assertEquals(second.body.alreadyCanceled, true);
  assertEquals(
    second.body.snapshot,
    first.body.snapshot,
    "snapshot は同じ状態を返す",
  );
  assertEquals(sent.length, 1, "サイレント push を二重発火させない");
});

Deno.test("checkin-cancel: ソロ状態(未ペア)でも自分のcheckin削除は可・push なし", async () => {
  const world = makeWorld({ pair: null, streakDays: [], plant: null });
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
  const { sent, pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyCanceled, false);
  assertEquals(world.checkins.has(`user-a|${TODAY}`), false);
  const expected: PairSnapshot = {
    schemaVersion: 1,
    pairId: null,
    updatedAt: "2026-06-10T03:00:00.000Z",
    streakCurrent: 0,
    streakBest: 0,
    todayMeDone: false,
    todayPartnerDone: false,
    myPromiseTitle: "筋トレ",
    myPromiseEmoji: "💪",
    partnerName: null,
    partnerPromiseTitle: null,
    partnerPromiseEmoji: null,
    plantStage: 0,
    plantMood: "normal",
    plantName: null,
    hasPartnerPhotoToday: false,
  };
  assertEquals(result.body.snapshot, expected, "ソロ snapshot");
  assertEquals(sent.length, 0, "ソロは push 先がない");
});

Deno.test("checkin-cancel: ユーザー不在は 404", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-zzz",
    dateLocal: TODAY,
  });
  assertEquals(result.status, 404);
  if (result.status !== 404) throw new Error("unreachable");
  assertEquals(result.body.error, "user_not_found");
  assertEquals(sent.length, 0);
});

Deno.test("checkin-cancel: 相手に push_token が無ければ push せず成功", async () => {
  const noTokenB = { ...userB, pushToken: null };
  const world = makeWorld({ users: [userA, noTokenB] });
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
  const { sent, pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });
  assertEquals(result.status, 200);
  assertEquals(sent.length, 0);
});

Deno.test("checkin-cancel: push 失敗(ok:false / throw)でも処理は成功扱い(サイレントはフォールバック — DESIGN §4)", async () => {
  for (const behavior of ["fail", "throw"] as const) {
    const world = makeWorld();
    world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
    const { sent, pusher } = makePusher(behavior);
    const result = await handleCheckinCancel(deps(world, pusher), {
      userId: "user-a",
      dateLocal: TODAY,
    });
    assertEquals(result.status, 200, `pusher=${behavior}`);
    if (result.status !== 200) throw new Error("unreachable");
    assertEquals(result.body.alreadyCanceled, false);
    assertEquals(sent.length, 1, "送信自体は試みる");
    assertEquals(world.checkins.has(`user-a|${TODAY}`), false, "削除は成立");
  }
});

Deno.test("checkin-cancel: 約束をアーカイブ済みでも当日checkinの取消は可", async () => {
  // checkin と違い削除に現役の約束は不要(誤タップ対応を約束の有無で塞がない)
  const world = makeWorld({ promises: {} });
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
  const { sent, pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyCanceled, false);
  assertEquals(result.body.snapshot.myPromiseTitle, null);
  assertEquals(sent.length, 1, "ペアは健在なのでサイレント push は送る");
});
