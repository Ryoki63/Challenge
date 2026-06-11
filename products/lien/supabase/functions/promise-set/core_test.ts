// core_test.ts — promise-set/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/REQUIREMENTS.md §3.3(1人1つ・20字・編集してもストリーク継続)
//        / docs/DESIGN.md §5.3(promise-set)/ §4(サイレントpush = content-available: 1)

import {
  handlePromiseSet,
  type PromiseRow,
  type PromiseSetRepo,
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

// ---- fake repo / pusher(checkin-cancel/core_test.ts と同じ世界) ----

interface World {
  users: SnapshotUserRow[];
  /** userId → 現役の約束(remindAt 込みの完全な行) */
  promises: Map<string, PromiseRow>;
  pair:
    | { pairId: string; startedOn: string; memberIds: [string, string] }
    | null;
  checkins: Map<string, { photoPath: string | null }>; // key: `${userId}|${dateLocal}`
  streakDays: StreakDayRecord[];
  plant: SnapshotPlantRow | null;
  nextId: number;
}

function makeRepo(world: World): PromiseSetRepo {
  return {
    getUser: (id) =>
      Promise.resolve(world.users.find((u) => u.id === id) ?? null),
    getActivePromise: (id): Promise<SnapshotPromiseRow | null> => {
      const p = world.promises.get(id);
      return Promise.resolve(
        p ? { id: p.id, title: p.title, emoji: p.emoji } : null,
      );
    },
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
    upsertActivePromise: (params) => {
      const existing = world.promises.get(params.userId);
      if (existing) {
        // 同一 id への UPDATE(archive+insert しない — REQUIREMENTS §3.3)
        const updated: PromiseRow = {
          id: existing.id,
          title: params.title,
          emoji: params.emoji,
          remindAt: params.remindAt,
        };
        world.promises.set(params.userId, updated);
        return Promise.resolve({ promise: { ...updated }, created: false });
      }
      const created: PromiseRow = {
        id: `prom-${world.nextId++}`,
        title: params.title,
        emoji: params.emoji,
        remindAt: params.remindAt,
      };
      world.promises.set(params.userId, created);
      return Promise.resolve({ promise: { ...created }, created: true });
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

/** JST 2026-06-10 12:00。todayLocal = 2026-06-10 */
const NOW = new Date("2026-06-10T03:00:00Z");

function makeWorld(overrides: Partial<World> = {}): World {
  return {
    users: [userA, userB],
    promises: new Map([
      ["user-b", {
        id: "prom-b",
        title: "ランニング",
        emoji: "🏃",
        remindAt: null,
      }],
    ]),
    pair: {
      pairId: "pair-1",
      startedOn: "2026-06-01",
      memberIds: ["user-a", "user-b"],
    },
    checkins: new Map(),
    streakDays: [],
    plant: { grownDays: 0, name: null },
    nextId: 1,
    ...overrides,
  };
}

function deps(world: World, pusher: Pusher) {
  return { repo: makeRepo(world), pusher, now: () => NOW };
}

// ---- 本体テスト ----

Deno.test("promise-set: 新規作成成功 — 200+created:true、相手へ pair_update サイレントpush(受信者視点snapshot同梱)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const result = await handlePromiseSet(deps(world, pusher), {
    userId: "user-a",
    title: "筋トレ",
    emoji: "💪",
    remindAt: "20:00",
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.created, true);
  assertEquals(result.body.promise, {
    id: "prom-1",
    title: "筋トレ",
    emoji: "💪",
    remindAt: "20:00",
  });

  // push: 受信者(B)視点の snapshot — B から見ると「相手の約束」が筋トレに更新されている
  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-b");
  assertEquals(
    sent[0].opts,
    { pushType: "background", priority: 5 },
    "サイレントは apns-push-type: background / priority 5",
  );
  const payload = sent[0].payload as {
    aps: Record<string, unknown>;
    lien: { type: string; snapshot: PairSnapshot };
  };
  assertEquals(payload.aps, { "content-available": 1 }, "alert/sound なし");
  assertEquals(payload.lien.type, "pair_update");
  assertEquals(payload.lien.snapshot.myPromiseTitle, "ランニング");
  assertEquals(payload.lien.snapshot.partnerPromiseTitle, "筋トレ");
  assertEquals(payload.lien.snapshot.partnerPromiseEmoji, "💪");
  assertEquals(payload.lien.snapshot.partnerName, "あきら");
});

Deno.test("promise-set: 既存更新は同一 promise_id への UPDATE — id 不変(checkins FK 継続=ストリーク非影響 §3.3)", async () => {
  const world = makeWorld();
  world.promises.set("user-a", {
    id: "prom-a-original",
    title: "筋トレ",
    emoji: "💪",
    remindAt: "20:00",
  });
  const { pusher } = makePusher();

  const result = await handlePromiseSet(deps(world, pusher), {
    userId: "user-a",
    title: "朝ストレッチ",
    emoji: "🧘",
    remindAt: null,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.created, false, "新規ではなく更新");
  assertEquals(result.body.promise, {
    id: "prom-a-original", // id が変わらない = checkins.promise_id の FK が生き続ける
    title: "朝ストレッチ",
    emoji: "🧘",
    remindAt: null,
  });
});

Deno.test("promise-set: 他人(相手)の約束には触れない — 自分の upsert 後も相手の行は不変", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  const result = await handlePromiseSet(deps(world, pusher), {
    userId: "user-a",
    title: "筋トレ",
    emoji: "💪",
  });

  assertEquals(result.status, 200);
  assertEquals(world.promises.get("user-b"), {
    id: "prom-b",
    title: "ランニング",
    emoji: "🏃",
    remindAt: null,
  }, "B の約束は元のまま");
});

Deno.test("promise-set: title バリデーション — 空・空白のみ・21字は 400、20字ちょうどは OK(コードポイントで数える)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  for (const bad of ["", "   ", "\n\t"]) {
    const r = await handlePromiseSet(d, {
      userId: "user-a",
      title: bad,
      emoji: "💪",
    });
    assertEquals(r.status, 400, `title=${JSON.stringify(bad)}`);
    if (r.status !== 400) throw new Error("unreachable");
    assertEquals(r.body.error, "invalid_title");
  }

  const over = await handlePromiseSet(d, {
    userId: "user-a",
    title: "あ".repeat(21),
    emoji: "💪",
  });
  assertEquals(over.status, 400, "21字は拒否");

  // 絵文字(サロゲートペア)20個 = UTF-16 では40だがコードポイントでは20 → OK
  // (DB の char_length(title) <= 20 と同じ数え方であることの検査)
  const exact = await handlePromiseSet(d, {
    userId: "user-a",
    title: "💪".repeat(20),
    emoji: "💪",
  });
  assertEquals(exact.status, 200, "コードポイント20字ちょうどは通る");

  // trim 後に 20 字に収まる(前後空白は字数に入れない)
  const padded = await handlePromiseSet(d, {
    userId: "user-a",
    title: `  ${"あ".repeat(20)}  `,
    emoji: "💪",
  });
  assertEquals(padded.status, 200, "trim 後 20 字は通る");
  if (padded.status !== 200) throw new Error("unreachable");
  assertEquals(
    padded.body.promise.title,
    "あ".repeat(20),
    "保存値は trim 済み",
  );
});

