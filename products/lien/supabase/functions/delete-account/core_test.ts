// core_test.ts — delete-account/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: marketing/terms.md 第8条・privacy-policy.md §6 / docs/DESIGN.md §5.3(delete-account)・§5.2 / issue #23

import {
  type DeleteAccountRepo,
  handleDeleteAccount,
  MAX_DAYS_PER_PAIR,
  type MembershipRow,
  photoPathsToRemove,
  type Pusher,
  REMOVE_CHUNK_SIZE,
} from "./core.ts";
import type {
  PairSnapshot,
  SnapshotPairRow,
  SnapshotPlantRow,
  SnapshotPromiseRow,
  SnapshotUserRow,
} from "../_shared/snapshot.ts";
import type { StreakDayRecord } from "../_shared/streak.ts";
import type { ApnsSendOptions } from "../_shared/apns.ts";

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

async function assertRejects(
  fn: () => Promise<unknown>,
  msg = "",
): Promise<void> {
  try {
    await fn();
  } catch {
    return;
  }
  throw new Error(`rejects を期待したが成功した ${msg}`);
}

// ---- 世界(users / ペア / 写真 / Storage / auth)と fake repo ----

interface PairRow {
  pairId: string;
  startedOn: string;
  status: "active" | "dissolved";
  dissolvedAt: string | null;
}

interface World {
  users: SnapshotUserRow[];
  /** auth.users(消すとここから無くなる。users 行も連鎖して消える) */
  authUsers: Set<string>;
  promises: Record<string, SnapshotPromiseRow>;
  pairs: PairRow[];
  members: Array<{ pairId: string; userId: string }>;
  /** checkins のうち photo_path を持つ行 */
  checkinPhotos: Array<{ userId: string; path: string }>;
  /** photos バケットのオブジェクト */
  storage: Set<string>;
  streakDays: Record<string, StreakDayRecord[]>;
  plants: Map<string, SnapshotPlantRow>;
  /** repo のメソッド呼び出しの順序 */
  calls: string[];
  /** removePhotos に渡された件数の記録 */
  removeSizes: number[];
  /** true にしたメソッドは 1 回だけ失敗する(その後は直る = やり直しの再現) */
  failOnce: Record<string, boolean>;
  /** メソッドごとの呼び出し回数(failAt が数える) */
  callCounts: Record<string, number>;
  /** そのメソッドの N 回目(1 始まり)の呼び出しだけ失敗する(同じメソッドを複数回呼ぶ手順の、途中の失敗の再現) */
  failAt: Record<string, number>;
}

function maybeFail(world: World, name: string): void {
  world.callCounts[name] = (world.callCounts[name] ?? 0) + 1;
  if (world.failAt[name] === world.callCounts[name]) {
    throw new Error(`${name} の ${world.callCounts[name]} 回目が失敗(注入)`);
  }
  if (world.failOnce[name]) {
    world.failOnce[name] = false;
    throw new Error(`${name} が失敗(注入)`);
  }
}

