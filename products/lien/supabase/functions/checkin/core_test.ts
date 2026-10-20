// core_test.ts — checkin/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.3(checkin)/ §5.5(冪等性)/ §4(ペイロード)/ REQUIREMENTS §3.4

import {
  type CheckinRepo,
  handleCheckin,
  isOwnPhotoPath,
  photoUploadPaths,
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
  /** createSignedUploadUrl が要求されたパスの記録(パス規約の検証用) */
  signedUploadPaths: string[];
  /** Storage の photos バケットにあるオブジェクトのキー(removePhotos で消える) */
  storage: Set<string>;
  /** removePhotos の呼び出し(引数のパス)を順に記録する */
  removeCalls: string[][];
  /** true なら removePhotos が失敗する(Storage の障害) */
  removeFails: boolean;
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
        ticketBalance: world.pair.ticketBalance,
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
        const previousPhotoPath = existing.photoPath;
        existing.photoPath = params.photoPath;
        return Promise.resolve({
          created: false,
          photoUpdated: true,
          previousPhotoPath,
        });
      }
      return Promise.resolve({ created: false, photoUpdated: false });
    },
    removePhotos: (paths) => {
      world.removeCalls.push([...paths]);
      if (world.removeFails) {
        return Promise.reject(new Error("storage down"));
      }
      for (const path of paths) world.storage.delete(path); // 存在しないキーは無視
      return Promise.resolve();
    },
    createSignedUploadUrl: (path) => {
      world.signedUploadPaths.push(path);
      return Promise.resolve({
        token: `tok-${world.signedUploadPaths.length}`,
      });
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
    signedUploadPaths: [],
    storage: new Set(),
    removeCalls: [],
    removeFails: false,
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
    dateLocal: "2026-06-10",
    streakCurrent: 5,
    streakBest: 5,
    todayMeDone: true,
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
    plantMood: "fidget",
    plantName: "みどり",
    hasPartnerPhotoToday: false,
    ticketBalance: 2,
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
  assertEquals(
    s.plantStage,
    3,
    "ふたり達成 6 + 今日の先取り 1 = 7 回でわかばに昇格",
  );
  assertEquals(s.plantGrownDays, 7);
  assertEquals(s.plantStageFloor, 7);
  assertEquals(s.plantNextStageAt, 14);
  assertEquals(s.plantMood, "happy");

  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-a");
  const partnerView = (sent[0].payload.lien as { snapshot: PairSnapshot })
    .snapshot;
  assertEquals(partnerView.todayMeDone, true);
  assertEquals(partnerView.todayPartnerDone, true);
  assertEquals(partnerView.streakCurrent, 6);
  assertEquals(partnerView.plantStage, 3, "相手視点の snapshot も同じ成長回数");
  assertEquals(partnerView.plantGrownDays, 7);
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
    photoPath: "pairs/pair-1/2026-06-10/user-a/photo.jpg",
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

Deno.test("checkin: 写真パスは本人の区画 'pairs/<pair_id>/<date>/<user_id>/photo.jpg' 以外を拒否(issue #52)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const bad: Array<[string, string]> = [
    ["他ペア", "pairs/other-pair/2026-06-10/user-a/photo.jpg"],
    ["相手(user-b)の区画", "pairs/pair-1/2026-06-10/user-b/photo.jpg"],
    ["旧形式(user_id 区画なし)", "pairs/pair-1/2026-06-10/photo.jpg"],
    ["サムネのパス", "pairs/pair-1/2026-06-10/user-a/photo_thumb.jpg"],
    ["別のファイル名", "pairs/pair-1/2026-06-10/user-a/a.jpg"],
    ["日付区画が不正", "pairs/pair-1/2026-6-10/user-a/photo.jpg"],
    ["階層が深い(..)", "pairs/pair-1/2026-06-10/user-a/../user-b/photo.jpg"],
    ["階層が深い", "pairs/pair-1/2026-06-10/user-a/x/photo.jpg"],
    ["先頭が pairs でない", "other/pair-1/2026-06-10/user-a/photo.jpg"],
    ["pair 直下", "pairs/pair-1/photo.jpg"],
  ];
  for (const [label, photoPath] of bad) {
    const result = await handleCheckin(deps(world, pusher), {
      userId: "user-a",
      dateLocal: TODAY,
      photoPath,
    });
    assertEquals(result.status, 400, label);
    if (result.status !== 400) throw new Error("unreachable");
    assertEquals(result.body.error, "invalid_photo_path", label);
  }
  assertEquals(world.checkins.size, 0, "拒否時はチェックインも記録しない");
  assertEquals(sent.length, 0);

  const soloWorld = makeWorld({ pair: null });
  const soloPhoto = await handleCheckin(deps(soloWorld, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: "pairs/pair-1/2026-06-10/user-a/photo.jpg",
  });
  assertEquals(soloPhoto.status, 400, "ソロ状態の写真は置き場所(ペア)がない");
  assertEquals(sent.length, 0);
});