Deno.test("promise-set: emoji バリデーション — 欠落(空)は 400、ZWJ 合成絵文字は OK", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  for (const bad of ["", "  "]) {
    const r = await handlePromiseSet(d, {
      userId: "user-a",
      title: "筋トレ",
      emoji: bad,
    });
    assertEquals(r.status, 400, `emoji=${JSON.stringify(bad)}`);
    if (r.status !== 400) throw new Error("unreachable");
    assertEquals(r.body.error, "invalid_emoji");
  }

  // 家族絵文字(ZWJ 合成・7コードポイント)は上限8以内 → OK
  const zwj = await handlePromiseSet(d, {
    userId: "user-a",
    title: "筋トレ",
    emoji: "👨‍👩‍👧‍👦",
  });
  assertEquals(zwj.status, 200);

  // 長すぎる文字列(絵文字欄への文章入力)は拒否
  const tooLong = await handlePromiseSet(d, {
    userId: "user-a",
    title: "筋トレ",
    emoji: "ながいもじれつはきょひ",
  });
  assertEquals(tooLong.status, 400);
  if (tooLong.status !== 400) throw new Error("unreachable");
  assertEquals(tooLong.body.error, "invalid_emoji");
});

Deno.test("promise-set: remindAt 形式不正は 400、'HH:MM'・null・未指定は OK", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  for (
    const bad of ["24:00", "20:60", "8:00", "20:0", "20:00:00", "8pm", " "]
  ) {
    const r = await handlePromiseSet(d, {
      userId: "user-a",
      title: "筋トレ",
      emoji: "💪",
      remindAt: bad,
    });
    assertEquals(r.status, 400, `remindAt=${JSON.stringify(bad)}`);
    if (r.status !== 400) throw new Error("unreachable");
    assertEquals(r.body.error, "invalid_remind_at");
  }

  for (
    const ok of [
      { remindAt: "00:00", expect: "00:00" },
      { remindAt: "23:59", expect: "23:59" },
      { remindAt: null, expect: null },
      { remindAt: undefined, expect: null },
    ]
  ) {
    const r = await handlePromiseSet(d, {
      userId: "user-a",
      title: "筋トレ",
      emoji: "💪",
      remindAt: ok.remindAt,
    });
    assertEquals(r.status, 200, `remindAt=${JSON.stringify(ok.remindAt)}`);
    if (r.status !== 200) throw new Error("unreachable");
    assertEquals(r.body.promise.remindAt, ok.expect);
  }
});