function makeRepo(world: World): DeleteAccountRepo {
  return {
    getUser: (id) =>
      Promise.resolve(world.users.find((u) => u.id === id) ?? null),
    getActivePromise: (id) => Promise.resolve(world.promises[id] ?? null),
    getActivePair: (id): Promise<SnapshotPairRow | null> => {
      const mine = world.members.filter((m) => m.userId === id);
      const active = mine.find((m) =>
        world.pairs.find((p) => p.pairId === m.pairId)?.status === "active"
      );
      if (!active) return Promise.resolve(null);
      const pair = world.pairs.find((p) => p.pairId === active.pairId)!;
      const partnerMember = world.members.find((m) =>
        m.pairId === active.pairId && m.userId !== id
      );
      if (!partnerMember) return Promise.resolve(null);
      const partner = world.users.find((u) => u.id === partnerMember.userId);
      if (!partner) return Promise.resolve(null);
      return Promise.resolve({
        pairId: pair.pairId,
        startedOn: pair.startedOn,
        partner,
      });
    },
    getCheckin: () => Promise.resolve(null),
    listStreakDays: (pairId) =>
      Promise.resolve([...(world.streakDays[pairId] ?? [])]),
    getPlant: (pairId) => {
      const plant = world.plants.get(pairId);
      return Promise.resolve(plant ? { ...plant } : null);
    },
    dissolvePair: (pairId, dissolvedAtIso) => {
      world.calls.push("dissolvePair");
      maybeFail(world, "dissolvePair");
      const p = world.pairs.find((x) => x.pairId === pairId);
      if (!p || p.status !== "active") return Promise.resolve(false);
      p.status = "dissolved";
      p.dissolvedAt = dissolvedAtIso;
      return Promise.resolve(true);
    },
    listMemberships: (userId): Promise<MembershipRow[]> => {
      world.calls.push("listMemberships");
      maybeFail(world, "listMemberships");
      return Promise.resolve(
        world.members.filter((m) => m.userId === userId).map((m) => {
          const p = world.pairs.find((x) => x.pairId === m.pairId)!;
          return {
            pairId: p.pairId,
            startedOn: p.startedOn,
            status: p.status,
            dissolvedAt: p.dissolvedAt,
          };
        }),
      );
    },
    listPhotoPaths: (userId) => {
      world.calls.push("listPhotoPaths");
      maybeFail(world, "listPhotoPaths");
      return Promise.resolve(
        world.checkinPhotos.filter((c) => c.userId === userId).map((c) =>
          c.path
        ),
      );
    },
    removePhotos: (paths) => {
      world.calls.push("removePhotos");
      maybeFail(world, "removePhotos");
      world.removeSizes.push(paths.length);
      for (const p of paths) world.storage.delete(p);
      return Promise.resolve();
    },
    deleteMemberships: (userId) => {
      world.calls.push("deleteMemberships");
      maybeFail(world, "deleteMemberships");
      world.members = world.members.filter((m) => m.userId !== userId);
      return Promise.resolve();
    },
    deleteOrphanPairs: (pairIds, exceptUserId) => {
      world.calls.push("deleteOrphanPairs");
      maybeFail(world, "deleteOrphanPairs");
      for (const id of pairIds) {
        // exceptUserId の所属は数えない(その人しか居ないペアも「誰も残らない」ペア)
        if (
          world.members.some((m) =>
            m.pairId === id && m.userId !== exceptUserId
          )
        ) continue;
        world.pairs = world.pairs.filter((p) => p.pairId !== id);
        // pair_members・plants・streak_days は pairs への ON DELETE CASCADE
        world.members = world.members.filter((m) => m.pairId !== id);
        world.plants.delete(id);
        delete world.streakDays[id];
      }
      return Promise.resolve();
    },
    deleteAuthUser: (userId) => {
      world.calls.push("deleteAuthUser");
      maybeFail(world, "deleteAuthUser");
      world.authUsers.delete(userId);
      // users 行以下は CASCADE
      world.users = world.users.filter((u) => u.id !== userId);
      delete world.promises[userId];
      world.checkinPhotos = world.checkinPhotos.filter((c) =>
        c.userId !== userId
      );
      return Promise.resolve();
    },
  };
}

