// core_test.ts — plant-name/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/GROWTH.md §5.3(名前付け)・§8.1(plant-name の仕様)/ docs/DESIGN.md §5.3・§4

import {
  handlePlantName,
  normalizePlantName,
  PLANT_NAME_MAX_LENGTH,
  type PlantNameRepo,
  type Pusher,
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

// ---- fake repo / pusher ----

interface PairRow {
  pairId: string;
  startedOn: string;
  memberIds: [string, string];
}

interface World {
  users: SnapshotUserRow[];
  promises: Record<string, SnapshotPromiseRow>;
  pairs: PairRow[];
  streakDays: Record<string, StreakDayRecord[]>; // pairId → 行
  plants: Map<string, SnapshotPlantRow>;
  /** plants への書き込み(first = 条件付き / rename = 上書き)の記録 */
  writes: Array<{ kind: "first" | "rename"; pairId: string; name: string }>;
  /** getUser の呼び出し回数(入力検証が DB を引く前に弾くことの検査用) */
  userLookups: number;
  /** setPlantNameIfUnset の直前に走るフック(読んでから書くまでの間に起きる競合の再現) */
  beforeConditionalWrite?: () => void;
}

function makeRepo(world: World): PlantNameRepo {
  return {
    getUser: (id) => {
      world.userLookups++;
      return Promise.resolve(world.users.find((u) => u.id === id) ?? null);
    },
    getActivePromise: (id) => Promise.resolve(world.promises[id] ?? null),
    getActivePair: (id): Promise<SnapshotPairRow | null> => {
      const p = world.pairs.find((x) => x.memberIds.includes(id));
      if (!p) return Promise.resolve(null);
      const partnerId = p.memberIds.find((m) => m !== id)!;
      const partner = world.users.find((u) => u.id === partnerId)!;
      return Promise.resolve({
        pairId: p.pairId,
        startedOn: p.startedOn,
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
    setPlantNameIfUnset: (pairId, name) => {
      world.beforeConditionalWrite?.();
      const plant = world.plants.get(pairId);
      if (!plant || plant.name !== null) return Promise.resolve(false);
      plant.name = name;
      world.writes.push({ kind: "first", pairId, name });
      return Promise.resolve(true);
    },
    setPlantName: (pairId, name) => {
      const plant = world.plants.get(pairId);
      if (plant) plant.name = name;
      world.writes.push({ kind: "rename", pairId, name });
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
};
const userB: SnapshotUserRow = {
  id: "user-b",
  nickname: "ゆうき",
  timezone: "Asia/Tokyo",
  pushToken: "token-b",
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

/** ペア1(A・B)に名前なしの鉢、ペア2(C・D)に名前付きの鉢 */
function makeWorld(overrides: Partial<World> = {}): World {
  return {
    users: [userA, userB, userC, userD],
    promises: {
      "user-a": { id: "prom-a", title: "筋トレ", emoji: "💪" },
      "user-b": { id: "prom-b", title: "ランニング", emoji: "🏃" },
    },
    pairs: [
      {
        pairId: "pair-1",
        startedOn: "2026-06-01",
        memberIds: ["user-a", "user-b"],
      },
      {
        pairId: "pair-2",
        startedOn: "2026-06-01",
        memberIds: ["user-c", "user-d"],
      },
    ],
    streakDays: {
      "pair-1": bothDays("2026-06-07", "2026-06-08", "2026-06-09"),
      "pair-2": [],
    },
    plants: new Map([
      ["pair-1", { grownDays: 3, name: null }],
      ["pair-2", { grownDays: 0, name: "ほかのこ" }],
    ]),
    writes: [],
    userLookups: 0,
    ...overrides,
  };
}

function deps(world: World, pusher: Pusher) {
  return { repo: makeRepo(world), pusher, now: () => NOW };
}

// ---- first: 先に付けた人の名前に決まる ----

Deno.test("plant-name first: 名前が無ければ書ける — 200・自分用 snapshot に plantName・相手へサイレント push(snapshot 同梱)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: "みどり",
    mode: "first",
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.name, "みどり");
  assertEquals(result.body.snapshot.plantName, "みどり", "自分用 snapshot");
  assertEquals(result.body.snapshot.pairId, "pair-1");
  assertEquals(result.body.snapshot.partnerName, "ゆうき");
  assertEquals(
    result.body.snapshot.plantGrownDays,
    3,
    "成長回数は行から数える",
  );
  assertEquals(world.plants.get("pair-1")?.name, "みどり");
  assertEquals(world.writes, [{
    kind: "first",
    pairId: "pair-1",
    name: "みどり",
  }]);

  // 相手(B)へ: サイレント(content-available)+受信者視点の snapshot
  assertEquals(sent.length, 1);
  assertEquals(sent[0].deviceToken, "token-b");
  const payload = sent[0].payload as {
    aps: Record<string, unknown>;
    lien: { type: string; snapshot: PairSnapshot };
  };
  assertEquals(
    payload.aps,
    { "content-available": 1 },
    "通知 UI の無いサイレント",
  );
  assertEquals(payload.lien.type, "pair_update");
  assertEquals(payload.lien.snapshot.plantName, "みどり");
  assertEquals(
    payload.lien.snapshot.partnerName,
    "あきら",
    "相手視点で組み立てる",
  );
  assertEquals(payload.lien.snapshot.myPromiseTitle, "ランニング");
  assertEquals(
    sent[0].opts,
    { pushType: "background", priority: 5 },
    "サイレントは apns-push-type: background / priority 5",
  );
});

Deno.test("plant-name first: すでに名前があれば 409 already_named と今の名前を返す(書かない・push しない)", async () => {
  const world = makeWorld();
  world.plants.get("pair-1")!.name = "さくら";
  const { sent, pusher } = makePusher();

  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-b",
    name: "みどり",
    mode: "first",
  });

  assertEquals(result.status, 409);
  assertEquals(result.body, { error: "already_named", name: "さくら" });
  assertEquals(
    world.plants.get("pair-1")?.name,
    "さくら",
    "先に付けた名前のまま",
  );
  assertEquals(world.writes, []);
  assertEquals(sent.length, 0);
});

Deno.test("plant-name first: 同じ名前の再送(通信失敗の再試行など)も 409(誰が付けたかは区別しない)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  const first = await handlePlantName(d, {
    userId: "user-a",
    name: "みどり",
    mode: "first",
  });
  const again = await handlePlantName(d, {
    userId: "user-a",
    name: "みどり",
    mode: "first",
  });

  assertEquals(first.status, 200);
  assertEquals(again.status, 409);
  assertEquals(again.body, { error: "already_named", name: "みどり" });
  assertEquals(world.writes.length, 1);
  assertEquals(sent.length, 1, "2回目は push しない");
});