Deno.test("checkin: 本人の区画のパスは受理される(新規チェックインと同時 / 後から添付)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  const withPhoto = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: "pairs/pair-1/2026-06-10/user-a/photo.jpg",
  });
  assertEquals(withPhoto.status, 200);
  assertEquals(
    world.checkins.get(`user-a|${TODAY}`)?.photoPath,
    "pairs/pair-1/2026-06-10/user-a/photo.jpg",
  );

  // 相手(B)も同じ日・同じペアで、自分の区画なら受理され、A の写真は上書きされない
  const bPhoto = await handleCheckin(d, {
    userId: "user-b",
    dateLocal: TODAY,
    photoPath: "pairs/pair-1/2026-06-10/user-b/photo.jpg",
  });
  assertEquals(bPhoto.status, 200);
  assertEquals(
    world.checkins.get(`user-a|${TODAY}`)?.photoPath,
    "pairs/pair-1/2026-06-10/user-a/photo.jpg",
    "A の写真は B のチェックインで変わらない",
  );
  assertEquals(
    world.checkins.get(`user-b|${TODAY}`)?.photoPath,
    "pairs/pair-1/2026-06-10/user-b/photo.jpg",
  );
});

Deno.test("isOwnPhotoPath / photoUploadPaths: 発行したパスは検査を通り、他人・旧形式は通らない", () => {
  const mine = photoUploadPaths("pair-1", "2026-06-10", "user-a");
  assertEquals(mine, {
    photo: "pairs/pair-1/2026-06-10/user-a/photo.jpg",
    thumb: "pairs/pair-1/2026-06-10/user-a/photo_thumb.jpg",
  });
  assertEquals(isOwnPhotoPath(mine.photo, "pair-1", "user-a"), true);
  assertEquals(
    isOwnPhotoPath(mine.thumb, "pair-1", "user-a"),
    false,
    "原寸のみ",
  );
  assertEquals(isOwnPhotoPath(mine.photo, "pair-1", "user-b"), false, "他人");
  assertEquals(isOwnPhotoPath(mine.photo, "pair-2", "user-a"), false, "他ペア");
  // 同じ日でも本人ごとにパスが違う(上書きし合わない)
  const theirs = photoUploadPaths("pair-1", "2026-06-10", "user-b");
  assertEquals(theirs.photo !== mine.photo, true);
  assertEquals(theirs.thumb !== mine.thumb, true);
});

// ---- 写真の差し替えで参照されなくなった古い実体の掃除(issue #68。DESIGN §5.2・§5.3) ----

/** 本人の区画のオブジェクト 2 つ(原寸 + サムネ)のキー */
const objectsOf = (
  user: string,
  date: string = TODAY,
  pair: string = "pair-1",
): [string, string] => [
  `pairs/${pair}/${date}/${user}/photo.jpg`,
  `pairs/${pair}/${date}/${user}/photo_thumb.jpg`,
];

Deno.test("checkin: 同じパスへの差し替え(ふつうの貼り直し)では、実体を消さない(上書きされた新しい写真を消してしまう)", async () => {
  const world = makeWorld();
  const [photo, thumb] = objectsOf("user-a");
  world.checkins.set(`user-a|${TODAY}`, { photoPath: null });
  world.storage.add(photo);
  world.storage.add(thumb);
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  // 1 枚目を記録 → 同じパスで貼り直し(photoPath は同じなので photoUpdated にならない)
  const first = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: photo,
  });
  const second = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: photo,
  });

  assertEquals(first.status, 200);
  assertEquals(second.status, 200);
  assertEquals(world.removeCalls, [], "同じパスでは消さない");
  assertEquals(world.storage.size, 2, "実体は残る");
});

Deno.test("checkin: 同じ日のうちに別のペアの区画へ photo_path が変わったら、前のペアの区画の実体(原寸+サムネ)を消す", async () => {
  const world = makeWorld();
  const [oldPhoto, oldThumb] = objectsOf("user-a", TODAY, "pair-0");
  const [newPhoto, newThumb] = objectsOf("user-a");
  const [exPhoto, exThumb] = objectsOf("user-b", TODAY, "pair-0");
  world.checkins.set(`user-a|${TODAY}`, { photoPath: oldPhoto });
  for (const k of [oldPhoto, oldThumb, newPhoto, newThumb, exPhoto, exThumb]) {
    world.storage.add(k);
  }
  const { pusher } = makePusher();

  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: newPhoto,
  });

  assertEquals(result.status, 200);
  assertEquals(world.checkins.get(`user-a|${TODAY}`)?.photoPath, newPhoto);
  assertEquals(world.removeCalls.length, 1);
  assertEquals(
    [...world.removeCalls[0]].sort(),
    [oldPhoto, oldThumb].sort(),
    "消すのは古い区画の原寸とサムネだけ",
  );
  assertEquals(
    [...world.storage].sort(),
    [newPhoto, newThumb, exPhoto, exThumb].sort(),
    "新しい写真と、元の相手の区画は残る",
  );
});