interface SentPush {
  deviceToken: string;
  payload: Record<string, unknown>;
  opts?: ApnsSendOptions;
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

// ---- 共通フィクスチャ ----

const userA: SnapshotUserRow = {
  id: "user-a",
  nickname: "あきら",
  timezone: "Asia/Tokyo",
  pushToken: "token-a",
  pushEnv: "production",
};
const userB: SnapshotUserRow = {
  id: "user-b",
  nickname: "ゆうき",
  timezone: "Asia/Tokyo",
  pushToken: "token-b",
  pushEnv: "sandbox",
};
const userC: SnapshotUserRow = {
  id: "user-c",
  nickname: "ほか",
  timezone: "Asia/Tokyo",
  pushToken: "token-c",
};
const userD: SnapshotUserRow = {
  id: "user-d",
  nickname: "べつ",
  timezone: "Asia/Tokyo",
  pushToken: "token-d",
};

/** JST 2026-06-10 12:00(todayLocal = 2026-06-10) */
const NOW = new Date("2026-06-10T03:00:00Z");

const dir = (pair: string, date: string, user: string) =>
  `pairs/${pair}/${date}/${user}`;

/**
 * ペア1(A・B。2026-06-01〜現役)とペア2(C・D)。
 * A の写真: 06-05 と 06-09(チェックインの行あり)・06-07 のサムネだけ(行が無い孤児)・
 *           旧形式 06-02(ペア×日付単位。A の行が指す)
 * B の写真: 06-05。C・D の写真もある
 */
function makeWorld(overrides: Partial<World> = {}): World {
  const storage = new Set<string>([
    `${dir("pair-1", "2026-06-05", "user-a")}/photo.jpg`,
    `${dir("pair-1", "2026-06-05", "user-a")}/photo_thumb.jpg`,
    `${dir("pair-1", "2026-06-09", "user-a")}/photo.jpg`,
    `${dir("pair-1", "2026-06-09", "user-a")}/photo_thumb.jpg`,
    `${dir("pair-1", "2026-06-07", "user-a")}/photo_thumb.jpg`,
    `pairs/pair-1/2026-06-02/photo.jpg`,
    `pairs/pair-1/2026-06-02/photo_thumb.jpg`,
    `${dir("pair-1", "2026-06-05", "user-b")}/photo.jpg`,
    `${dir("pair-1", "2026-06-05", "user-b")}/photo_thumb.jpg`,
    `${dir("pair-2", "2026-06-05", "user-c")}/photo.jpg`,
    `${dir("pair-2", "2026-06-05", "user-d")}/photo.jpg`,
  ]);
  return {
    users: [userA, userB, userC, userD],
    authUsers: new Set(["user-a", "user-b", "user-c", "user-d"]),
    promises: {
      "user-a": { id: "prom-a", title: "筋トレ", emoji: "💪" },
      "user-b": { id: "prom-b", title: "ランニング", emoji: "🏃" },
      "user-c": { id: "prom-c", title: "読書", emoji: "📚" },
      "user-d": { id: "prom-d", title: "散歩", emoji: "🚶" },
    },
    pairs: [
      {
        pairId: "pair-1",
        startedOn: "2026-06-01",
        status: "active",
        dissolvedAt: null,
      },
      {
        pairId: "pair-2",
        startedOn: "2026-06-01",
        status: "active",
        dissolvedAt: null,
      },
    ],
    members: [
      { pairId: "pair-1", userId: "user-a" },
      { pairId: "pair-1", userId: "user-b" },
      { pairId: "pair-2", userId: "user-c" },
      { pairId: "pair-2", userId: "user-d" },
    ],
    checkinPhotos: [
      {
        userId: "user-a",
        path: `${dir("pair-1", "2026-06-05", "user-a")}/photo.jpg`,
      },
      {
        userId: "user-a",
        path: `${dir("pair-1", "2026-06-09", "user-a")}/photo.jpg`,
      },
      { userId: "user-a", path: "pairs/pair-1/2026-06-02/photo.jpg" },
      {
        userId: "user-b",
        path: `${dir("pair-1", "2026-06-05", "user-b")}/photo.jpg`,
      },
    ],
    storage,
    streakDays: { "pair-1": [], "pair-2": [] },
    plants: new Map([
      ["pair-1", { grownDays: 3, name: "みどり" }],
      ["pair-2", { grownDays: 1, name: null }],
    ]),
    calls: [],
    removeSizes: [],
    failOnce: {},
    callCounts: {},
    failAt: {},
    ...overrides,
  };
}

function deps(world: World, pusher: Pusher) {
  return { repo: makeRepo(world), pusher, now: () => NOW };
}

type PushedPayload = {
  aps: Record<string, unknown>;
  lien: { type: string; snapshot: PairSnapshot };
};

// ---- 全体の流れ ----

Deno.test("delete-account: ペアあり — 解消 → 写真 → 関連データ → auth ユーザーの順で消し、{ deleted: true }", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  const result = await handleDeleteAccount(deps(world, pusher), {
    userId: "user-a",
  });

  assertEquals(result, { status: 200, body: { deleted: true } });
  const order = world.calls.filter((c, i, all) => all.indexOf(c) === i);
  assertEquals(
    order,
    [
      "dissolvePair",
      "listMemberships",
      "listPhotoPaths",
      "removePhotos",
      "deleteOrphanPairs", // 本人しか居ないペアを先に(所属を消す前)
      "deleteMemberships",
      "deleteAuthUser",
    ],
    "auth ユーザーは最後(それまでの失敗はやり直せる)。本人しか居ないペアは所属を消す前に消す",
  );
  assertEquals(world.authUsers.has("user-a"), false);
  assertEquals(world.users.some((u) => u.id === "user-a"), false);
  assertEquals(world.checkinPhotos.some((c) => c.userId === "user-a"), false);
  assertEquals(world.members.some((m) => m.userId === "user-a"), false);
});

