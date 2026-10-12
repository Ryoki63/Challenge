// core_test.ts — nudge/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/REQUIREMENTS.md §3.7(つつく)/ docs/DESIGN.md §5.3 / §5.5(当日カウント)

import {
  handleNudge,
  NUDGE_DAILY_LIMIT,
  type NudgeRepo,
  type Pusher,
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

interface NudgeRecord {
  pairId: string;
  fromUserId: string;
  stamp: string;
  createdAtIso: string;
}

interface World {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>;
  pair:
    | { pairId: string; startedOn: string; memberIds: [string, string] }
    | null;
  checkins: Map<string, { photoPath: string | null }>; // key: `${userId}|${dateLocal}`
  streakDays: StreakDayRecord[];
  plant: SnapshotPlantRow | null;
  nudges: NudgeRecord[];
}

function makeRepo(world: World): NudgeRepo {
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
    listRecentNudgesBySender: (params) =>
      Promise.resolve(
        world.nudges
          .filter((n) =>
            n.pairId === params.pairId && n.fromUserId === params.fromUserId
          )
          .map((n) => ({ createdAtIso: n.createdAtIso })),
      ),
    insertNudge: (params) => {
      world.nudges.push({ ...params, createdAtIso: NOW.toISOString() });
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

/** JST 2026-06-10 12:00。todayLocal = 2026-06-10 */
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
    streakDays: bothDays("2026-06-08", "2026-06-09"),
    plant: { grownDays: 2, name: null },
    nudges: [],
    ...overrides,
  };
}

function deps(world: World, pusher: Pusher) {
  return { repo: makeRepo(world), pusher, now: () => NOW, random: () => 0 };
}

// ---- テスト ----

Deno.test("nudge: 正常送信 — 相手が未完なら200・相手へ可視push(送り手名義)・remainingToday減算", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher("ok");
  const result = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "👋",
  });
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.remainingToday, NUDGE_DAILY_LIMIT - 1);
  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-b");
  const payload = sent[0].payload as {
    aps: { alert: { title: string; body: string } };
    lien: { type: string };
  };
  // 送り手(user-a=あきら)名義で届く(つつかれた側が誰につつかれたか分かる — §3.7)
  assertEquals(payload.aps.alert.title, "あきら");
  assert(payload.aps.alert.body.includes("👋"), "本文にスタンプが無い");
  assertEquals(payload.lien.type, "nudge");
  assertEquals(world.nudges.length, 1);
  assertEquals(world.nudges[0].stamp, "👋");
});

Deno.test("nudge: 3回目は成功・4回目は429(1日3回まで — §3.7)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("ok");
  for (let i = 0; i < NUDGE_DAILY_LIMIT; i++) {
    const r = await handleNudge(deps(world, pusher), {
      userId: "user-a",
      stamp: "👋",
    });
    assertEquals(r.status, 200, `${i + 1}回目は成功するはず`);
  }
  const fourth = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "👋",
  });
  assertEquals(fourth.status, 429);
  if (fourth.status === 429) {
    assertEquals(fourth.body.error, "nudge_limit_exceeded");
  }
});

Deno.test("nudge: 3回目成功時の remainingToday は 0", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("ok");
  let last;
  for (let i = 0; i < NUDGE_DAILY_LIMIT; i++) {
    last = await handleNudge(deps(world, pusher), {
      userId: "user-a",
      stamp: "👋",
    });
  }
  assertEquals(last!.status, 200);
  if (last!.status === 200) {
    assertEquals(last!.body.remainingToday, 0);
  }
});

Deno.test("nudge: TZ日付境界でカウントがリセットされる(前日分は当日カウントに含めない)", async () => {
  const world = makeWorld({
    nudges: [
      // 前日(JST 2026-06-09)に3回送っている → 当日(06-10)はまだ0回のはず
      {
        pairId: "pair-1",
        fromUserId: "user-a",
        stamp: "👋",
        createdAtIso: "2026-06-09T03:00:00Z",
      },
      {
        pairId: "pair-1",
        fromUserId: "user-a",
        stamp: "👋",
        createdAtIso: "2026-06-09T10:00:00Z",
      },
      {
        pairId: "pair-1",
        fromUserId: "user-a",
        stamp: "👋",
        createdAtIso: "2026-06-09T14:00:00Z",
      },
    ],
  });
  const { pusher } = makePusher("ok");
  const result = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "👋",
  });
  assertEquals(result.status, 200);
  if (result.status === 200) {
    // 当日1回目を消費 → 残り2
    assertEquals(result.body.remainingToday, NUDGE_DAILY_LIMIT - 1);
  }
});

Deno.test("nudge: 相手が当日チェックイン済みなら409 partner_already_done(§3.7「相手が未完のときだけ」)", async () => {
  const world = makeWorld();
  world.checkins.set("user-b|2026-06-10", { photoPath: null });
  const { pusher } = makePusher("ok");
  const result = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "👋",
  });
  assertEquals(result.status, 409);
  if (result.status === 409) {
    assertEquals(result.body.error, "partner_already_done");
  }
});

Deno.test("nudge: ソロ状態(ペア無し)は409 no_pair", async () => {
  const world = makeWorld({ pair: null });
  const { pusher } = makePusher("ok");
  const result = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "👋",
  });
  assertEquals(result.status, 409);
  if (result.status === 409) {
    assertEquals(result.body.error, "no_pair");
  }
});

Deno.test("nudge: 語彙外のstampは400 invalid_stamp(自由入力は入れない方針 — §3.7)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("ok");
  const result = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "free-text-not-allowed",
  });
  assertEquals(result.status, 400);
  if (result.status === 400) {
    assertEquals(result.body.error, "invalid_stamp");
  }
  assertEquals(world.nudges.length, 0, "拒否時は記録しない");
});

Deno.test("nudge: ユーザー不在は404", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("ok");
  const result = await handleNudge(deps(world, pusher), {
    userId: "ghost",
    stamp: "👋",
  });
  assertEquals(result.status, 404);
});

Deno.test("nudge: push失敗(ok:false)でも200(自己修復経路前提)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("fail");
  const result = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "👋",
  });
  assertEquals(result.status, 200);
});

Deno.test("nudge: push送信がthrowしても200(自己修復経路前提)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher("throw");
  const result = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "👋",
  });
  assertEquals(result.status, 200);
});

Deno.test("nudge: 相手にpush_tokenが無ければpushせず成功", async () => {
  const world = makeWorld({
    users: [userA, { ...userB, pushToken: null }],
  });
  const { sent, pusher } = makePusher("ok");
  const result = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "👋",
  });
  assertEquals(result.status, 200);
  assertEquals(sent.length, 0);
});

Deno.test("nudge: 自分と相手のレート制限は独立(相手が3回送っていても自分は送れる)", async () => {
  const world = makeWorld({
    nudges: [
      {
        pairId: "pair-1",
        fromUserId: "user-b",
        stamp: "👋",
        createdAtIso: NOW.toISOString(),
      },
      {
        pairId: "pair-1",
        fromUserId: "user-b",
        stamp: "👋",
        createdAtIso: NOW.toISOString(),
      },
      {
        pairId: "pair-1",
        fromUserId: "user-b",
        stamp: "👋",
        createdAtIso: NOW.toISOString(),
      },
    ],
  });
  const { pusher } = makePusher("ok");
  const result = await handleNudge(deps(world, pusher), {
    userId: "user-a",
    stamp: "👋",
  });
  assertEquals(result.status, 200);
  if (result.status === 200) {
    assertEquals(result.body.remainingToday, NUDGE_DAILY_LIMIT - 1);
  }
});