Deno.test("checkin: 古い photo_path が別の日・旧形式・他人の区画なら、差し替えても消さない(別の日の行の写真・相手の写真を巻き込まない)", async () => {
  const [newPhoto] = objectsOf("user-a");
  for (
    const [name, previous] of [
      ["別の日(昨日)の本人の区画", objectsOf("user-a", "2026-06-09")[0]],
      ["旧形式(ペア×日付単位)", `pairs/pair-1/${TODAY}/photo.jpg`],
      ["相手の区画", objectsOf("user-b")[0]],
    ] as const
  ) {
    const world = makeWorld();
    world.checkins.set(`user-a|${TODAY}`, { photoPath: previous });
    world.storage.add(previous);
    const { pusher } = makePusher();

    const result = await handleCheckin(deps(world, pusher), {
      userId: "user-a",
      dateLocal: TODAY,
      photoPath: newPhoto,
    });

    assertEquals(result.status, 200, name);
    assertEquals(world.removeCalls, [], `${name}: 消さない`);
    assertEquals(world.storage.has(previous), true, name);
  }
});

Deno.test("checkin: 新規のチェックイン・写真なしの再送では実体を消さない", async () => {
  const world = makeWorld();
  const [photo] = objectsOf("user-a");
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  await handleCheckin(d, { userId: "user-a", dateLocal: TODAY }); // 新規
  await handleCheckin(d, { userId: "user-a", dateLocal: TODAY }); // 写真なしの再送
  await handleCheckin(d, {
    userId: "user-b",
    dateLocal: TODAY,
    photoPath: objectsOf("user-b")[0],
  }); // 別の人の初めての写真
  await handleCheckin(d, {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: photo,
  }); // 前の photo_path が null → 古い実体はない

  assertEquals(world.removeCalls, []);
});

Deno.test("checkin: 古い実体の削除に失敗しても checkin は成功(ログだけ残す)", async () => {
  const world = makeWorld();
  const [oldPhoto] = objectsOf("user-a", TODAY, "pair-0");
  const [newPhoto] = objectsOf("user-a");
  world.checkins.set(`user-a|${TODAY}`, { photoPath: oldPhoto });
  world.removeFails = true;
  const { sent, pusher } = makePusher();
  const original = console.error;
  const logs: string[] = [];
  console.error = (...args: unknown[]) => {
    logs.push(args.map(String).join(" "));
  };
  let result;
  try {
    result = await handleCheckin(deps(world, pusher), {
      userId: "user-a",
      dateLocal: TODAY,
      photoPath: newPhoto,
    });
  } finally {
    console.error = original;
  }

  assertEquals(result.status, 200, "差し替え自体は成功");
  assertEquals(world.checkins.get(`user-a|${TODAY}`)?.photoPath, newPhoto);
  assertEquals(sent.length, 1, "写真を添えた通知は送る");
  assertEquals(
    logs.some((l) => l.includes("古い写真の実体の削除に失敗")),
    true,
    "ログに残す",
  );
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
    dateLocal: "2026-06-10",
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
    plantGrownDays: 0,
    plantStageFloor: 0,
    plantNextStageAt: null,
    plantMood: "normal",
    plantName: null,
    hasPartnerPhotoToday: false,
    ticketBalance: null,
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

// ---- 署名付きアップロードURL(DESIGN §5.6 — issue #48 / T14) ----

Deno.test("checkin: requestPhotoUpload — 原寸+サムネ2本の {path, token} を同梱(パス規約 pairs/<pairId>/<date>/<userId>/)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
    requestPhotoUpload: true,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(
    result.body.alreadyCheckedIn,
    false,
    "チェックイン自体も実行される",
  );
  assertEquals(result.body.photoUpload, {
    photo: {
      path: "pairs/pair-1/2026-06-10/user-a/photo.jpg",
      token: "tok-1",
    },
    thumb: {
      path: "pairs/pair-1/2026-06-10/user-a/photo_thumb.jpg",
      token: "tok-2",
    },
  });
  // 署名はパス規約どおりの2本に対してのみ要求される(migration 0004 のポリシーと一致)
  assertEquals(world.signedUploadPaths, [
    "pairs/pair-1/2026-06-10/user-a/photo.jpg",
    "pairs/pair-1/2026-06-10/user-a/photo_thumb.jpg",
  ]);
  // 発行された原寸パスをそのまま photoPath として再送すると受理される(T14 のフロー)
  if (!result.body.photoUpload) throw new Error("unreachable");
  const attach = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: result.body.photoUpload.photo.path,
  });
  assertEquals(attach.status, 200, "発行されたパスは photoPath 検査を通る");
  assertEquals(
    world.checkins.get(`user-a|${TODAY}`)?.photoPath,
    "pairs/pair-1/2026-06-10/user-a/photo.jpg",
  );
});