Deno.test("delete-account: 本人の写真だけを Storage から消す(原寸・サムネ・行の無い孤児・旧形式)— 相手とほかのペアの写真は残す", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  await handleDeleteAccount(deps(world, pusher), { userId: "user-a" });

  assertEquals(
    [...world.storage].sort(),
    [
      `${dir("pair-1", "2026-06-05", "user-b")}/photo.jpg`,
      `${dir("pair-1", "2026-06-05", "user-b")}/photo_thumb.jpg`,
      `${dir("pair-2", "2026-06-05", "user-c")}/photo.jpg`,
      `${dir("pair-2", "2026-06-05", "user-d")}/photo.jpg`,
    ].sort(),
    "A の 原寸・サムネ・06-07 の孤児サムネ・旧形式 06-02 は消え、B・C・D の写真は残る",
  );
});

Deno.test("delete-account: 相手へサイレント push(pair_update・解消後のソロの snapshot)— 相手のペアの記録(植物)はアーカイブとして残る", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  await handleDeleteAccount(deps(world, pusher), { userId: "user-a" });

  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-b");
  const payload = sent[0].payload as PushedPayload;
  assertEquals(payload.aps, { "content-available": 1 });
  assertEquals(payload.lien.type, "pair_update");
  assertEquals(payload.lien.snapshot.pairId, null, "相手はソロに戻る");
  assertEquals(payload.lien.snapshot.myPromiseTitle, "ランニング");
  assertEquals(
    sent[0].opts,
    { pushType: "background", priority: 5, environment: "sandbox" },
  );

  const pair1 = world.pairs.find((p) => p.pairId === "pair-1")!;
  assertEquals(pair1.status, "dissolved", "ペアは解消済みで残る");
  assertEquals(world.plants.get("pair-1")?.name, "みどり");
  assertEquals(
    world.members.filter((m) => m.pairId === "pair-1").map((m) => m.userId),
    ["user-b"],
    "相手の所属は残る(アーカイブ閲覧)",
  );
  assertEquals(world.authUsers.has("user-b"), true, "相手のアカウントは無傷");
});

Deno.test("delete-account: push が失敗(ok:false / throw)しても削除は完了する", async () => {
  for (const behavior of ["fail", "throw"] as const) {
    const world = makeWorld();
    const { sent, pusher } = makePusher(behavior);

    const result = await handleDeleteAccount(deps(world, pusher), {
      userId: "user-a",
    });

    assertEquals(result.body, { deleted: true }, behavior);
    assertEquals(sent.length, 1, behavior);
    assertEquals(world.authUsers.has("user-a"), false, behavior);
  }
});

Deno.test("delete-account: ソロ(ペアなし)— push も写真の削除も無く、auth ユーザーを消す", async () => {
  const world = makeWorld({
    pairs: [],
    members: [],
    checkinPhotos: [],
    storage: new Set(),
  });
  const { sent, pusher } = makePusher();

  const result = await handleDeleteAccount(deps(world, pusher), {
    userId: "user-a",
  });

  assertEquals(result.body, { deleted: true });
  assertEquals(sent.length, 0);
  assertEquals(world.calls.includes("removePhotos"), false, "消すものが無い");
  assertEquals(world.authUsers.has("user-a"), false);
});

