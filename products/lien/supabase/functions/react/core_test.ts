// core_test.ts — react/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/REQUIREMENTS.md §3.8(リアクション)/ docs/DESIGN.md §5.3 / docs/TASKPLAN.md §9.4(T15 の行)
//   - push は最初のリアクションの1回だけ(付け替え・同一スタンプの再送では送らない)
//   - 同梱する snapshot の「今日」は相手(受信者)のタイムゾーンで決まる

import {
  handleReact,
  type Pusher,
  type ReactCheckinRow,
  type ReactRepo,
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

Deno.test("react: 別スタンプへの付け替えは 200 changed:true・上書きするが push は送らない(最初の1回だけ)", async () => {
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
  // changed は「保存内容が変わったか」。付け替えは true(push の有無とは別)
  if (result.status === 200) assertEquals(result.body.changed, true);
  assertEquals(sent2.length, 0, "付け替えでは push を送り直さない");
  assertEquals(
    world.reactions.length,
    1,
    "行は更新であり追加ではない(UNIQUE制約と一致)",
  );
  assertEquals(world.reactions[0].stamp, "🔥", "スタンプは上書きされる");
});

Deno.test("react: 付け替え・再送を何度繰り返しても、push は最初の1回だけ", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher("ok"); // 全リクエストで同じ pusher を使い、総数を数える
  const results = [];
  for (const stamp of ["❤️", "🔥", "🔥", "❤️", "👏", "👏", "🔥"]) {
    results.push(
      await handleReact(deps(world, pusher), {
        userId: "user-a",
        checkinId: "checkin-b-1",
        stamp,
      }),
    );
  }
  assertEquals(sent.length, 1, "push は最初のリアクションの1回だけ");
  const payload = sent[0].payload as { aps: { alert: { body: string } } };
  assert(
    payload.aps.alert.body.includes("❤️"),
    "その1回は最初のスタンプの文言",
  );
  // changed: 新規 true → 付け替え true → 同じスタンプの再送 false → 付け替え true ...
  assertEquals(
    JSON.stringify(
      results.map((r) => (r.status === 200 ? r.body.changed : null)),
    ),
    JSON.stringify([true, true, false, true, true, false, true]),
  );
  assertEquals(world.reactions.length, 1);
  assertEquals(world.reactions[0].stamp, "🔥", "最後のスタンプが残る");
});

Deno.test("react: 最初のリアクションの push が失敗しても、付け替えで送り直さない(自己修復経路前提)", async () => {
  const world = makeWorld();
  const { sent: sentFail, pusher: failing } = makePusher("fail");
  await handleReact(deps(world, failing), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "❤️",
  });
  assertEquals(sentFail.length, 1, "最初の1回は送る(結果は ok:false)");
  const { sent: sentLater, pusher: working } = makePusher("ok");
  await handleReact(deps(world, working), {
    userId: "user-a",
    checkinId: "checkin-b-1",
    stamp: "🔥",
  });
  assertEquals(
    sentLater.length,
    0,
    "最初の1回を過ぎたら、失敗していても送らない",
  );
});

Deno.test("react: 相手に届く snapshot の「今日」は相手のタイムゾーンで決まる(送り手とずれる TZ のペア)", async () => {
  // NOW = 2026-06-10T03:00:00Z。東京は 6/10 12:00、ホノルル(UTC-10)は 6/9 17:00 で、日付が1日ずれる。
  // 送り手 A がリアクションし、push に載る snapshot は受信者 B 視点。B の todayMeDone / todayPartnerDone は
  // 「B の日付」で決まる。送り手の日付(A の今日)を使うと、この組み合わせは反転してしまう
  const cases = [
    {
      name: "相手が日付の遅れる側(送り手 東京・相手 ホノルル)",
      senderTz: "Asia/Tokyo",
      partnerTz: "Pacific/Honolulu",
      senderToday: "2026-06-10",
      partnerToday: "2026-06-09",
    },
    {
      name: "相手が日付の進む側(送り手 ホノルル・相手 東京)",
      senderTz: "Pacific/Honolulu",
      partnerTz: "Asia/Tokyo",
      senderToday: "2026-06-09",
      partnerToday: "2026-06-10",
    },
  ];
  for (const c of cases) {
    const sender = { ...userA, timezone: c.senderTz };
    const partner = { ...userB, timezone: c.partnerTz };
    const world = makeWorld({
      users: [sender, partner],
      streakDays: [],
      checkins: new Map([
        // 相手 B は「B の今日」にチェックイン済み(= B 視点の todayMeDone)
        [`user-b|${c.partnerToday}`, { photoPath: null }],
        // 送り手 A は「A の今日」にチェックイン済み。B の今日の分ではない(= todayPartnerDone にならない)
        [`user-a|${c.senderToday}`, { photoPath: null }],
      ]),
    });
    const { sent, pusher } = makePusher("ok");
    const result = await handleReact(deps(world, pusher), {
      userId: "user-a",
      checkinId: "checkin-b-1",
      stamp: "❤️",
    });
    assertEquals(result.status, 200, c.name);
    assertEquals(sent.length, 1, c.name);
    const payload = sent[0].payload as {
      aps: { alert: { title: string } };
      lien: { snapshot: PairSnapshot };
    };
    const snapshot = payload.lien.snapshot;
    assertEquals(sent[0].deviceToken, "token-b", c.name);
    assertEquals(payload.aps.alert.title, "あきら", c.name);
    assertEquals(snapshot.partnerName, "あきら", `${c.name}: 受信者 B 視点`);
    assertEquals(
      snapshot.todayMeDone,
      true,
      `${c.name}: B の今日(${c.partnerToday})の B のチェックイン`,
    );
    assertEquals(
      snapshot.todayPartnerDone,
      false,
      `${c.name}: B の今日(${c.partnerToday})には A のチェックインが無い`,
    );
    assertEquals(snapshot.plantMood, "fidget", c.name);
  }
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
