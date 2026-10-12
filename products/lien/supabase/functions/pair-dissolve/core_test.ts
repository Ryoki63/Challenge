// core_test.ts — pair-dissolve/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/REQUIREMENTS.md §3.2(ペア解消)・§8 / docs/DESIGN.md §5.3(pair-dissolve)・§4 / issue #23

import {
  handlePairDissolve,
  type PairDissolveRepo,
  type PairDissolveResult,
  type Pusher,
} from "./core.ts";
import { dissolveActivePair } from "../_shared/pair_dissolve.ts";
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

/** 200 の本文を取り出す(200 でなければテスト失敗) */
function okBody(
  result: PairDissolveResult,
): { dissolved: boolean; snapshot: PairSnapshot } {
  if (result.status !== 200) {
    throw new Error(
      `200 を期待したが ${result.status}: ${JSON.stringify(result.body)}`,
    );
  }
  return result.body;
}

// ---- fake repo / pusher ----

interface PairRow {
  pairId: string;
  startedOn: string;
  memberIds: [string, string];
  status: "active" | "dissolved";
  dissolvedAt: string | null;
}

interface World {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>;
  pairs: PairRow[];
  /** 今日チェックイン済みのユーザー(userId → 写真パス | null) */
  checkins: Record<string, string | null>;
  streakDays: Record<string, StreakDayRecord[]>;
  plants: Map<string, SnapshotPlantRow>;
  /** dissolvePair の呼び出し記録 */
  dissolveCalls: Array<{ pairId: string; dissolvedAtIso: string }>;
  /** dissolvePair が競合で負けた(false を返す)ようにする */
  loseTheRace?: boolean;
  /** dissolvePair が失敗する */
  failDissolve?: boolean;
}