Deno.test("delete-account: 解消済みのペア(アーカイブ)の写真も消す — 現役ペアと両方", async () => {
  const world = makeWorld();
  // A は以前 pair-0 (06-01〜06-03) にいた。A の写真が 06-02 と、解消の翌日 06-04 にもある
  world.pairs.push({
    pairId: "pair-0",
    startedOn: "2026-06-01",
    status: "dissolved",
    dissolvedAt: "2026-06-03T09:00:00.000Z",
  });
  world.members.push(
    { pairId: "pair-0", userId: "user-a" },
    { pairId: "pair-0", userId: "user-e" },
  );
  world.users.push({
    id: "user-e",
    nickname: "むかし",
    timezone: "Asia/Tokyo",
    pushToken: "token-e",
  });
  world.storage.add(`${dir("pair-0", "2026-06-02", "user-a")}/photo.jpg`);
  world.storage.add(`${dir("pair-0", "2026-06-04", "user-a")}/photo_thumb.jpg`);
  world.storage.add(`${dir("pair-0", "2026-06-02", "user-e")}/photo.jpg`);
  const { sent, pusher } = makePusher();

  await handleDeleteAccount(deps(world, pusher), { userId: "user-a" });

  assertEquals(
    [...world.storage].filter((p) => p.includes("user-a")),
    [],
    "A の区画の写真はどのペアのものも消える",
  );
  assertEquals(
    world.storage.has(`${dir("pair-0", "2026-06-02", "user-e")}/photo.jpg`),
    true,
    "むかしの相手 E の写真は残る",
  );
  assertEquals(
    sent.map((s) => s.deviceToken),
    ["token-b"],
    "通知は現役の相手だけ",
  );
  assertEquals(world.members.some((m) => m.userId === "user-a"), false);
});

Deno.test("delete-account: 相手が先にアカウントを消していたら、誰も残らないペアの行も消す(植物・ストリークごと)", async () => {
  const world = makeWorld({
    streakDays: {
      "pair-1": [{ dateLocal: "2026-06-05", kind: "both" }],
      "pair-2": [],
    },
  });
  const { pusher } = makePusher();

  // B が先に削除 → ペアは解消済みで A のアーカイブとして残る
  await handleDeleteAccount(deps(world, pusher), { userId: "user-b" });
  assertEquals(world.pairs.some((p) => p.pairId === "pair-1"), true);
  assertEquals(world.plants.has("pair-1"), true, "A が残るので鉢も残る");

  // 続けて A が削除 → pair-1 に誰も居なくなる
  world.calls.length = 0;
  await handleDeleteAccount(deps(world, pusher), { userId: "user-a" });
  assertEquals(
    world.pairs.map((p) => p.pairId),
    ["pair-2"],
    "pair-1 の行は消える",
  );
  assertEquals(world.plants.has("pair-1"), false);
  assertEquals(world.streakDays["pair-1"], undefined);
  assertEquals(world.plants.has("pair-2"), true, "ほかのペアは無傷");
});

// ---- 失敗とやり直し ----

Deno.test("delete-account: 写真の削除に失敗 → 例外・DB の関連データと auth ユーザーは残る(やり直せる)。やり直しは最後まで進み、相手には二重に知らせない", async () => {
  const world = makeWorld({ failOnce: { removePhotos: true } });
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  await assertRejects(() => handleDeleteAccount(d, { userId: "user-a" }));
  assertEquals(world.authUsers.has("user-a"), true, "auth ユーザーはまだ有効");
  assertEquals(
    world.members.some((m) => m.userId === "user-a"),
    true,
    "所属も残っている",
  );
  assertEquals(world.calls.includes("deleteMemberships"), false);
  assertEquals(world.calls.includes("deleteAuthUser"), false);
  assertEquals(sent.length, 1, "ペアの解消(と相手への通知)は済んでいる");

  // やり直し(同じ要求)
  const retry = await handleDeleteAccount(d, { userId: "user-a" });
  assertEquals(retry.body, { deleted: true });
  assertEquals(world.authUsers.has("user-a"), false);
  assertEquals(
    [...world.storage].filter((p) => p.includes("user-a")),
    [],
  );
  assertEquals(sent.length, 1, "やり直しでは相手に二重に知らせない");
});