Deno.test("checkin: requestPhotoUpload — 同じ日に2人が要求しても本人ごとに別のパス(上書きし合わない)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  const a = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: TODAY,
    requestPhotoUpload: true,
  });
  const b = await handleCheckin(d, {
    userId: "user-b",
    dateLocal: TODAY,
    requestPhotoUpload: true,
  });
  if (a.status !== 200 || b.status !== 200) throw new Error("unreachable");
  if (!a.body.photoUpload || !b.body.photoUpload) {
    throw new Error("unreachable");
  }

  assertEquals(
    a.body.photoUpload.photo.path,
    "pairs/pair-1/2026-06-10/user-a/photo.jpg",
  );
  assertEquals(
    b.body.photoUpload.photo.path,
    "pairs/pair-1/2026-06-10/user-b/photo.jpg",
  );
  const all = [
    a.body.photoUpload.photo.path,
    a.body.photoUpload.thumb.path,
    b.body.photoUpload.photo.path,
    b.body.photoUpload.thumb.path,
  ];
  assertEquals(new Set(all).size, 4, "4本とも別パス");

  // 相手の区画のパスは、自分の photoPath としては受け付けない
  const steal = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: TODAY,
    photoPath: b.body.photoUpload.photo.path,
  });
  assertEquals(steal.status, 400);
});

Deno.test("checkin: requestPhotoUpload — チェックイン済みの日の再要求も 200(冪等)で新しいURLを返す", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  await handleCheckin(d, { userId: "user-a", dateLocal: TODAY });
  const again = await handleCheckin(d, {
    userId: "user-a",
    dateLocal: TODAY,
    requestPhotoUpload: true,
  });

  assertEquals(again.status, 200);
  if (again.status !== 200) throw new Error("unreachable");
  assertEquals(again.body.alreadyCheckedIn, true);
  assertEquals(again.body.photoUpload !== undefined, true);
  assertEquals(sent.length, 1, "URL再発行だけでは push を再送しない");
});

Deno.test("checkin: requestPhotoUpload — ソロ状態は 400 no_pair(upsert もしない)", async () => {
  const world = makeWorld({ pair: null, streakDays: [], plant: null });
  const { sent, pusher } = makePusher();

  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
    requestPhotoUpload: true,
  });

  assertEquals(result.status, 400);
  if (result.status !== 400) throw new Error("unreachable");
  assertEquals(result.body.error, "no_pair");
  assertEquals(world.checkins.size, 0, "拒否時はチェックインも記録しない");
  assertEquals(world.signedUploadPaths, []);
  assertEquals(sent.length, 0);
});

Deno.test("checkin: requestPhotoUpload なし(従来リクエスト)は photoUpload キー自体を含まない", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  const result = await handleCheckin(deps(world, pusher), {
    userId: "user-a",
    dateLocal: TODAY,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals("photoUpload" in result.body, false);
  assertEquals(world.signedUploadPaths, []);
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
  assertEquals(
    result.body.snapshot.plantStage,
    1,
    "ふたり達成 0 + 今日の先取り 1 = 1 回で、成立当日にふたばになる(最初の成功をすぐ返す — GROWTH §3.3)",
  );
  assertEquals(result.body.snapshot.plantGrownDays, 1);
  assertEquals(result.body.snapshot.plantStageFloor, 1);
  assertEquals(result.body.snapshot.plantNextStageAt, 3);
  assertEquals(result.body.snapshot.plantMood, "happy");
});

Deno.test("checkin: 受信者(相手)の push_env を送信オプションの environment に載せる — 未設定は載せず APNS_ENV に任せる(issue #60)", async () => {
  const cases = [
    ["production", { environment: "production" }],
    ["sandbox", { environment: "sandbox" }],
    [null, {}],
    [undefined, {}],
  ] as const;
  for (const [pushEnv, expected] of cases) {
    const world = makeWorld({ users: [userA, { ...userB, pushEnv }] });
    const { sent, pusher } = makePusher();

    await handleCheckin(deps(world, pusher), {
      userId: "user-a",
      dateLocal: TODAY,
    });

    assertEquals(sent.length, 1, `push_env=${pushEnv}`);
    assertEquals(sent[0].deviceToken, "token-b");
    assertEquals(sent[0].opts, expected, `push_env=${pushEnv}`);
  }
});
