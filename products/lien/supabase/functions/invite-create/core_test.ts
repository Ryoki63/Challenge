// core_test.ts — invite-create/core.ts の deno test(リポジトリはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.1(8文字英数・0/O/1/l 除外・72h・1回限り)/ §6 / REQUIREMENTS §3.2

import {
  generateInviteToken,
  handleInviteCreate,
  INVITE_TOKEN_ALPHABET,
  INVITE_TOKEN_LENGTH,
  type InviteCreateRepo,
} from "./core.ts";
import type { SnapshotPairRow, SnapshotUserRow } from "../_shared/snapshot.ts";

// ---- 自作 assert ヘルパ(外部モジュールを使わない) ----

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

function assert(cond: boolean, msg = ""): void {
  if (!cond) throw new Error(`assert failed: ${msg}`);
}

// ---- token 生成 ----

Deno.test("token: 文字集合 — 8文字英数で紛らわしい 0/O/1/l を含まない(DESIGN §5.1)", () => {
  // 文字集合そのものの検査
  assertEquals(INVITE_TOKEN_ALPHABET.length, 58, "62 - 4(0,O,1,l)");
  for (const banned of ["0", "O", "1", "l"]) {
    assert(
      !INVITE_TOKEN_ALPHABET.includes(banned),
      `紛らわしい文字 ${banned} を含んではいけない`,
    );
  }
  assert(
    /^[A-Za-z0-9]+$/.test(INVITE_TOKEN_ALPHABET),
    "英数のみ(invites.token の DB CHECK と整合)",
  );
  assertEquals(
    new Set(INVITE_TOKEN_ALPHABET).size,
    INVITE_TOKEN_ALPHABET.length,
    "重複なし",
  );

  // 実乱数で大量生成しても形式・文字集合を守る
  const re = new RegExp(`^[${INVITE_TOKEN_ALPHABET}]{${INVITE_TOKEN_LENGTH}}$`);
  for (let i = 0; i < 500; i++) {
    const token = generateInviteToken();
    assert(re.test(token), `不正なtoken: ${token}`);
  }
});

Deno.test("token: 乱数注入で決定論的(バイト→文字の対応と棄却サンプリング)", () => {
  // 0..7 → alphabet 先頭8文字
  const seq = generateInviteToken(() =>
    new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7])
  );
  assertEquals(seq, INVITE_TOKEN_ALPHABET.slice(0, 8));

  // 232 以上のバイトは棄却される(256 % 58 = 24 の偏り防止)。
  // 1回目の8バイトのうち 232+ の2バイトは捨てられ、2回目の呼び出しから補充される
  let call = 0;
  const tokens = [
    new Uint8Array([255, 232, 0, 0, 0, 0, 0, 0]), // 有効6バイト
    new Uint8Array([57, 57, 0, 0, 0, 0, 0, 0]), // 補充(先頭2バイトを消費)
  ];
  const token = generateInviteToken(() => tokens[call++]);
  const z = INVITE_TOKEN_ALPHABET[57]; // "9"
  assertEquals(token, "AAAAAA" + z + z);
  assertEquals(call, 2, "棄却分を2回目の乱数で補充する");
});

// ---- handler ----

const userA: SnapshotUserRow = {
  id: "user-a",
  nickname: "あきら",
  timezone: "Asia/Tokyo",
  pushToken: "token-a",
};

interface World {
  users: SnapshotUserRow[];
  pairOf: Record<string, SnapshotPairRow>;
  invites: Array<{ token: string; fromUser: string; expiresAtIso: string }>;
  /** insertInvite が { inserted: false } を返す回数(衝突シミュレーション) */
  collisions: number;
}

function makeWorld(overrides: Partial<World> = {}): World {
  return {
    users: [userA],
    pairOf: {},
    invites: [],
    collisions: 0,
    ...overrides,
  };
}