/** 失敗を注入する手順(name は repo のメソッド、at はそのメソッドの何回目か)と、その失敗の後に実行されてはいけない手順 */
const FAILURE_POINTS: Array<{
  label: string;
  name: string;
  at: number;
  notAfter: string[];
}> = [
  {
    label: "dissolvePair",
    name: "dissolvePair",
    at: 1,
    notAfter: ["listMemberships", "deleteAuthUser"],
  },
  {
    label: "listMemberships",
    name: "listMemberships",
    at: 1,
    notAfter: ["removePhotos", "deleteAuthUser"],
  },
  {
    label: "listPhotoPaths",
    name: "listPhotoPaths",
    at: 1,
    notAfter: ["removePhotos", "deleteAuthUser"],
  },
  {
    label: "removePhotos",
    name: "removePhotos",
    at: 1,
    notAfter: ["deleteOrphanPairs", "deleteMemberships", "deleteAuthUser"],
  },
  {
    label: "deleteOrphanPairs(a: 本人しか居ないペアを先に消す)",
    name: "deleteOrphanPairs",
    at: 1,
    notAfter: ["deleteMemberships", "deleteAuthUser"],
  },
  {
    label: "deleteMemberships(b)",
    name: "deleteMemberships",
    at: 1,
    notAfter: ["deleteAuthUser"],
  },
  {
    label: "deleteOrphanPairs(c: 所属を消したあとの取りこぼし)",
    name: "deleteOrphanPairs",
    at: 2,
    notAfter: ["deleteAuthUser"],
  },
  { label: "deleteAuthUser", name: "deleteAuthUser", at: 1, notAfter: [] },
];

Deno.test("delete-account: どの手順で失敗しても、後ろの手順は実行されず、やり直しで完了する", async () => {
  for (const point of FAILURE_POINTS) {
    const world = makeWorld({ failAt: { [point.name]: point.at } });
    const { pusher } = makePusher();
    const d = deps(world, pusher);

    await assertRejects(
      () => handleDeleteAccount(d, { userId: "user-a" }),
      point.label,
    );
    for (const name of point.notAfter) {
      assertEquals(
        world.calls.includes(name),
        false,
        `${point.label} の失敗後に ${name}`,
      );
    }
    if (point.name !== "deleteAuthUser") {
      assertEquals(
        world.authUsers.has("user-a"),
        true,
        `${point.label}: 認証は有効のまま`,
      );
    }

    const retry = await handleDeleteAccount(d, { userId: "user-a" });
    assertEquals(retry.body, { deleted: true }, point.label);
    assertEquals(
      world.authUsers.has("user-a"),
      false,
      `${point.label}: やり直しで完了`,
    );
    assertEquals(
      world.members.some((m) => m.userId === "user-a"),
      false,
      point.label,
    );
  }
});

Deno.test("delete-account: 相手が先に消えていて本人しか居ないペアは、どの手順で失敗しても、やり直しでペアの行(植物・ストリーク)ごと消える", async () => {
  for (const point of FAILURE_POINTS) {
    // 現役のペアが無い世界なので、ペアの解消(dissolvePair)は呼ばれない
    if (point.name === "dissolvePair") continue;
    const world = makeWorld({
      streakDays: {
        "pair-1": [{ dateLocal: "2026-06-05", kind: "both" }],
        "pair-2": [],
      },
    });
    const { pusher } = makePusher();
    // B が先に削除 → pair-1 は解消済みで、A だけが所属するアーカイブとして残る
    await handleDeleteAccount(deps(world, pusher), { userId: "user-b" });
    assertEquals(world.pairs.some((p) => p.pairId === "pair-1"), true);
    assertEquals(
      world.members.filter((m) => m.pairId === "pair-1").map((m) => m.userId),
      ["user-a"],
      "A しか居ない",
    );

    // A の削除。注入した手順で失敗 → 同じ要求をやり直す(呼び出し回数は A の削除から数え直す)
    world.callCounts = {};
    world.failAt = { [point.name]: point.at };
    const d = deps(world, pusher);
    await assertRejects(
      () => handleDeleteAccount(d, { userId: "user-a" }),
      point.label,
    );
    const retry = await handleDeleteAccount(d, { userId: "user-a" });

    assertEquals(retry.body, { deleted: true }, point.label);
    assertEquals(
      world.pairs.map((p) => p.pairId),
      ["pair-2"],
      `${point.label}: 誰も居ないペアの行が残らない`,
    );
    assertEquals(world.plants.has("pair-1"), false, point.label);
    assertEquals(world.streakDays["pair-1"], undefined, point.label);
    assertEquals(
      world.members.some((m) => m.pairId === "pair-1"),
      false,
      point.label,
    );
    assertEquals(world.plants.has("pair-2"), true, "ほかのペアは無傷");
  }
});