Deno.test("plant-name first: 読んでから書くまでの間に相手が先に付けたら、決まった名前で 409(先に着いた1人だけが勝つ)", async () => {
  const world = makeWorld();
  // A が「名前なし」を読んだ後、書く直前に B が「ぱっと」を付ける
  world.beforeConditionalWrite = () => {
    world.plants.get("pair-1")!.name = "ぱっと";
  };
  const { sent, pusher } = makePusher();

  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: "みどり",
    mode: "first",
  });

  assertEquals(result.status, 409);
  assertEquals(result.body, { error: "already_named", name: "ぱっと" });
  assertEquals(
    world.plants.get("pair-1")?.name,
    "ぱっと",
    "負けた側は書かない",
  );
  assertEquals(world.writes, []);
  assertEquals(sent.length, 0);
});

Deno.test("plant-name first: 競合の最中に鉢の行が消えていたら 404 plant_not_found", async () => {
  const world = makeWorld();
  world.beforeConditionalWrite = () => {
    world.plants.delete("pair-1");
  };
  const { pusher } = makePusher();

  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: "みどり",
    mode: "first",
  });

  assertEquals(result.status, 404);
  assertEquals(result.body, { error: "plant_not_found" });
});

Deno.test("plant-name first: 相手が先に付けた後に、自分が first を送っても上書きされない(双方向)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  const byB = await handlePlantName(d, {
    userId: "user-b",
    name: "ゆうきのこ",
    mode: "first",
  });
  const byA = await handlePlantName(d, {
    userId: "user-a",
    name: "あきらのこ",
    mode: "first",
  });

  assertEquals(byB.status, 200);
  assertEquals(byA.status, 409);
  assertEquals(byA.body, { error: "already_named", name: "ゆうきのこ" });
  assertEquals(world.plants.get("pair-1")?.name, "ゆうきのこ");
});