function makeRepo(world: World): InviteCreateRepo {
  return {
    getUser: (id) =>
      Promise.resolve(world.users.find((u) => u.id === id) ?? null),
    getActivePair: (id) => Promise.resolve(world.pairOf[id] ?? null),
    insertInvite: (params) => {
      if (world.collisions > 0) {
        world.collisions--;
        return Promise.resolve({ inserted: false });
      }
      world.invites.push(params);
      return Promise.resolve({ inserted: true });
    },
  };
}

const NOW = new Date("2026-06-10T03:00:00Z");

function deps(world: World, randomBytes?: () => Uint8Array) {
  return {
    repo: makeRepo(world),
    webBaseUrl: "https://example.github.io/Challenge",
    now: () => NOW,
    randomBytes,
  };
}

Deno.test("invite-create: 発行成功 — 2形式のURL・72h期限・DB保存(DESIGN §6 / §5.1)", async () => {
  const world = makeWorld();
  const result = await handleInviteCreate(
    deps(world, () => new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7])),
    { userId: "user-a" },
  );

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  const expectedToken = INVITE_TOKEN_ALPHABET.slice(0, 8); // "ABCDEFGH"
  assertEquals(result.body.token, expectedToken);
  assertEquals(result.body.appUrl, `lien://invite/${expectedToken}`);
  assertEquals(
    result.body.webUrl,
    `https://example.github.io/Challenge/lien/i/?t=${expectedToken}`,
  );
  // 72h 後(2026-06-10T03:00Z + 72h = 2026-06-13T03:00Z)
  assertEquals(result.body.expiresAt, "2026-06-13T03:00:00.000Z");

  assertEquals(world.invites.length, 1);
  assertEquals(world.invites[0], {
    token: expectedToken,
    fromUser: "user-a",
    expiresAtIso: "2026-06-13T03:00:00.000Z",
  });
});

Deno.test("invite-create: webBaseUrl 末尾スラッシュは二重スラッシュにならない", async () => {
  const world = makeWorld();
  const result = await handleInviteCreate(
    {
      repo: makeRepo(world),
      webBaseUrl: "https://example.github.io/Challenge/",
      now: () => NOW,
      randomBytes: () => new Uint8Array([0, 0, 0, 0, 0, 0, 0, 0]),
    },
    { userId: "user-a" },
  );
  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(
    result.body.webUrl,
    "https://example.github.io/Challenge/lien/i/?t=AAAAAAAA",
  );
});

Deno.test("invite-create: 既にペアがいる発行者は 409(v1 は1ユーザー1ペア)", async () => {
  const world = makeWorld({
    pairOf: {
      "user-a": {
        pairId: "pair-1",
        startedOn: "2026-06-01",
        partner: { ...userA, id: "user-b" },
      },
    },
  });
  const result = await handleInviteCreate(deps(world), { userId: "user-a" });
  assertEquals(result.status, 409);
  if (result.status !== 409) throw new Error("unreachable");
  assertEquals(result.body.error, "already_paired");
  assertEquals(world.invites.length, 0);
});

Deno.test("invite-create: ユーザー不在は 404", async () => {
  const world = makeWorld();
  const result = await handleInviteCreate(deps(world), { userId: "user-zzz" });
  assertEquals(result.status, 404);
});

Deno.test("invite-create: token 衝突(PK 重複)は再生成してリトライ", async () => {
  const world = makeWorld({ collisions: 2 });
  const result = await handleInviteCreate(deps(world), { userId: "user-a" });
  assertEquals(result.status, 200);
  assertEquals(world.invites.length, 1, "3回目の挿入で成功");
});

Deno.test("invite-create: 衝突が続く場合は有限回で諦めて 500", async () => {
  const world = makeWorld({ collisions: 100 });
  const result = await handleInviteCreate(deps(world), { userId: "user-a" });
  assertEquals(result.status, 500);
  if (result.status !== 500) throw new Error("unreachable");
  assertEquals(result.body.error, "token_generation_failed");
  assertEquals(world.invites.length, 0);
});