function makeRepo(world: World): PairDissolveRepo {
  return {
    getUser: (id) =>
      Promise.resolve(world.users.find((u) => u.id === id) ?? null),
    getActivePromise: (id) => Promise.resolve(world.promises[id] ?? null),
    getActivePair: (id): Promise<SnapshotPairRow | null> => {
      // 現役(active)のペアだけ。解消済みのペアは snapshot に出ない(DESIGN §5.2)
      const p = world.pairs.find((x) =>
        x.status === "active" && x.memberIds.includes(id)
      );
      if (!p) return Promise.resolve(null);
      const partnerId = p.memberIds.find((m) => m !== id)!;
      const partner = world.users.find((u) => u.id === partnerId)!;
      return Promise.resolve({
        pairId: p.pairId,
        startedOn: p.startedOn,
        partner,
      });
    },
    getCheckin: (userId) =>
      Promise.resolve(
        userId in world.checkins ? { photoPath: world.checkins[userId] } : null,
      ),
    listStreakDays: (pairId) =>
      Promise.resolve([...(world.streakDays[pairId] ?? [])]),
    getPlant: (pairId) => {
      const plant = world.plants.get(pairId);
      return Promise.resolve(plant ? { ...plant } : null);
    },
    dissolvePair: (pairId, dissolvedAtIso) => {
      if (world.failDissolve) return Promise.reject(new Error("db down"));
      world.dissolveCalls.push({ pairId, dissolvedAtIso });
      if (world.loseTheRace) return Promise.resolve(false);
      const p = world.pairs.find((x) => x.pairId === pairId);
      if (!p || p.status !== "active") return Promise.resolve(false);
      p.status = "dissolved";
      p.dissolvedAt = dissolvedAtIso;
      return Promise.resolve(true);
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

/** JST 2026-06-10 12:00 */
const NOW = new Date("2026-06-10T03:00:00Z");

const bothDays = (...dates: string[]): StreakDayRecord[] =>
  dates.map((d) => ({ dateLocal: d, kind: "both" as const }));

/** ペア1(A・B)とペア2(C・D)。A は今日チェックイン済み、B はまだ */
function makeWorld(overrides: Partial<World> = {}): World {
  return {
    users: [userA, userB, userC, userD],
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
        memberIds: ["user-a", "user-b"],
        status: "active",
        dissolvedAt: null,
      },
      {
        pairId: "pair-2",
        startedOn: "2026-06-01",
        memberIds: ["user-c", "user-d"],
        status: "active",
        dissolvedAt: null,
      },
    ],
    checkins: { "user-a": null },
    streakDays: {
      "pair-1": bothDays("2026-06-07", "2026-06-08", "2026-06-09"),
      "pair-2": bothDays("2026-06-09"),
    },
    plants: new Map([
      ["pair-1", { grownDays: 3, name: "みどり" }],
      ["pair-2", { grownDays: 1, name: null }],
    ]),
    dissolveCalls: [],
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

// ---- 解消する ----

Deno.test("pair-dissolve: 現役のペアを解消する — status = dissolved + dissolved_at・自分用はソロの snapshot", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  const result = await handlePairDissolve(deps(world, pusher), {
    userId: "user-a",
  });

  assertEquals(okBody(result).dissolved, true);

  const pair1 = world.pairs.find((p) => p.pairId === "pair-1")!;
  assertEquals(pair1.status, "dissolved");
  assertEquals(
    pair1.dissolvedAt,
    NOW.toISOString(),
    "status と同時に dissolved_at を打刻する(CHECK 制約)",
  );
  assertEquals(world.dissolveCalls, [{
    pairId: "pair-1",
    dissolvedAtIso: NOW.toISOString(),
  }]);

  // 自分用の snapshot: ペアが無い(ソロ)形。約束と今日の自分のチェックインは残る
  const snap = okBody(result).snapshot;
  assertEquals(snap.pairId, null);
  assertEquals(snap.partnerName, null);
  assertEquals(snap.partnerPromiseTitle, null);
  assertEquals(snap.myPromiseTitle, "筋トレ", "自分の約束は残る");
  assertEquals(snap.todayMeDone, true, "自分のチェックイン履歴は残る");
  assertEquals(snap.todayPartnerDone, false);
  assertEquals(snap.streakCurrent, 0, "ストリークはペアのもの(アーカイブ)");
  assertEquals(snap.plantName, null, "植物もアーカイブ(ソロには鉢が無い)");
  assertEquals(snap.plantStage, 0);
  assertEquals(snap.plantGrownDays, 0);
  assertEquals(snap.hasPartnerPhotoToday, false);
});

Deno.test("pair-dissolve: 行は消さない — 植物・ストリークはペアに残る(アーカイブ。復縁しても復活しない)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  await handlePairDissolve(deps(world, pusher), { userId: "user-a" });

  assertEquals(world.plants.get("pair-1")?.name, "みどり", "植物の行は残る");
  assertEquals(world.streakDays["pair-1"].length, 3, "ストリークの行は残る");
});

Deno.test("pair-dissolve: 相手へサイレント push(pair_update)— 通知 UI なし・解消後のソロの snapshot を同梱・相手の push_env を使う", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  await handlePairDissolve(deps(world, pusher), { userId: "user-a" });

  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-b");
  const payload = sent[0].payload as PushedPayload;
  assertEquals(
    payload.aps,
    { "content-available": 1 },
    "alert も sound も無いサイレント(罰・恥の演出を作らない)",
  );
  assertEquals(payload.lien.type, "pair_update");

  const snap = payload.lien.snapshot;
  assertEquals(snap.pairId, null, "相手もソロの形(ペアは解消された)");
  assertEquals(snap.partnerName, null);
  assertEquals(
    snap.myPromiseTitle,
    "ランニング",
    "受信者(相手)視点で組み立てる",
  );
  assertEquals(snap.todayMeDone, false);
  assertEquals(snap.plantName, null);

  assertEquals(
    sent[0].opts,
    { pushType: "background", priority: 5, environment: "sandbox" },
    "サイレントは background / priority 5。環境は受信者の push_env",
  );
});

Deno.test("pair-dissolve: 相手の push_token が無ければ送らない(解消は成功)", async () => {
  const world = makeWorld({
    users: [userA, { ...userB, pushToken: null }, userC, userD],
  });
  const { sent, pusher } = makePusher();

  const result = await handlePairDissolve(deps(world, pusher), {
    userId: "user-a",
  });

  assertEquals(okBody(result).dissolved, true);
  assertEquals(sent.length, 0);
});

Deno.test("pair-dissolve: push 送信が失敗(ok:false / throw)しても 200・解消は記録済み", async () => {
  for (const behavior of ["fail", "throw"] as const) {
    const world = makeWorld();
    const { sent, pusher } = makePusher(behavior);

    const result = await handlePairDissolve(deps(world, pusher), {
      userId: "user-a",
    });

    assertEquals(okBody(result).dissolved, true, behavior);
    assertEquals(sent.length, 1, behavior);
    assertEquals(world.pairs[0].status, "dissolved", behavior);
  }
});