// ---- rename: 上書き。変わったときだけ相手へ知らせる ----

Deno.test("plant-name rename: 上書きできる — 200・相手へサイレント push", async () => {
  const world = makeWorld();
  world.plants.get("pair-1")!.name = "さくら";
  const { sent, pusher } = makePusher();

  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-b",
    name: "みどり",
    mode: "rename",
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.name, "みどり");
  assertEquals(result.body.snapshot.plantName, "みどり");
  assertEquals(world.plants.get("pair-1")?.name, "みどり");
  assertEquals(world.writes, [{
    kind: "rename",
    pairId: "pair-1",
    name: "みどり",
  }]);

  assertEquals(sent.length, 1);
  assertEquals(
    sent[0].deviceToken,
    "token-a",
    "変えたのは B。知らせる相手は A",
  );
  const payload = sent[0].payload as {
    lien: { type: string; snapshot: PairSnapshot };
  };
  assertEquals(payload.lien.type, "pair_update");
  assertEquals(payload.lien.snapshot.plantName, "みどり");
  assertEquals(payload.lien.snapshot.partnerName, "ゆうき");
});

Deno.test("plant-name rename: 同じ名前への変更は何もしない(書き込みも push もない)", async () => {
  const world = makeWorld();
  world.plants.get("pair-1")!.name = "みどり";
  const { sent, pusher } = makePusher();

  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: "  みどり  ", // 前後の空白を除くと同じ
    mode: "rename",
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.name, "みどり");
  assertEquals(result.body.snapshot.plantName, "みどり");
  assertEquals(world.writes, []);
  assertEquals(sent.length, 0);
});

Deno.test("plant-name rename: まだ名前が無くても上書き(書き込み)できる", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: "みどり",
    mode: "rename",
  });

  assertEquals(result.status, 200);
  assertEquals(world.plants.get("pair-1")?.name, "みどり");
  assertEquals(sent.length, 1);
});

// ---- 入力検査 ----

Deno.test("normalizePlantName: 使える名前 — 前後の空白は除き、途中の空白は残す・8字ちょうどまで・絵文字もよい", () => {
  assertEquals(normalizePlantName("みどり"), "みどり");
  assertEquals(normalizePlantName("  みどり  "), "みどり", "半角空白を除く");
  assertEquals(normalizePlantName("　みどり　"), "みどり", "全角空白を除く");
  assertEquals(normalizePlantName("み どり"), "み どり", "途中の空白は残す");
  assertEquals(normalizePlantName("あ"), "あ", "1字");
  assertEquals(
    normalizePlantName("あいうえおかきく"),
    "あいうえおかきく",
    "8字",
  );
  assertEquals(normalizePlantName("12345678"), "12345678");
  assertEquals(normalizePlantName("🌱"), "🌱");
  assertEquals(
    normalizePlantName("🌱🌱🌱🌱🌱🌱🌱🌱"),
    "🌱🌱🌱🌱🌱🌱🌱🌱",
    "絵文字 8 つ",
  );
  assertEquals(
    normalizePlantName("👨‍👩‍👧‍👦"),
    "👨‍👩‍👧‍👦",
    "ZWJ でつないだ家族の絵文字(7 コードポイント)",
  );
  assertEquals(PLANT_NAME_MAX_LENGTH, 8);
});

