// core_test.ts — react/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/REQUIREMENTS.md §3.8(リアクション)/ docs/DESIGN.md §5.3

import {
  handleReact,
  type Pusher,
  type ReactCheckinRow,
  type ReactRepo,
} from "./core.ts";
import type {
  SnapshotCheckinRow,
  SnapshotPairRow,
  SnapshotPlantRow,
  SnapshotPromiseRow,
  SnapshotUserRow,
} from "../_shared/snapshot.ts";
import type { StreakDayRecord } from "../_shared/streak.ts";

// ---- 自作 assert ヘルパ(外部モジュールを使わない) ----

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  if (!Object.is(actual, expected)) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${
        JSON.stringify(actual)
      }\n  expected: ${JSON.stringify(expected)}`,
    );
  }
}

function assert(cond: boolean, msg = ""): void {
  if (!cond) throw new Error(`assert failed: ${msg}`);
}

// ---- fake repo / pusher ----

interface ReactionRecord {
  checkinId: string;
  fromUserId: string;
  stamp: string;
}

interface World {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>;
  pair:
    | { pairId: string; startedOn: string; memberIds: [string, string] }
    | null;
  checkins: Map<string, { photoPath: string | null }>; // key: `${userId}|${dateLocal}`
  checkinsById: Map<string, ReactCheckinRow>; // key: checkinId
  streakDays: StreakDayRecord[];
  plant: SnapshotPlantRow | null;
  reactions: ReactionRecord[];
}

function makeRepo(world: World): ReactRepo {
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
    getCheckinById: (checkinId) =>
      Promise.resolve(world.checkinsById.get(checkinId) ?? null),
    getReaction: (params) => {
      const found = world.reactions.find(
        (r) =>
          r.checkinId === params.checkinId &&
          r.fromUserId === params.fromUserId,
      );
      return Promise.resolve(found ? { stamp: found.stamp } : null);
    },
    upsertReaction: (params) => {
      const idx = world.reactions.findIndex(
        (r) =>
          r.checkinId === params.checkinId &&
          r.fromUserId === params.fromUserId,
      );
      if (idx === -1) {
        world.reactions.push({ ...params });
      } else {
        world.reactions[idx].stamp = params.stamp;
      }
      return Promise.resolve();
    },
  };
}

interface SentPush {
  deviceToken: string;
  payload: Record<string, unknown>;
}

function makePusher(
  behavior: "ok" | "fail" | "throw" = "ok",
): { sent: SentPush[]; pusher: Pusher } {
  const sent: SentPush[] = [];
  return {
    sent,
    pusher: {
      send: (deviceToken, payload) => {
        sent.push({ deviceToken, payload });
        if (behavior === "throw") {
          return Promise.reject(new Error("apns down"));
        }
        return Promise.resolve({ ok: behavior === "ok" });
      },
    },
  };
}

// ---- 共通フィクスチャ ----

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

/** JST 2026-06-10 12:00 */
const NOW = new Date("2026-06-10T03:00:00Z");

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
    checkinsById: new Map([
      ["checkin-b-1", { userId: "user-b" }],
      ["checkin-a-1", { userId: "user-a" }],
    ]),
    streakDays: bothDays("2026-06-08", "2026-06-09"),
    plant: { grownDays: 2, name: null },
    reactions: [],
    ...overrides,
  };
}

function deps(world: World, pusher: Pusher) {
  return { repo: makeRepo(world), pusher, now: () => NOW };
}

// ---- テスト ----

Deno.test("react: 新規リアクション — 200 changed:true、相手へ可視push(自分の名前名義)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher("ok");
  const result = await handleReact(deps(world, pusher), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "❤️",
  });
  assertEquals(result.status, 200);
  if (result.status === 200) assertEquals(result.body.changed, true);
  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-b");
  const payload = sent[0].payload as {
    aps: { alert: { title: string; body: string } };
    lien: { type: string };
  };
  // 自分の名前名義(REQUIREMENTS §3.8。リアクションした user-a=あきら の名前で届く)
  assertEquals(payload.aps.alert.title, "あきら");
  assert(payload.aps.alert.body.includes("❤️"));
  assertEquals(payload.lien.type, "reaction");
});

Deno.test("react: 同一スタンプの再送は冪等(200 changed:false)で再pushしない", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("ok");
  await handleReact(deps(world, pusher), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "❤️",
  });
  const { sent: sent2, pusher: pusher2 } = makePusher("ok");
  // 2回目は同じ pusher インスタンスでなく新規カウントするため sent2 で検証
  const result = await handleReact({
    repo: makeRepo(world),
    pusher: pusher2,
    now: () => NOW,
  }, {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "❤️",
  });
  assertEquals(result.status, 200);
  if (result.status === 200) assertEquals(result.body.changed, false);
  assertEquals(sent2.length, 0, "同一スタンプの再送はpushしない");
});

Deno.test("react: 別スタンプへの変更は200 changed:true・再push(新しいスタンプの文言)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("ok");
  await handleReact(deps(world, pusher), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "❤️",
  });
  const { sent: sent2, pusher: pusher2 } = makePusher("ok");
  const result = await handleReact({
    repo: makeRepo(world),
    pusher: pusher2,
    now: () => NOW,
  }, {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "🔥",
  });
  assertEquals(result.status, 200);
  if (result.status === 200) assertEquals(result.body.changed, true);
  assertEquals(sent2.length, 1, "スタンプ変更時は再pushする");
  const payload = sent2[0].payload as { aps: { alert: { body: string } } };
  assert(payload.aps.alert.body.includes("🔥"));
  assertEquals(
    world.reactions.length,
    1,
    "行は更新であり追加ではない(UNIQUE制約と一致)",
  );
  assertEquals(world.reactions[0].stamp, "🔥");
});

Deno.test("react: 自分自身のチェックインには403 not_partner", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("ok");
  const result = await handleReact(deps(world, pusher), {
    userId: "user-a",
    checkinId: "checkin-a-1",
    stamp: "❤️",
  });
  assertEquals(result.status, 403);
  if (result.status === 403) assertEquals(result.body.error, "not_partner");
});

Deno.test("react: 存在しないチェックインは404", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("ok");
  const result = await handleReact(deps(world, pusher), {
    userId: "user-a",
    checkinId: "ghost-checkin",
    stamp: "❤️",
  });
  assertEquals(result.status, 404);
  if (result.status === 404) {
    assertEquals(result.body.error, "checkin_not_found");
  }
});

Deno.test("react: 語彙外のスタンプは400 invalid_stamp(自由入力は入れない方針 — §3.8)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("ok");
  const result = await handleReact(deps(world, pusher), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "😡",
  });
  assertEquals(result.status, 400);
  if (result.status === 400) assertEquals(result.body.error, "invalid_stamp");
  assertEquals(world.reactions.length, 0);
});

Deno.test("react: ソロ状態(ペア無し)は409 no_pair", async () => {
  const world = makeWorld({ pair: null });
  const { pusher } = makePusher("ok");
  const result = await handleReact(deps(world, pusher), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "❤️",
  });
  assertEquals(result.status, 409);
  if (result.status === 409) assertEquals(result.body.error, "no_pair");
});

Deno.test("react: push失敗/throwでも200(自己修復経路前提)", async () => {
  const world1 = makeWorld();
  const { pusher: failPusher } = makePusher("fail");
  const r1 = await handleReact(deps(world1, failPusher), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "❤️",
  });
  assertEquals(r1.status, 200);

  const world2 = makeWorld();
  const { pusher: throwPusher } = makePusher("throw");
  const r2 = await handleReact(deps(world2, throwPusher), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "❤️",
  });
  assertEquals(r2.status, 200);
});

Deno.test("react: 相手にpush_tokenが無ければpushせず成功", async () => {
  const world = makeWorld({ users: [userA, { ...userB, pushToken: null }] });
  const { sent, pusher } = makePusher("ok");
  const result = await handleReact(deps(world, pusher), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "❤️",
  });
  assertEquals(result.status, 200);
  assertEquals(sent.length, 0);
});