Deno.test("delete-account: 所属を消す前に本人しか居ないペアを消す — 相手が居るペアは(解消後も)相手のアーカイブとして残す", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  await handleDeleteAccount(deps(world, pusher), { userId: "user-a" });

  assertEquals(
    world.pairs.map((p) => p.pairId).sort(),
    ["pair-1", "pair-2"],
    "pair-1 には相手 B が残るので、行を消さない",
  );
  assertEquals(world.plants.get("pair-1")?.name, "みどり");
  assertEquals(
    world.members.filter((m) => m.pairId === "pair-1").map((m) => m.userId),
    ["user-b"],
  );
});

Deno.test("delete-account: 2 回目(すでに消えた後の再実行)も例外にならない — users 行が無くても auth ユーザー削除まで進む", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  await handleDeleteAccount(d, { userId: "user-a" });
  world.calls.length = 0;
  const again = await handleDeleteAccount(d, { userId: "user-a" });

  assertEquals(again.body, { deleted: true });
  assertEquals(world.calls.includes("deleteAuthUser"), true);
  assertEquals(sent.length, 1, "再実行で通知しない");
  assertEquals(world.authUsers.has("user-b"), true);
});

Deno.test("delete-account: 本人以外のデータには触れない(C・D のペア・アカウント・写真)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  await handleDeleteAccount(deps(world, pusher), { userId: "user-a" });

  assertEquals(
    [...world.authUsers].sort(),
    ["user-b", "user-c", "user-d"],
  );
  assertEquals(
    world.pairs.find((p) => p.pairId === "pair-2")?.status,
    "active",
  );
  assertEquals(
    world.members.filter((m) => m.pairId === "pair-2").length,
    2,
  );
});

// ---- 写真のパス(純粋関数) ----

const membership = (
  over: Partial<MembershipRow> & { pairId: string },
): MembershipRow => ({
  startedOn: "2026-06-01",
  status: "active",
  dissolvedAt: null,
  ...over,
});

Deno.test("photoPathsToRemove: 現役ペアは成立日の前日から今日の翌日まで、原寸とサムネの両方", () => {
  const paths = photoPathsToRemove({
    userId: "u1",
    memberships: [membership({ pairId: "p1", startedOn: "2026-06-08" })],
    referencedPaths: [],
    todayLocal: "2026-06-10",
  });
  assertEquals(paths, [
    "pairs/p1/2026-06-07/u1/photo.jpg",
    "pairs/p1/2026-06-07/u1/photo_thumb.jpg",
    "pairs/p1/2026-06-08/u1/photo.jpg",
    "pairs/p1/2026-06-08/u1/photo_thumb.jpg",
    "pairs/p1/2026-06-09/u1/photo.jpg",
    "pairs/p1/2026-06-09/u1/photo_thumb.jpg",
    "pairs/p1/2026-06-10/u1/photo.jpg",
    "pairs/p1/2026-06-10/u1/photo_thumb.jpg",
    "pairs/p1/2026-06-11/u1/photo.jpg",
    "pairs/p1/2026-06-11/u1/photo_thumb.jpg",
  ]);
});

Deno.test("photoPathsToRemove: 解消済みのペアは解消日の +2 日まで(今日を超えない)", () => {
  const dissolved = membership({
    pairId: "p1",
    startedOn: "2026-06-01",
    status: "dissolved",
    dissolvedAt: "2026-06-03T23:30:00.000+00:00",
  });
  const dates = (todayLocal: string) =>
    photoPathsToRemove({
      userId: "u1",
      memberships: [dissolved],
      referencedPaths: [],
      todayLocal,
    }).filter((p) => p.endsWith("/photo.jpg")).map((p) => p.split("/")[2]);

  assertEquals(dates("2026-06-20"), [
    "2026-05-31", // 成立日の前日(タイムゾーン違いで date_local が 1 日前になりうる)
    "2026-06-01",
    "2026-06-02",
    "2026-06-03",
    "2026-06-04",
    "2026-06-05",
  ]);
  // 解消した日のうちに削除する場合は、今日の翌日までで打ち切る
  assertEquals(dates("2026-06-03"), [
    "2026-05-31",
    "2026-06-01",
    "2026-06-02",
    "2026-06-03",
    "2026-06-04",
  ]);
});