Deno.test("normalizePlantName: 字数は Unicode コードポイントで数える(9字目は拒否)", () => {
  assertEquals(normalizePlantName("123456789"), null, "9字");
  assertEquals(normalizePlantName("あいうえおかきくけ"), null, "9字(全角)");
  assertEquals(
    normalizePlantName("🌱🌱🌱🌱🌱🌱🌱🌱🌱"),
    null,
    "絵文字 9 つ(UTF-16 では 18)",
  );
  // UTF-16 の .length ではなくコードポイント: 「𠮷」(U+20BB7)は .length 2 だが 1 字
  assertEquals(
    normalizePlantName("𠮷𠮷𠮷𠮷𠮷𠮷𠮷𠮷"),
    "𠮷𠮷𠮷𠮷𠮷𠮷𠮷𠮷",
    "8字",
  );
});

Deno.test("normalizePlantName: NFC に正規化してから数える(濁点が分解された入力でも字数がずれない)", () => {
  const nfd = "が"; // 「が」の分解形(2 コードポイント)
  assertEquals(nfd.length, 2);
  assertEquals(normalizePlantName(nfd), "が", "NFC の 1 字になる");
  assertEquals(
    normalizePlantName(nfd.repeat(8)),
    "が".repeat(8),
    "分解形 8 字(生のコードポイントは 16)も 8 字として通る",
  );
  assertEquals(normalizePlantName(nfd.repeat(9)), null, "9 字は拒否");
});

Deno.test("normalizePlantName: 拒否する名前 — 空・空白だけ・改行や制御文字を含む・見える文字が無い", () => {
  const bad: Array<[string, string]> = [
    ["", "空"],
    ["   ", "半角空白だけ"],
    ["　　", "全角空白だけ"],
    ["\n", "改行だけ"],
    ["み\nどり", "途中の LF"],
    ["み\r\nどり", "途中の CRLF"],
    ["み\rどり", "途中の CR"],
    ["み\tどり", "途中のタブ"],
    ["み\u0085どり", "NEL(次行)"],
    ["み どり", "行区切り U+2028"],
    ["み どり", "段落区切り U+2029"],
    ["み\u0000どり", "NUL"],
    ["み\u001bどり", "ESC"],
    ["み\u007fどり", "DEL"],
    ["み\ud800どり", "対になっていないサロゲート"],
    ["​", "ゼロ幅スペースだけ"],
    ["‍‍", "ZWJ だけ"],
    ["​‌‍", "書式文字だけ"],
  ];
  for (const [input, label] of bad) {
    assertEquals(normalizePlantName(input), null, label);
  }
});

