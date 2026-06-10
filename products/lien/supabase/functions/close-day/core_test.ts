// core_test.ts — close-day/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.4(確定処理=正本)/ §5.3 / REQUIREMENTS §3.5 / §3.6
//
// 判定そのもの(decideCloseDay)の全分岐は _shared/streak_test.ts が担保済み。
// ここでは「確定→DB反映→push」のオーケストレーションと再実行の冪等性を検証する。

import {
  type CloseDayPairRow,
  type CloseDayRepo,
  handleCloseDay,
} from "./core.ts";
import type {
  PairSnapshot,
  SnapshotPairRow,
  SnapshotPromiseRow,
  SnapshotUserRow,
} from "../_shared/snapshot.ts";
import type { StreakDayKind, StreakDayRecord } from "../_shared/streak.ts";
import type { Pusher } from "../checkin/core.ts";

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

function assert(cond: boolean, msg = ""): void {
  if (!cond) throw new Error(`assert failed: ${msg}`);
}

// ---- fake repo / pusher ----

interface World {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>;
  pairs: CloseDayPairRow[];
  /** key: `${userId}|${dateLocal}` */
  checkins: Set<string>;
  /** key: `${pairId}|${dateLocal}` */
  streakDays: Map<string, StreakDayKind>;
  /** お休み宣言済み。key: `${pairId}|${dateLocal}` */
  declares: Set<string>;
  ledger: Array<{
    pairId: string;
    delta: number;
    reason: string;
    dateLocal: string;
  }>;
  plants: Map<string, { grownDays: number; stage: number }>;
  resets: Array<{ pairId: string; dateLocal: string }>;
  /** このペアIDの getStreakDay を throw させる(エラー隔離テスト用) */
  failPairIds: Set<string>;
}