Deno.test("photoPathsToRemove: 行が指す旧形式のパス(本人の所属したペアのもの)とそのサムネを足す。他人の区画・知らないペア・規約外は無視する", () => {
  const paths = photoPathsToRemove({
    userId: "u1",
    memberships: [
      membership({ pairId: "p1", startedOn: "2026-06-10" }),
    ],
    referencedPaths: [
      "pairs/p1/2026-05-01/photo.jpg", // 旧形式(ペア × 日付)— 開始前の日付でも、行が指すなら消す
      "pairs/p1/2026-05-02/u1/photo.jpg", // 新形式・本人
      "pairs/p1/2026-05-03/u2/photo.jpg", // 他人の区画 → 無視
      "pairs/p9/2026-05-04/photo.jpg", // 所属していないペア → 無視
      "pairs/p1/2026-05-05/../u2/photo.jpg", // パスの細工 → 無視
      "pairs/p1/2026-05-06/u1/other.jpg", // photo.jpg 以外 → 無視
      "pairs/p1/xx/u1/photo.jpg", // 日付でない → 無視
      "elsewhere/p1/2026-05-07/photo.jpg", // pairs/ 以外 → 無視
      "",
    ],
    todayLocal: "2026-06-10",
  });
  const referenced = paths.filter((p) => p.includes("2026-05"));
  assertEquals(referenced, [
    "pairs/p1/2026-05-01/photo.jpg",
    "pairs/p1/2026-05-01/photo_thumb.jpg",
    "pairs/p1/2026-05-02/u1/photo.jpg",
    "pairs/p1/2026-05-02/u1/photo_thumb.jpg",
  ]);
});

Deno.test("photoPathsToRemove: 重複しない・成立日が未来や異常でも例外にしない・日数に上限がある", () => {
  // 行が指すパスが期間内のパスと重なっても 1 回
  const dup = photoPathsToRemove({
    userId: "u1",
    memberships: [membership({ pairId: "p1", startedOn: "2026-06-10" })],
    referencedPaths: ["pairs/p1/2026-06-10/u1/photo.jpg"],
    todayLocal: "2026-06-10",
  });
  assertEquals(new Set(dup).size, dup.length);

  // 成立日が(時計のずれで)明日より先: 期間が空
  const future = photoPathsToRemove({
    userId: "u1",
    memberships: [membership({ pairId: "p1", startedOn: "2027-01-01" })],
    referencedPaths: [],
    todayLocal: "2026-06-10",
  });
  assertEquals(future, []);

  // 成立日が大昔(データ不整合): 上限の日数で打ち切る(新しい方を残す)
  const ancient = photoPathsToRemove({
    userId: "u1",
    memberships: [membership({ pairId: "p1", startedOn: "1990-01-01" })],
    referencedPaths: [],
    todayLocal: "2026-06-10",
  });
  assertEquals(ancient.length, MAX_DAYS_PER_PAIR * 2);
  assertEquals(
    ancient[ancient.length - 1],
    "pairs/p1/2026-06-11/u1/photo_thumb.jpg",
  );
});

Deno.test("delete-account: 大量のパスは REMOVE_CHUNK_SIZE ずつに分けて消す(全部消える・1 回の件数が上限以内)", async () => {
  const world = makeWorld({ checkinPhotos: [], storage: new Set() });
  // A のペア 1 の期間を 2 年分にする(730 日 × 2 = 約 1460 パス)
  world.pairs[0].startedOn = "2024-06-11";
  for (const d of ["2024-07-01", "2025-08-15", "2026-06-09"]) {
    world.storage.add(`${dir("pair-1", d, "user-a")}/photo.jpg`);
    world.storage.add(`${dir("pair-1", d, "user-b")}/photo.jpg`);
  }
  const { pusher } = makePusher();

  await handleDeleteAccount(deps(world, pusher), { userId: "user-a" });

  assertEquals(world.removeSizes.every((n) => n <= REMOVE_CHUNK_SIZE), true);
  assertEquals(world.removeSizes.length > 10, true, "複数回に分かれる");
  assertEquals(
    [...world.storage].sort(),
    [
      `${dir("pair-1", "2024-07-01", "user-b")}/photo.jpg`,
      `${dir("pair-1", "2025-08-15", "user-b")}/photo.jpg`,
      `${dir("pair-1", "2026-06-09", "user-b")}/photo.jpg`,
    ],
    "A の分は全部消え、B の分は残る",
  );
});