Deno.test("promise-set: バリデーション拒否時は DB に書かず push もしない", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const r = await handlePromiseSet(deps(world, pusher), {
    userId: "user-a",
    title: "",
    emoji: "💪",
  });

  assertEquals(r.status, 400);
  assertEquals(world.promises.has("user-a"), false, "行を作らない");
  assertEquals(sent.length, 0, "push しない");
});

Deno.test("promise-set: ソロ状態(未ペア)でも保存は成功・push なし", async () => {
  const world = makeWorld({ pair: null, plant: null });
  const { sent, pusher } = makePusher();

  const result = await handlePromiseSet(deps(world, pusher), {
    userId: "user-a",
    title: "まいにち散歩",
    emoji: "🚶",
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.created, true);
  assertEquals(result.body.promise.title, "まいにち散歩");
  assertEquals(sent.length, 0, "ソロは push 先がない");
});

Deno.test("promise-set: 相手に push_token が無ければ push せず成功", async () => {
  const noTokenB = { ...userB, pushToken: null };
  const world = makeWorld({ users: [userA, noTokenB] });
  const { sent, pusher } = makePusher();

  const result = await handlePromiseSet(deps(world, pusher), {
    userId: "user-a",
    title: "筋トレ",
    emoji: "💪",
  });
  assertEquals(result.status, 200);
  assertEquals(sent.length, 0);
});

Deno.test("promise-set: push 失敗(ok:false / throw)でも 200(サイレントはフォールバック — DESIGN §4)", async () => {
  for (const behavior of ["fail", "throw"] as const) {
    const world = makeWorld();
    const { sent, pusher } = makePusher(behavior);
    const result = await handlePromiseSet(deps(world, pusher), {
      userId: "user-a",
      title: "筋トレ",
      emoji: "💪",
    });
    assertEquals(result.status, 200, `pusher=${behavior}`);
    assertEquals(sent.length, 1, "送信自体は試みる");
    assertEquals(
      world.promises.get("user-a")?.title,
      "筋トレ",
      "保存は成立",
    );
  }
});

Deno.test("promise-set: ユーザー不在は 404", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const result = await handlePromiseSet(deps(world, pusher), {
    userId: "user-zzz",
    title: "筋トレ",
    emoji: "💪",
  });
  assertEquals(result.status, 404);
  if (result.status !== 404) throw new Error("unreachable");
  assertEquals(result.body.error, "user_not_found");
  assertEquals(sent.length, 0);
});