Deno.test("normalizePlantName: 書式文字は ZWJ だけ許す — 双方向制御・ゼロ幅・BOM などは拒否、絵文字の ZWJ 結合と VS16 は通す", () => {
  // 拒否: 名前の中に1つでもあれば(見える文字が他にあっても)
  const forbidden: Array<[string, string]> = [
    ["\u202e", "RLO(右から左への上書き)"],
    ["\u202d", "LRO(左から右への上書き)"],
    ["\u202a", "LRE"],
    ["\u202b", "RLE"],
    ["\u202c", "PDF"],
    ["\u2066", "LRI"],
    ["\u2067", "RLI"],
    ["\u2068", "FSI"],
    ["\u2069", "PDI"],
    ["\u200b", "ゼロ幅スペース"],
    ["\u200c", "ZWNJ(ゼロ幅非結合子)"],
    ["\u200e", "LRM"],
    ["\u200f", "RLM"],
    ["\u061c", "ALM"],
    ["\u2060", "語結合子"],
    ["\ufeff", "BOM / ZWNBSP"],
    ["\u00ad", "ソフトハイフン"],
  ];
  for (const [ch, label] of forbidden) {
    assertEquals(normalizePlantName(`み${ch}どり`), null, `${label}(途中)`);
    if (ch === "\ufeff") {
      // BOM(U+FEFF)は JavaScript の空白として前後を trim で除かれる(途中のものは上で拒否している)
      assertEquals(normalizePlantName(`${ch}みどり${ch}`), "みどり", label);
      continue;
    }
    assertEquals(normalizePlantName(`${ch}みどり`), null, `${label}(先頭)`);
    assertEquals(normalizePlantName(`みどり${ch}`), null, `${label}(末尾)`);
  }
  // 許す: 絵文字をつなぐ ZWJ(U+200D)と、絵文字表示の VS16(U+FE0F)
  assertEquals(normalizePlantName("\u2764\ufe0f"), "\u2764\ufe0f", "❤️(VS16)");
  assertEquals(
    normalizePlantName("\u{1f3f3}\ufe0f\u200d\u{1f308}"),
    "\u{1f3f3}\ufe0f\u200d\u{1f308}",
    "🏳️‍🌈(VS16 + ZWJ)",
  );
  assertEquals(
    normalizePlantName("\u{1f469}\u{1f3fd}\u200d\u{1f4bb}"),
    "\u{1f469}\u{1f3fd}\u200d\u{1f4bb}",
    "👩🏽‍💻(肌の色 + ZWJ)",
  );
});

Deno.test("plant-name: 使えない名前は 400 invalid_name — DB を引く前に弾く(書かない・push しない)", async () => {
  for (
    const name of ["", "   ", "123456789", "み\nどり", "\u200b", "み\u202eどり"]
  ) {
    const world = makeWorld();
    const { sent, pusher } = makePusher();
    for (const mode of ["first", "rename"]) {
      const result = await handlePlantName(deps(world, pusher), {
        userId: "user-a",
        name,
        mode,
      });
      assertEquals(result.status, 400, `${JSON.stringify(name)} ${mode}`);
      assertEquals(result.body, { error: "invalid_name" });
    }
    assertEquals(world.userLookups, 0, "入力検証は DB より先");
    assertEquals(world.writes, []);
    assertEquals(world.plants.get("pair-1")?.name, null);
    assertEquals(sent.length, 0);
  }
});

Deno.test("plant-name: mode は first か rename だけ — それ以外は 400 invalid_mode(DB を引く前)", async () => {
  for (const mode of ["", "FIRST", "Rename", "first ", "update", "set"]) {
    const world = makeWorld();
    const { sent, pusher } = makePusher();
    const result = await handlePlantName(deps(world, pusher), {
      userId: "user-a",
      name: "みどり",
      mode,
    });
    assertEquals(result.status, 400, JSON.stringify(mode));
    assertEquals(result.body, { error: "invalid_mode" });
    assertEquals(world.userLookups, 0);
    assertEquals(world.writes, []);
    assertEquals(sent.length, 0);
  }
});

Deno.test("plant-name: 保存される名前は前後の空白を除き NFC にしたもの", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: " 　がん ",
    mode: "first",
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.name, "がん");
  assertEquals(world.plants.get("pair-1")?.name, "がん");
  assertEquals(result.body.snapshot.plantName, "がん");
});

// ---- ペア必須・本人のペアだけ ----

Deno.test("plant-name: 有効なペアが無ければ 409 no_pair(ソロには鉢が無い)", async () => {
  const world = makeWorld({ pairs: [] });
  const { sent, pusher } = makePusher();
  for (const mode of ["first", "rename"]) {
    const result = await handlePlantName(deps(world, pusher), {
      userId: "user-a",
      name: "みどり",
      mode,
    });
    assertEquals(result.status, 409, mode);
    assertEquals(result.body, { error: "no_pair" });
  }
  assertEquals(world.writes, []);
  assertEquals(sent.length, 0);
});

Deno.test("plant-name: ユーザー不在は 404 user_not_found", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-zzz",
    name: "みどり",
    mode: "first",
  });
  assertEquals(result.status, 404);
  assertEquals(result.body, { error: "user_not_found" });
  assertEquals(sent.length, 0);
});