Deno.test("pair-dissolve: どちらのメンバーからでも解消できる(相手 B からも)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const result = await handlePairDissolve(deps(world, pusher), {
    userId: "user-b",
  });

  assertEquals(okBody(result).dissolved, true);
  assertEquals(world.pairs[0].status, "dissolved");
  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-a", "相手(A)へ通知する");
  assertEquals(sent[0].opts?.environment, "production");
});

// ---- 冪等 ----

Deno.test("pair-dissolve: 二重の解消は冪等 — 2回目は dissolved:false・DB を書かない・push しない", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  const first = await handlePairDissolve(d, { userId: "user-a" });
  const second = await handlePairDissolve(d, { userId: "user-a" });
  // 相手からの再送も同じ(ペアはもう無い)
  const fromPartner = await handlePairDissolve(d, { userId: "user-b" });

  assertEquals(okBody(first).dissolved, true);
  assertEquals(okBody(second).dissolved, false);
  assertEquals(okBody(fromPartner).dissolved, false);
  assertEquals(world.dissolveCalls.length, 1, "UPDATE は1回だけ");
  assertEquals(sent.length, 1, "通知も1回だけ");

  // 再送でも、クライアントが必要とする snapshot(ソロの形)は同じように返る
  const snap = okBody(second).snapshot;
  assertEquals(snap.pairId, null);
  assertEquals(snap.myPromiseTitle, "筋トレ");
});

Deno.test("pair-dissolve: もともとソロ(ペアが無い)なら dissolved:false・何も書かない・push しない", async () => {
  const world = makeWorld({ pairs: [] });
  const { sent, pusher } = makePusher();

  const result = await handlePairDissolve(deps(world, pusher), {
    userId: "user-a",
  });

  assertEquals(okBody(result).dissolved, false);
  assertEquals(world.dissolveCalls, []);
  assertEquals(sent.length, 0);
});

Deno.test("pair-dissolve: 同時に相手が先に解消した(UPDATE が負けた)ら dissolved:false・push しない", async () => {
  const world = makeWorld({ loseTheRace: true });
  const { sent, pusher } = makePusher();

  const result = await handlePairDissolve(deps(world, pusher), {
    userId: "user-a",
  });

  assertEquals(okBody(result).dissolved, false);
  assertEquals(world.dissolveCalls.length, 1, "UPDATE は試みた");
  assertEquals(sent.length, 0, "解消を記録した側だけが相手に知らせる");
});

// ---- 範囲と失敗 ----

Deno.test("pair-dissolve: 本人のペアだけ — 他のペア(C・D)には触れない", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  await handlePairDissolve(deps(world, pusher), { userId: "user-a" });

  const pair2 = world.pairs.find((p) => p.pairId === "pair-2")!;
  assertEquals(pair2.status, "active");
  assertEquals(pair2.dissolvedAt, null);
  assertEquals(sent.map((s) => s.deviceToken), ["token-b"]);
  assertEquals(world.dissolveCalls.map((c) => c.pairId), ["pair-1"]);
});

Deno.test("pair-dissolve: users 行が無ければ 404 user_not_found(何も書かない)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const result = await handlePairDissolve(deps(world, pusher), {
    userId: "user-x",
  });

  assertEquals(result.status, 404);
  assertEquals(result.body, { error: "user_not_found" });
  assertEquals(world.dissolveCalls, []);
  assertEquals(sent.length, 0);
});

Deno.test("pair-dissolve: DB の更新が失敗したら例外(index.ts が 500)— push は送らない・ペアは現役のまま", async () => {
  const world = makeWorld({ failDissolve: true });
  const { sent, pusher } = makePusher();

  let threw = false;
  try {
    await handlePairDissolve(deps(world, pusher), { userId: "user-a" });
  } catch {
    threw = true;
  }

  assertEquals(threw, true);
  assertEquals(
    world.pairs[0].status,
    "active",
    "半端に解消された状態にならない",
  );
  assertEquals(sent.length, 0);
});

// ---- _shared/pair_dissolve.ts ----

Deno.test("dissolveActivePair: 解消したときだけ相手(push_token と push_env つき)を返す", async () => {
  const world = makeWorld();
  const repo = makeRepo(world);

  const first = await dissolveActivePair(repo, { userId: "user-a", now: NOW });
  assertEquals(first.dissolved, true);
  assertEquals(first.pairId, "pair-1");
  assertEquals(first.partner?.id, "user-b");
  assertEquals(first.partner?.pushToken, "token-b");
  assertEquals(first.partner?.pushEnv, "sandbox");

  const again = await dissolveActivePair(repo, { userId: "user-a", now: NOW });
  assertEquals(again, { dissolved: false, pairId: null, partner: null });
});
