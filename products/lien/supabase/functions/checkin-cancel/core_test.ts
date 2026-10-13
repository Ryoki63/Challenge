// core_test.ts — checkin-cancel/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.3(checkin-cancel)/ §4(サイレントpush = content-available: 1)
//        / REQUIREMENTS §3.4「取り消しは当日中のみ可」

import {
  cancelledPhotoPaths,
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

// ---- fake repo / pusher ----

interface World {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>; // userId → 現役の約束
  pair:
    | {
      pairId: string;
      startedOn: string;
      memberIds: [string, string];
      ticketBalance?: number;
    }
    | null;
  checkins: Map<string, { photoPath: string | null }>; // key: `${userId}|${dateLocal}`
  streakDays: StreakDayRecord[];
  plant: SnapshotPlantRow | null;
  /** Storage の photos バケットにあるオブジェクトのキー(removePhotos で消える) */
  storage: Set<string>;
  /** removePhotos の呼び出し(引数のパス)を順に記録する */
  removeCalls: string[][];
  /** true なら removePhotos が失敗する(Storage の障害) */
  removeFails: boolean;
  /** 操作の順序の記録("remove" / "push") */
  events: string[];
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
        ticketBalance: world.pair.ticketBalance,
        partner,
      });
    },
    getCheckin: (id, dateLocal): Promise<SnapshotCheckinRow | null> =>
      Promise.resolve(world.checkins.get(`${id}|${dateLocal}`) ?? null),
    listStreakDays: () => Promise.resolve([...world.streakDays]),
    getPlant: () => Promise.resolve(world.plant),
    deleteCheckin: (params) => {
      const key = `${params.userId}|${params.dateLocal}`;
      const row = world.checkins.get(key);
      const deleted = world.checkins.delete(key);
      return Promise.resolve({ deleted, photoPath: row?.photoPath ?? null });
    },
    removePhotos: (paths) => {
      world.events.push("remove");
      world.removeCalls.push([...paths]);
      if (world.removeFails) {
        return Promise.reject(new Error("storage down"));
      }
      for (const path of paths) world.storage.delete(path); // 存在しないキーは無視
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
  events?: string[],
): { sent: SentPush[]; pusher: Pusher } {
  const sent: SentPush[] = [];
  return {
    sent,
    pusher: {
      send: (deviceToken, payload, opts) => {
        events?.push("push");
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
      ticketBalance: 2,
    },
    checkins: new Map(),
    // 確定済みの連続5日(6/5〜6/9)+途切れた前の1日(6/2)= ふたり達成 6 回(わかば(7回)の一歩手前)。
    // 成長回数は streak_days の both の行数から数える(GROWTH §7.2)
    streakDays: bothDays(
      "2026-06-02",
      "2026-06-05",
      "2026-06-06",
      "2026-06-07",
      "2026-06-08",
      "2026-06-09",
    ),
    // grown_days は控え。snapshot は読まない(わざと行数と違う値にして、読んでいないことを検知する)
    plant: { grownDays: 99, name: "みどり" },
    storage: new Set(),
    removeCalls: [],
    removeFails: false,
    events: [],
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
    plantStage: 2, // ふたり達成 6 回 = めばえ(3 回〜)
    plantGrownDays: 6,
    plantStageFloor: 3,
    plantNextStageAt: 7,
    plantMood: "normal",
    plantName: "みどり",
    hasPartnerPhotoToday: false,
    ticketBalance: 2,
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
  assertEquals(
    s.plantStage,
    2,
    "先取りしていた昇格(6+1=7 回でわかば)が6回に戻り、めばえのまま(GROWTH §3.2: 当日の取消は戻る)",
  );
  assertEquals(s.plantGrownDays, 6, "先取りの1回分が戻る");
  assertEquals(s.plantMood, "fidget", "片方未完のそわそわに戻る");

  assertEquals(sent.length, 1);
  const partnerView = (sent[0].payload as { lien: { snapshot: PairSnapshot } })
    .lien.snapshot;
  assertEquals(partnerView.todayMeDone, true, "B 自身は完了のまま");
  assertEquals(partnerView.todayPartnerDone, false, "B 視点で相手(A)は未完に");
  assertEquals(partnerView.streakCurrent, 5);
  assertEquals(
    partnerView.plantGrownDays,
    6,
    "相手視点の snapshot も先取りが戻る",
  );
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
    plantGrownDays: 0,
    plantStageFloor: 0,
    plantNextStageAt: null,
    plantMood: "normal",
    plantName: null,
    hasPartnerPhotoToday: false,
    ticketBalance: null,
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

Deno.test("checkin-cancel: 相手の push_env を、サイレント push の送信オプション(pushType / priority)と一緒に environment へ載せる(issue #60)", async () => {
  const cases = [
    ["production", {
      pushType: "background",
      priority: 5,
      environment: "production",
    }],
    ["sandbox", {
      pushType: "background",
      priority: 5,
      environment: "sandbox",
    }],
    [null, { pushType: "background", priority: 5 }],
    [undefined, { pushType: "background", priority: 5 }],
  ] as const;
  for (const [pushEnv, expected] of cases) {
    const world = makeWorld({ users: [userA, { ...userB, pushEnv }] });
    world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
    const { sent, pusher } = makePusher();

    await handleCheckinCancel(deps(world, pusher), {
      userId: "user-a",
      dateLocal: TODAY,
    });

    assertEquals(sent.length, 1, `push_env=${pushEnv}`);
    assertEquals(sent[0].deviceToken, "token-b");
    assertEquals(sent[0].opts, expected, `push_env=${pushEnv}`);
  }
});

// ---- 写真の実体の削除(issue #68。DESIGN §5.2・§5.3) ----
//
// 取り消すと、行の写真(原寸 photo.jpg とサムネ photo_thumb.jpg)を Storage から消す。#59 の方式ではクライアントが
// 署名付き URL を作るので、パスは決定的(pair_id・日付・取り消した人の user_id は相手にも分かる)。行を消すだけだと、
// 相手は取消のあとも同じパスから写真を取れてしまう。消すのは本人の区画だけ。失敗しても取消は成功

/** 本人の区画のオブジェクト 2 つ(原寸 + サムネ)のキー */
const objectsOf = (
  user: string,
  date: string = TODAY,
  pair: string = "pair-1",
): [string, string] => [
  `pairs/${pair}/${date}/${user}/photo.jpg`,
  `pairs/${pair}/${date}/${user}/photo_thumb.jpg`,
];

/** console.error を差し替えて、出力を集める(エラーログの出方も検査するため。テストの出力を汚さない) */
async function captureErrors<T>(
  fn: () => Promise<T>,
): Promise<{ result: T; logs: string[] }> {
  const original = console.error;
  const logs: string[] = [];
  console.error = (...args: unknown[]) => {
    logs.push(args.map(String).join(" "));
  };
  try {
    return { result: await fn(), logs };
  } finally {
    console.error = original;
  }
}

Deno.test("cancelledPhotoPaths: 行の photo_path(本人の区画・この日)+ 現役のペアのこの日の本人の区画。重複なし", () => {
  const [photo, thumb] = objectsOf("user-a");
  // 行の photo_path と現役のペアが同じ区画 → 2 つだけ(重複しない)
  assertEquals(
    cancelledPhotoPaths({
      userId: "user-a",
      dateLocal: TODAY,
      pairId: "pair-1",
      rowPhotoPath: photo,
    }),
    { paths: [photo, thumb], rowPhotoPathIgnored: false },
  );
  // 行に photo_path が無くても、現役のペアのこの日の区画は消す(行に記録される前にアップロードだけ済んだ孤児)
  assertEquals(
    cancelledPhotoPaths({
      userId: "user-a",
      dateLocal: TODAY,
      pairId: "pair-1",
      rowPhotoPath: null,
    }),
    { paths: [photo, thumb], rowPhotoPathIgnored: false },
  );
  // 同じ日のうちにペアを組み直した: 行は前のペアの区画を指す → 前のペアの区画も消す(4 つ)
  const [oldPhoto, oldThumb] = objectsOf("user-a", TODAY, "pair-0");
  assertEquals(
    cancelledPhotoPaths({
      userId: "user-a",
      dateLocal: TODAY,
      pairId: "pair-1",
      rowPhotoPath: oldPhoto,
    }),
    { paths: [oldPhoto, oldThumb, photo, thumb], rowPhotoPathIgnored: false },
  );
  // ソロ(ペアなし・写真なし)は消すものがない
  assertEquals(
    cancelledPhotoPaths({
      userId: "user-a",
      dateLocal: TODAY,
      pairId: null,
      rowPhotoPath: null,
    }),
    { paths: [], rowPhotoPathIgnored: false },
  );
  // ペアを解消してソロになったあとでも、行が指す本人の区画は消す
  assertEquals(
    cancelledPhotoPaths({
      userId: "user-a",
      dateLocal: TODAY,
      pairId: null,
      rowPhotoPath: oldPhoto,
    }),
    { paths: [oldPhoto, oldThumb], rowPhotoPathIgnored: false },
  );
});

Deno.test("cancelledPhotoPaths: 他人の区画・別の日・旧形式・サムネ・規約外の photo_path は消さない(本人のこの日の決定的なパスだけ)", () => {
  const [photo, thumb] = objectsOf("user-a");
  const ignored = [
    ["相手の区画", objectsOf("user-b")[0]],
    ["別の日(昨日)の区画", objectsOf("user-a", "2026-06-09")[0]],
    ["旧形式(ペア×日付単位)", `pairs/pair-1/${TODAY}/photo.jpg`],
    ["サムネのパス", thumb],
    ["規約外のファイル名", `pairs/pair-1/${TODAY}/user-a/other.png`],
    ["余計な階層", `pairs/pair-1/${TODAY}/user-a/x/photo.jpg`],
    ["区画に ..", `pairs/../${TODAY}/user-a/photo.jpg`],
    ["空の区画", `pairs//${TODAY}/user-a/photo.jpg`],
    ["pairs でない", `other/pair-1/${TODAY}/user-a/photo.jpg`],
    ["空文字", ""],
  ] as const;
  for (const [name, rowPhotoPath] of ignored) {
    assertEquals(
      cancelledPhotoPaths({
        userId: "user-a",
        dateLocal: TODAY,
        pairId: "pair-1",
        rowPhotoPath,
      }),
      { paths: [photo, thumb], rowPhotoPathIgnored: true },
      name,
    );
  }
  // 現役のペアが無ければ何も消さない(無視した事実だけが返る)
  assertEquals(
    cancelledPhotoPaths({
      userId: "user-a",
      dateLocal: TODAY,
      pairId: null,
      rowPhotoPath: objectsOf("user-b")[0],
    }),
    { paths: [], rowPhotoPathIgnored: true },
  );
});

Deno.test("checkin-cancel: 写真つきのチェックインを取り消すと、原寸とサムネの実体も消える(相手の写真は残る)", async () => {
  const world = makeWorld();
  const [aPhoto, aThumb] = objectsOf("user-a");
  const [bPhoto, bThumb] = objectsOf("user-b");
  world.checkins.set(`user-a|${TODAY}`, { photoPath: aPhoto });
  world.checkins.set(`user-b|${TODAY}`, { photoPath: bPhoto });
  for (const k of [aPhoto, aThumb, bPhoto, bThumb]) world.storage.add(k);
  const { sent, pusher } = makePusher("ok", world.events);

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyCanceled, false);
  assertEquals(
    Object.keys(result.body).sort(),
    ["alreadyCanceled", "snapshot"],
    "応答の形は変えない",
  );
  assertEquals(
    [...world.storage].sort(),
    [bPhoto, bThumb].sort(),
    "A の原寸とサムネだけが消え、B の写真は残る",
  );
  assertEquals(world.removeCalls.length, 1, "Storage の削除は 1 回の呼び出し");
  assertEquals(
    [...world.removeCalls[0]].sort(),
    [aPhoto, aThumb].sort(),
    "消すのは本人の区画の 2 つだけ",
  );
  assertEquals(
    world.events,
    ["remove", "push"],
    "相手へ知らせる前に実体を消す(知らせを受けた相手が、まだ残っている実体を取りに行く隙を作らない)",
  );
  assertEquals(sent.length, 1);
});

Deno.test("checkin-cancel: 行に photo_path が記録される前にアップロードだけ済んだ写真(孤児)も消える", async () => {
  const world = makeWorld();
  const [aPhoto, aThumb] = objectsOf("user-a");
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null }); // 行は作ったが、photoPath 付きの再送の前
  world.storage.add(aPhoto);
  world.storage.add(aThumb);
  const { pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  assertEquals([...world.storage], [], "決定的なパスの実体が消える");
});

Deno.test("checkin-cancel: 写真が無いソロの取消では Storage を呼ばない", async () => {
  const world = makeWorld({ pair: null, streakDays: [], plant: null });
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
  const { sent, pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  assertEquals(
    world.removeCalls,
    [],
    "消すものが無いので Storage の削除を呼ばない",
  );
  assertEquals(sent.length, 0);
});

Deno.test("checkin-cancel: 同じ日のうちにペアを解消してソロになっていても、行が指す本人の区画の写真は消える(相手の区画は残る)", async () => {
  const world = makeWorld({ pair: null, streakDays: [], plant: null });
  const [oldPhoto, oldThumb] = objectsOf("user-a", TODAY, "pair-0");
  const [exPhoto, exThumb] = objectsOf("user-b", TODAY, "pair-0");
  world.checkins.set(`user-a|${TODAY}`, { photoPath: oldPhoto });
  for (const k of [oldPhoto, oldThumb, exPhoto, exThumb]) world.storage.add(k);
  const { pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  assertEquals(
    [...world.storage].sort(),
    [exPhoto, exThumb].sort(),
    "元の相手の区画には触れない",
  );
});

Deno.test("checkin-cancel: すでに取消済み(行なし)の再送でも、残っていた実体を片付ける。push はしない(冪等)", async () => {
  // 前回の取消で実体の削除に失敗していた状況の再送
  const world = makeWorld();
  const [aPhoto, aThumb] = objectsOf("user-a");
  world.storage.add(aPhoto);
  world.storage.add(aThumb);
  const { sent, pusher } = makePusher();

  const result = await handleCheckinCancel(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyCanceled, true);
  assertEquals([...world.storage], [], "再送で片付く");
  assertEquals(sent.length, 0, "状態が変わっていないので push しない");
});

Deno.test("checkin-cancel: 実体の削除に失敗しても取消は成功(応答はそのまま・push も送る)。ログだけ残す", async () => {
  const world = makeWorld();
  const [aPhoto, aThumb] = objectsOf("user-a");
  world.checkins.set(`user-a|${TODAY}`, { photoPath: aPhoto });
  world.storage.add(aPhoto);
  world.storage.add(aThumb);
  world.removeFails = true;
  const { sent, pusher } = makePusher();

  const { result, logs } = await captureErrors(() =>
    handleCheckinCancel(deps(world, pusher), {
      userId: "user-a",
      dateLocal: TODAY,
    })
  );

  assertEquals(result.status, 200, "取消自体は成功");
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.alreadyCanceled, false);
  assertEquals(world.checkins.has(`user-a|${TODAY}`), false, "行は消えている");
  assertEquals(sent.length, 1, "相手への更新は送る");
  assertEquals(world.storage.size, 2, "実体は残る(次の取消の再送で片付く)");
  assertEquals(
    logs.some((l) => l.includes("写真の実体の削除に失敗")),
    true,
    "ログに残す",
  );
  assertEquals(
    logs.some((l) => l.includes("user-a") || l.includes("pair-1")),
    false,
    "ログにパス・ID を出さない",
  );
});

Deno.test("checkin-cancel: 行の photo_path が他人の区画・別の日・旧形式を指していても、本人のこの日の区画しか消さない", async () => {
  const [aPhoto, aThumb] = objectsOf("user-a");
  const [bPhoto, bThumb] = objectsOf("user-b");
  const [yPhoto, yThumb] = objectsOf("user-a", "2026-06-09");
  const legacy = `pairs/pair-1/${TODAY}/photo.jpg`;
  for (
    const [name, rowPath] of [
      ["相手の区画", bPhoto],
      ["別の日(昨日)の本人の区画", yPhoto],
      ["旧形式(ペア×日付単位。2 人の行が同じ実体を指しうる)", legacy],
    ] as const
  ) {
    const world = makeWorld();
    world.checkins.set(`user-a|${TODAY}`, { photoPath: rowPath });
    for (const k of [aPhoto, aThumb, bPhoto, bThumb, yPhoto, yThumb, legacy]) {
      world.storage.add(k);
    }
    const { pusher } = makePusher();

    const { result, logs } = await captureErrors(() =>
      handleCheckinCancel(deps(world, pusher), {
        userId: "user-a",
        dateLocal: TODAY,
      })
    );

    assertEquals(result.status, 200, name);
    assertEquals(
      [...world.storage].sort(),
      [bPhoto, bThumb, yPhoto, yThumb, legacy].sort(),
      `${name}: 消えるのは本人のこの日の決定的なパス(原寸とサムネ)だけ`,
    );
    assertEquals(
      logs.some((l) => l.includes("本人のこの日の区画を指していない")),
      true,
      `${name}: 無視したことをログに残す`,
    );
  }
});

Deno.test("checkin-cancel: 取り消せない日(昨日・明日・形式不正・ユーザー不在)では Storage に触らない", async () => {
  const world = makeWorld();
  const [yPhoto, yThumb] = objectsOf("user-a", "2026-06-09");
  const [aPhoto, aThumb] = objectsOf("user-a");
  world.checkins.set("user-a|2026-06-09", { photoPath: yPhoto });
  for (const k of [yPhoto, yThumb, aPhoto, aThumb]) world.storage.add(k);
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  for (const dateLocal of ["2026-06-09", "2026-06-11", "2026-6-10"]) {
    const r = await handleCheckinCancel(d, { userId: "user-a", dateLocal });
    assertEquals(r.status, 400, dateLocal);
  }
  const ghost = await handleCheckinCancel(d, {
    userId: "user-zzz",
    dateLocal: TODAY,
  });
  assertEquals(ghost.status, 404);
  assertEquals(world.removeCalls, [], "400 / 404 では削除を呼ばない");
  assertEquals(world.storage.size, 4, "実体は何も消えない");
});
