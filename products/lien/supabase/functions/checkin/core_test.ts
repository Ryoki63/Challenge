// core_test.ts — checkin/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.3(checkin)/ §5.5(冪等性)/ §4(ペイロード)/ REQUIREMENTS §3.4

import { type CheckinRepo, handleCheckin, type Pusher } from "./core.ts";
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

function makeRepo(world: World): CheckinRepo {
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
    upsertCheckin: (params) => {
      const key = `${params.userId}|${params.dateLocal}`;
      const existing = world.checkins.get(key);
      if (!existing) {
        world.checkins.set(key, { photoPath: params.photoPath });
        return Promise.resolve({ created: true, photoUpdated: false });
      }
      if (
        params.photoPath !== null && existing.photoPath !== params.photoPath
      ) {
        existing.photoPath = params.photoPath;
        return Promise.resolve({ created: false, photoUpdated: true });
      }
      return Promise.resolve({ created: false, photoUpdated: false });
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
  return { repo: makeRepo(world), pusher, now: () => NOW, random: () => 0 };
}

// ---- 本体テスト ----

Deno.test("checkin: 初回(相手未完)— 自分用snapshot返却+相手へ可視push(snapshot同梱)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyCheckedIn, false);

  const expectedMine: PairSnapshot = {
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
    plantStage: 2,
    plantMood: "fidget",
    plantName: "みどり",
    hasPartnerPhotoToday: false,
  };
  assertEquals(result.body.snapshot, expectedMine, "自分用 snapshot");

  // push: 受信者(B)視点の snapshot を同梱した可視プッシュ(DESIGN §4)
  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-b");
  const expectedPartner: PairSnapshot = {
    ...expectedMine,
    todayMeDone: false,
    todayPartnerDone: true,
    myPromiseTitle: "ランニング",
    myPromiseEmoji: "🏃",
    partnerName: "あきら",
    partnerPromiseTitle: "筋トレ",
    partnerPromiseEmoji: "💪",
  };
  assertEquals(sent[0].payload, {
    aps: {
      alert: { title: "あきら", body: "筋トレやった!💪" },
      sound: "default",
      "mutable-content": 1,
    },
    lien: { type: "partner_checkin", snapshot: expectedPartner },
  });
});

Deno.test("checkin: 2人目の完了で両者達成 — プレビュー+1・happy・植物昇格", async () => {
  const world = makeWorld();
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null }); // A は完了済み
  const { sent, pusher } = makePusher();

  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-b",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  const s = result.body.snapshot;
  assertEquals(s.todayMeDone, true);
  assertEquals(s.todayPartnerDone, true);
  assertEquals(
    s.streakCurrent,
    6,
    "確定5+今日両者完了で6(DESIGN §5.4 プレビュー)",
  );
  assertEquals(s.streakBest, 6);
  assertEquals(s.plantStage, 3, "累計13+1=14日で若葉");
  assertEquals(s.plantMood, "happy");

  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-a");
  const partnerView = (sent[0].payload.lien as { snapshot: PairSnapshot })
    .snapshot;
  assertEquals(partnerView.todayMeDone, true);
  assertEquals(partnerView.todayPartnerDone, true);
  assertEquals(partnerView.streakCurrent, 6);
  assertEquals(partnerView.plantMood, "happy");
});

Deno.test("checkin: 重複リクエストは 200 冪等・push は再送しない(DESIGN §5.5)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  const first = await handleCheckin(d, { userId: "user-a", dateLocal: TODAY });
  const second = await handleCheckin(d, { userId: "user-a", dateLocal: TODAY });

  assertEquals(first.status, 200);
  assertEquals(second.status, 200);
  if (first.status !== 200 || second.status !== 200) {
    throw new Error("unreachable");
  }
  assertEquals(first.body.alreadyCheckedIn, false);
  assertEquals(second.body.alreadyCheckedIn, true);
  assertEquals(
    second.body.snapshot,
    first.body.snapshot,
    "snapshot は同じ状態を返す",
  );
  assertEquals(sent.length, 1, "通知は二重発火しない");
});

Deno.test("checkin: 完了後の写真添付 — 写真を更新し photo 文言で push(hasPartnerPhotoToday)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  await handleCheckin(d, { userId: "user-a", dateLocal: TODAY });
  const result = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: "pairs/pair-1/2026-06-10/a.jpg",
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyCheckedIn, true);

  assertEquals(sent.length, 2, "写真追加は通知する(REQUIREMENTS §3.12)");
  const payload = sent[1].payload as {
    aps: { alert: { title: string; body: string } };
    lien: { snapshot: PairSnapshot };
  };
  assertEquals(payload.aps.alert.body, "今日の写真を添えたよ📷");
  assertEquals(
    payload.lien.snapshot.hasPartnerPhotoToday,
    true,
    "B 視点では相手(A)の写真がある",
  );
});