Deno.test("plant-name: ペアはいるのに鉢の行が無い(データ不整合)は 404 plant_not_found", async () => {
  const world = makeWorld();
  world.plants.delete("pair-1");
  const { sent, pusher } = makePusher();
  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: "みどり",
    mode: "first",
  });
  assertEquals(result.status, 404);
  assertEquals(result.body, { error: "plant_not_found" });
  assertEquals(world.writes, []);
  assertEquals(sent.length, 0);
});

Deno.test("plant-name: 書き込むのは呼び出し本人のペアの鉢だけ(他のペアの鉢には触れない)", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();

  // ペア2(C・D)の鉢は「ほかのこ」。ペア1 の A が first / rename を送っても触れない
  await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: "みどり",
    mode: "first",
  });
  await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: "みどり2",
    mode: "rename",
  });

  assertEquals(world.plants.get("pair-1")?.name, "みどり2");
  assertEquals(world.plants.get("pair-2")?.name, "ほかのこ");
  assertEquals(world.writes.every((w) => w.pairId === "pair-1"), true);
  assertEquals(
    sent.every((s) => s.deviceToken === "token-b"),
    true,
    "知らせるのは自分のペアの相手だけ",
  );
});

// ---- push の扱い ----

Deno.test("plant-name: 相手に push_token が無ければ push せず成功", async () => {
  const noTokenB = { ...userB, pushToken: null };
  const world = makeWorld({ users: [userA, noTokenB, userC, userD] });
  const { sent, pusher } = makePusher();

  const result = await handlePlantName(deps(world, pusher), {
    userId: "user-a",
    name: "みどり",
    mode: "first",
  });

  assertEquals(result.status, 200);
  assertEquals(sent.length, 0);
  assertEquals(world.plants.get("pair-1")?.name, "みどり");
});

Deno.test("plant-name: push が失敗(ok:false)・throw しても名前の保存は成功(自己修復経路がある)", async () => {
  for (const behavior of ["fail", "throw"] as const) {
    const world = makeWorld();
    const { sent, pusher } = makePusher(behavior);

    const result = await handlePlantName(deps(world, pusher), {
      userId: "user-a",
      name: "みどり",
      mode: "first",
    });

    assertEquals(result.status, 200, behavior);
    assertEquals(world.plants.get("pair-1")?.name, "みどり", behavior);
    assertEquals(sent.length, 1, `${behavior}: 送信は試みた`);
  }
});

Deno.test("plant-name: first が負けたとき(409)は push しない・rename は変わったときだけ push する", async () => {
  const world = makeWorld();
  const { sent, pusher } = makePusher();
  const d = deps(world, pusher);

  await handlePlantName(d, { userId: "user-a", name: "みどり", mode: "first" }); // push 1
  await handlePlantName(d, { userId: "user-b", name: "さくら", mode: "first" }); // 409
  await handlePlantName(d, {
    userId: "user-b",
    name: "さくら",
    mode: "rename",
  }); // push 2
  await handlePlantName(d, {
    userId: "user-b",
    name: "さくら",
    mode: "rename",
  }); // 同じ名前: なし

  assertEquals(sent.length, 2);
  assertEquals(sent.map((s) => s.deviceToken), ["token-b", "token-a"]);
  assertEquals(world.plants.get("pair-1")?.name, "さくら");
});

Deno.test("plant-name: 相手の push_env を、サイレント push の送信オプション(pushType / priority)と一緒に environment へ載せる(issue #60)", async () => {
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
    const { sent, pusher } = makePusher();

    await handlePlantName(deps(world, pusher), {
      userId: "user-a",
      name: "みどり",
      mode: "first",
    });

    assertEquals(sent.length, 1, `push_env=${pushEnv}`);
    assertEquals(sent[0].deviceToken, "token-b");
    assertEquals(sent[0].opts, expected, `push_env=${pushEnv}`);
  }
});