function makeRepo(world: World): CloseDayRepo {
  return {
    getUser: (id) =>
      Promise.resolve(world.users.find((u) => u.id === id) ?? null),
    getActivePromise: (id) => Promise.resolve(world.promises[id] ?? null),
    getActivePair: (id): Promise<SnapshotPairRow | null> => {
      const p = world.pairs.find(
        (x) => x.status === "active" && x.memberIds.includes(id),
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
    getCheckin: (id, dateLocal) =>
      Promise.resolve(
        world.checkins.has(`${id}|${dateLocal}`) ? { photoPath: null } : null,
      ),
    listStreakDays: (pairId): Promise<StreakDayRecord[]> =>
      Promise.resolve(
        [...world.streakDays.entries()]
          .filter(([k]) => k.startsWith(`${pairId}|`))
          .map(([k, kind]) => ({ dateLocal: k.split("|")[1], kind })),
      ),
    getPlant: (pairId) => {
      const p = world.plants.get(pairId);
      return Promise.resolve(
        p ? { grownDays: p.grownDays, name: null } : null,
      );
    },

    // 確定対象の列挙: core 側の decideCloseDay ガード(status / started_on)を
    // 検証するため、フェイクはあえて絞り込まず全ペアを返す(過剰列挙でも安全)
    listPairsForClose: () => Promise.resolve([...world.pairs]),
    getStreakDay: (pairId, dateLocal) => {
      if (world.failPairIds.has(pairId)) {
        return Promise.reject(new Error("db down"));
      }
      return Promise.resolve(
        world.streakDays.get(`${pairId}|${dateLocal}`) ?? null,
      );
    },
    hasRestDeclared: (pairId, dateLocal) =>
      Promise.resolve(world.declares.has(`${pairId}|${dateLocal}`)),
    upsertStreakDay: (pairId, dateLocal, kind) => {
      const key = `${pairId}|${dateLocal}`;
      if (!world.streakDays.has(key)) world.streakDays.set(key, kind);
      return Promise.resolve();
    },
    updateTicketBalance: (pairId, balance) => {
      const p = world.pairs.find((x) => x.pairId === pairId)!;
      p.ticketBalance = balance;
      return Promise.resolve();
    },
    insertTicketLedger: (params) => {
      world.ledger.push({ ...params });
      return Promise.resolve();
    },
    updatePlantGrowth: (pairId, grownDays, stage) => {
      world.plants.set(pairId, { grownDays, stage });
      return Promise.resolve();
    },
    recordStreakReset: (pairId, dateLocal) => {
      world.resets.push({ pairId, dateLocal });
      return Promise.resolve();
    },
  };
}

interface SentPush {
  deviceToken: string;
  payload: Record<string, unknown>;
}

function makePusher(): { sent: SentPush[]; pusher: Pusher } {
  const sent: SentPush[] = [];
  return {
    sent,
    pusher: {
      send: (deviceToken, payload) => {
        sent.push({ deviceToken, payload });
        return Promise.resolve({ ok: true });
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

/** cron 実行時刻: JST 2026-06-11 00:10 → 前日 d = 2026-06-10 */
const NOW = new Date("2026-06-10T15:10:00Z");
const D = "2026-06-10";

function basePair(overrides: Partial<CloseDayPairRow> = {}): CloseDayPairRow {
  return {
    pairId: "pair-1",
    status: "active",
    startedOn: "2026-06-01",
    ticketBalance: 2,
    memberIds: ["user-a", "user-b"],
    ...overrides,
  };
}

function makeWorld(overrides: Partial<World> = {}): World {
  const world: World = {
    users: [userA, userB],
    promises: {
      "user-a": { id: "prom-a", title: "筋トレ", emoji: "💪" },
      "user-b": { id: "prom-b", title: "ランニング", emoji: "🏃" },
    },
    pairs: [basePair()],
    checkins: new Set(),
    streakDays: new Map(),
    declares: new Set(),
    ledger: [],
    plants: new Map([["pair-1", { grownDays: 13, stage: 2 }]]),
    resets: [],
    failPairIds: new Set(),
    ...overrides,
  };
  // 確定済みの連続5日(6/5〜6/9 both)
  for (
    const d of [
      "2026-06-05",
      "2026-06-06",
      "2026-06-07",
      "2026-06-08",
      "2026-06-09",
    ]
  ) {
    if (!overrides.streakDays) world.streakDays.set(`pair-1|${d}`, "both");
  }
  return world;
}

function deps(world: World, pusher: Pusher) {
  return { repo: makeRepo(world), pusher, now: () => NOW };
}

// ---- 本体テスト ----

Deno.test("close-day: 既定の対象日は JST の前日(00:10 JST 実行 → d = 昨日)", async () => {
  const world = makeWorld({ pairs: [] });
  const { pusher } = makePusher();
  const result = await handleCloseDay(deps(world, pusher), {});
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.dateLocal, D);
});

Deno.test("close-day: 両者達成 → streak_days(d,'both')+植物の成長 grown_days+1(push なし)", async () => {
  const world = makeWorld();
  world.checkins.add(`user-a|${D}`).add(`user-b|${D}`);
  const { sent, pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.recordedBoth, 1);
  assertEquals(world.streakDays.get(`pair-1|${D}`), "both");
  assertEquals(
    world.plants.get("pair-1"),
    { grownDays: 14, stage: 3 },
    "累計14日で若葉へ昇格(REQUIREMENTS §3.9)",
  );
  assertEquals(world.ledger.length, 0);
  assertEquals(
    world.pairs[0].ticketBalance,
    2,
    "チケットは減らない",
  );
  assertEquals(
    sent.length,
    0,
    "両者は checkin 時に通知済み。close-day は送らない",
  );
});

Deno.test("close-day: 片方未達+チケットあり → balance-1・ledger consume・ticket_used push(DESIGN §5.4-3)", async () => {
  const world = makeWorld();
  world.checkins.add(`user-a|${D}`); // B が未達
  const { sent, pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.recordedTicket, 1);
  assertEquals(world.streakDays.get(`pair-1|${D}`), "ticket");
  assertEquals(world.pairs[0].ticketBalance, 1);
  assertEquals(world.ledger, [
    { pairId: "pair-1", delta: -1, reason: "consume", dateLocal: D },
  ]);
  assertEquals(world.plants.get("pair-1"), {
    grownDays: 13,
    stage: 2,
  }, "ticket の日は達成日ではないので植物は成長しない");

  // 両者へ ticket_used push(snapshot 同梱・システム名義)
  assertEquals(sent.length, 2);
  assertEquals(
    sent.map((s) => s.deviceToken).sort(),
    ["token-a", "token-b"],
  );
  const payload = sent[0].payload as {
    aps: { alert: { title: string; body: string } };
    lien: { type: string; snapshot: PairSnapshot };
  };
  assertEquals(payload.aps.alert.title, "Lien");
  assertEquals(
    payload.aps.alert.body,
    "お休みチケットを1枚つかって、ふたりの記録をまもったよ🎟️",
  );
  assertEquals(payload.lien.type, "ticket_used");
  assertEquals(
    payload.lien.snapshot.streakCurrent,
    6,
    "ticket の日も継続日(6/5〜6/10 で 6)",
  );
  assertEquals(payload.lien.snapshot.todayMeDone, false, "新しい日はまだ未完");
});

Deno.test("close-day: 2人とも未達でも消費は1日1枚(人数で数えない — DESIGN §5.4)", async () => {
  const world = makeWorld(); // 誰もチェックインしていない
  const { sent, pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.recordedTicket, 1);
  assertEquals(world.pairs[0].ticketBalance, 1, "2人未達でも -1 だけ");
  assertEquals(world.ledger.length, 1);
  assertEquals(sent.length, 2);
});

Deno.test("close-day: 事前お休み宣言済みの日は追加消費なしで継続(REQUIREMENTS §3.6)", async () => {
  const world = makeWorld();
  world.declares.add(`pair-1|${D}`); // 宣言時に減算済みの想定
  const { sent, pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.recordedTicket, 1);
  assertEquals(world.streakDays.get(`pair-1|${D}`), "ticket");
  assertEquals(world.pairs[0].ticketBalance, 2, "追加消費しない");
  assertEquals(world.ledger.length, 0, "consume の二重記録をしない");
  assertEquals(sent.length, 2, "継続の通知は送る");
});

Deno.test("close-day: チケットなし → 行を作らない・streak_reset記録・責めない文言push(DESIGN §5.4-4)", async () => {
  const world = makeWorld();
  world.pairs[0].ticketBalance = 0;
  world.checkins.add(`user-a|${D}`); // B が未達
  const { sent, pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.reset, 1);
  assertEquals(
    world.streakDays.has(`pair-1|${D}`),
    false,
    "行を作らない=途切れ",
  );
  assertEquals(world.resets, [{ pairId: "pair-1", dateLocal: D }]);
  assertEquals(world.ledger.length, 0);

  assertEquals(sent.length, 2);
  const payload = sent[0].payload as {
    aps: { alert: { title: string; body: string } };
    lien: { type: string; snapshot: PairSnapshot };
  };
  assertEquals(payload.aps.alert.title, "Lien");
  assertEquals(
    payload.aps.alert.body,
    "また今日から。最高記録 5日 はふたりの財産だよ🌱",
    "最高記録はふたりの財産(REQUIREMENTS §3.5)",
  );
  // 罰・恥系の表現を含まない(REQUIREMENTS §3.5 / DESIGN §3.8)
  assert(
    !/枯れ|サボ|罰|恥|ダメ|怒|遅い|まだやってない/.test(
      payload.aps.alert.body,
    ),
    "責めない文言のみ",
  );
  assertEquals(payload.lien.type, "streak_reset");
  assertEquals(payload.lien.snapshot.streakCurrent, 0, "リセット後の現在値");
});

Deno.test("close-day: 履歴なしのリセットは最高記録に触れない文言", async () => {
  const world = makeWorld({ streakDays: new Map() });
  world.pairs[0].ticketBalance = 0;
  const { sent, pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  const payload = sent[0].payload as {
    aps: { alert: { body: string } };
  };
  assertEquals(
    payload.aps.alert.body,
    "また今日から、ふたりのペースで始めよう🌱",
  );
});

Deno.test("close-day: 再実行は冪等 — 2回目はすべて skip で何も増えない(DESIGN §5.4)", async () => {
  const world = makeWorld();
  world.checkins.add(`user-a|${D}`); // チケット消費パターン
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  const first = await handleCloseDay(d, {});
  assertEquals(first.status, 200);
  if (first.status !== 200) throw new Error("unreachable");
  assertEquals(first.body.recordedTicket, 1);

  const second = await handleCloseDay(d, {});
  assertEquals(second.status, 200);
  if (second.status !== 200) throw new Error("unreachable");
  assertEquals(second.body.recordedTicket, 0);
  assertEquals(second.body.skipped, 1, "確定済みの日は skip");

  assertEquals(world.pairs[0].ticketBalance, 1, "balance は二重に減らない");
  assertEquals(world.ledger.length, 1, "ledger は二重記録しない");
  assertEquals(sent.length, 2, "push は再送しない");

  // both パターンの再実行でも植物が二重成長しない
  const w2 = makeWorld();
  w2.checkins.add(`user-a|${D}`).add(`user-b|${D}`);
  const { pusher: p2 } = makePusher();
  const d2 = deps(w2, p2);
  await handleCloseDay(d2, {});
  await handleCloseDay(d2, {});
  assertEquals(w2.plants.get("pair-1"), { grownDays: 14, stage: 3 });
});

Deno.test("close-day: 対象外ペアは skip — started_on より前・dissolved(DESIGN §5.4-1)", async () => {
  const world = makeWorld({
    pairs: [
      basePair({ pairId: "pair-future", startedOn: "2026-06-11" }), // 成立は d より後
      basePair({ pairId: "pair-dissolved", status: "dissolved" }),
    ],
    plants: new Map(),
    streakDays: new Map(),
  });
  const { sent, pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.skipped, 2);
  assertEquals(result.body.recordedBoth + result.body.recordedTicket, 0);
  assertEquals(result.body.reset, 0);
  assertEquals(world.streakDays.size, 0);
  assertEquals(sent.length, 0);
});

Deno.test("close-day: ペア成立当日(started_on = d)は判定対象(DESIGN §5.4 の例3)", async () => {
  const world = makeWorld({
    pairs: [basePair({ startedOn: D })],
    streakDays: new Map(),
    plants: new Map([["pair-1", { grownDays: 0, stage: 0 }]]),
  });
  world.checkins.add(`user-a|${D}`).add(`user-b|${D}`);
  const { pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.recordedBoth, 1);
  assertEquals(world.streakDays.get(`pair-1|${D}`), "both");
});

Deno.test("close-day: 1ペアの失敗は隔離 — 他ペアは処理されエラーは報告される", async () => {
  const pairOk = basePair({
    pairId: "pair-ok",
    memberIds: ["user-a", "user-b"],
  });
  const pairNg = basePair({
    pairId: "pair-ng",
    memberIds: ["user-a", "user-b"],
  });
  const world = makeWorld({
    pairs: [pairNg, pairOk],
    streakDays: new Map(),
    plants: new Map([
      ["pair-ok", { grownDays: 0, stage: 0 }],
      ["pair-ng", { grownDays: 0, stage: 0 }],
    ]),
    failPairIds: new Set(["pair-ng"]),
  });
  world.checkins.add(`user-a|${D}`).add(`user-b|${D}`);
  const { pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.recordedBoth, 1, "正常ペアは確定される");
  assertEquals(result.body.errors.length, 1);
  assertEquals(result.body.errors[0].pairId, "pair-ng");
});

Deno.test("close-day: dateLocal 指定で過去日を再処理できる・不正な日付は 400", async () => {
  const world = makeWorld();
  world.checkins.add("user-a|2026-06-04").add("user-b|2026-06-04");
  const { pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {
    dateLocal: "2026-06-04",
  });
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.dateLocal, "2026-06-04");
  assertEquals(world.streakDays.get("pair-1|2026-06-04"), "both");

  const bad = await handleCloseDay(deps(world, pusher), {
    dateLocal: "2026-6-4",
  });
  assertEquals(bad.status, 400);
});

Deno.test("close-day: push_token の無いメンバーには送らない(処理は成功)", async () => {
  const noTokenB = { ...userB, pushToken: null };
  const world = makeWorld({ users: [userA, noTokenB] });
  world.checkins.add(`user-a|${D}`); // チケット消費 → push 発生パターン
  const { sent, pusher } = makePusher();

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.recordedTicket, 1);
  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-a");
});

Deno.test("close-day: push が throw しても確定処理は成功扱い(DESIGN §5.5)", async () => {
  const world = makeWorld();
  world.checkins.add(`user-a|${D}`);
  const pusher: Pusher = {
    send: () => Promise.reject(new Error("apns down")),
  };

  const result = await handleCloseDay(deps(world, pusher), {});

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.recordedTicket, 1);
  assertEquals(result.body.errors.length, 0);
  assertEquals(world.streakDays.get(`pair-1|${D}`), "ticket");
});