Deno.test("checkin: 写真パスはペア規約 'pairs/<pair_id>/...' 以外を拒否", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const wrongPair = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: "pairs/other-pair/photo.jpg",
  });
  assertEquals(wrongPair.status, 400);
  if (wrongPair.status !== 400) throw new Error("unreachable");
  assertEquals(wrongPair.body.error, "invalid_photo_path");

  const soloWorld = makeWorld({ pair: null });
  const soloPhoto = await handleCheckin(deps(soloWorld, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: "pairs/pair-1/photo.jpg",
  });
  assertEquals(soloPhoto.status, 400, "ソロ状態の写真は置き場所(ペア)がない");
  assertEquals(sent.length, 0);
});

Deno.test("checkin: ソロ状態 — pairId null の snapshot・push なし", async () => {
  const world = makeWorld({ pair: null, streakDays: [], plant: null });
  const { sent, pusher } = makePusher();

  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  const expected: PairSnapshot = {
    schemaVersion: 1,
    pairId: null,
    updatedAt: "2026-06-10T03:00:00.000Z",
    streakCurrent: 0,
    streakBest: 0,
    todayMeDone: true,
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
  assertEquals(result.body.snapshot, expected);
  assertEquals(sent.length, 0, "ソロは push 先がない");
});

Deno.test("checkin: 現役の約束が無いと 409 no_promise", async () => {
  const world = makeWorld({ promises: {} });
  const { sent, pusher } = makePusher();
  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });
  assertEquals(result.status, 409);
  if (result.status !== 409) throw new Error("unreachable");
  assertEquals(result.body.error, "no_promise");
  assertEquals(sent.length, 0);
});

Deno.test("checkin: ユーザー不在は 404", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-zzz",
    dateLocal: TODAY,
  });
  assertEquals(result.status, 404);
});

Deno.test("checkin: 日付検証 — 形式不正は 400、±1日超(遡及)も 400、±1日は許容", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  const malformed = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: "2026-6-10",
  });
  assertEquals(malformed.status, 400);
  if (malformed.status !== 400) throw new Error("unreachable");
  assertEquals(malformed.body.error, "invalid_date_local");

  const tooOld = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: "2026-06-05",
  });
  assertEquals(tooOld.status, 400, "遡及チェックイン不可(REQUIREMENTS §3.4)");
  if (tooOld.status !== 400) throw new Error("unreachable");
  assertEquals(tooOld.body.error, "date_local_out_of_range");

  const yesterday = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: "2026-06-09",
  });
  assertEquals(yesterday.status, 200, "±1日は時計ずれ・再送として許容");
});

Deno.test("checkin: 相手に push_token が無ければ push せず成功", async () => {
  const noTokenB = { ...userB, pushToken: null };
  const world = makeWorld({ users: [userA, noTokenB] });
  const { sent, pusher } = makePusher();
  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });
  assertEquals(result.status, 200);
  assertEquals(sent.length, 0);
});

Deno.test("checkin: push 失敗(ok:false / throw)でも処理は成功扱い(DESIGN §5.5)", async () => {
  for (const behavior of ["fail", "throw"] as const) {
    const world = makeWorld();
    const { sent, pusher } = makePusher(behavior);
    const result = await handleCheckin(deps(world, pusher), {
      userId: "user-a",
      dateLocal: TODAY,
    });
    assertEquals(result.status, 200, `pusher=${behavior}`);
    assertEquals(sent.length, 1, "送信自体は試みる");
  }
});

Deno.test("checkin: ペア成立当日(履歴なし)— streak はプレビュー1から始まる", async () => {
  const world = makeWorld({
    pair: {
      pairId: "pair-1",
      startedOn: TODAY,
      memberIds: ["user-a", "user-b"],
    },
    streakDays: [],
    plant: { grownDays: 0, name: null },
  });
  world.checkins.set(`user-b|${TODAY}`, { photoPath: null });
  const { pusher } = makePusher();

  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(
    result.body.snapshot.streakCurrent,
    1,
    "今日の両者達成プレビュー",
  );
  assertEquals(result.body.snapshot.plantStage, 0, "累計0+1=1日はまだ種");
  assertEquals(result.body.snapshot.plantMood, "happy");
});
