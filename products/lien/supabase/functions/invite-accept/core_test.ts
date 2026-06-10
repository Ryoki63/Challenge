// core_test.ts — invite-accept/core.ts の deno test(リポジトリ/プッシャーはモック。ネットワーク不要)
// 正本: docs/DESIGN.md §5.1 / §5.3(双方未ペア検査)/ §6 / REQUIREMENTS §3.2 / §3.6 / §5

import {
  DEFAULT_PLANT_SPECIES,
  handleInviteAccept,
  type InviteAcceptRepo,
  type InviteRow,
} from "./core.ts";
import type {
  PairSnapshot,
  SnapshotPairRow,
  SnapshotPromiseRow,
  SnapshotUserRow,
} from "../_shared/snapshot.ts";
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

type WorldUser = SnapshotUserRow & { premiumUntil: string | null };

interface CreatedPair {
  pairId: string;
  startedOn: string;
  ticketBalance: number;
  memberIds: string[];
}

interface World {
  users: WorldUser[];
  promises: Record<string, SnapshotPromiseRow>;
  invites: Map<string, Omit<InviteRow, "token">>;
  /** 事前に存在する active ペア(双方未ペア検査用) */
  existingPairOf: Record<string, SnapshotPairRow>;
  createdPair: CreatedPair | null;
  ledger: Array<{
    pairId: string;
    delta: number;
    reason: string;
    dateLocal: string;
  }>;
  plants: Array<{ pairId: string; species: string }>;
  checkins: Map<string, { photoPath: string | null }>;
  /** claimInvite を強制的に失敗させる(同時受諾の競合シミュレーション) */
  claimFails: boolean;
}

function makeRepo(world: World): InviteAcceptRepo {
  return {
    getUser: (id) =>
      Promise.resolve(world.users.find((u) => u.id === id) ?? null),
    getActivePromise: (id) => Promise.resolve(world.promises[id] ?? null),
    getActivePair: (id): Promise<SnapshotPairRow | null> => {
      if (world.existingPairOf[id]) {
        return Promise.resolve(world.existingPairOf[id]);
      }
      const p = world.createdPair;
      if (!p || !p.memberIds.includes(id)) return Promise.resolve(null);
      const partnerId = p.memberIds.find((m) => m !== id)!;
      const partner = world.users.find((u) => u.id === partnerId)!;
      return Promise.resolve({
        pairId: p.pairId,
        startedOn: p.startedOn,
        partner,
      });
    },
    getCheckin: (id, dateLocal) =>
      Promise.resolve(world.checkins.get(`${id}|${dateLocal}`) ?? null),
    listStreakDays: () => Promise.resolve([]),
    getPlant: (pairId) =>
      Promise.resolve(
        world.plants.some((p) => p.pairId === pairId)
          ? { grownDays: 0, name: null }
          : null,
      ),

    getInvite: (token) => {
      const row = world.invites.get(token);
      return Promise.resolve(row ? { token, ...row } : null);
    },
    claimInvite: (token, usedAtIso) => {
      const row = world.invites.get(token);
      if (!row || row.usedAtIso !== null || world.claimFails) {
        return Promise.resolve(false);
      }
      row.usedAtIso = usedAtIso;
      return Promise.resolve(true);
    },
    createPair: (params) => {
      world.createdPair = {
        pairId: "pair-new",
        startedOn: params.startedOn,
        ticketBalance: params.ticketBalance,
        memberIds: [],
      };
      return Promise.resolve({ pairId: "pair-new" });
    },
    addPairMembers: (_pairId, userIds) => {
      world.createdPair!.memberIds = [...userIds];
      return Promise.resolve();
    },
    insertTicketLedger: (params) => {
      world.ledger.push({ ...params });
      return Promise.resolve();
    },
    createPlant: (params) => {
      world.plants.push({ ...params });
      return Promise.resolve();
    },
    getPremiumUntil: (id) =>
      Promise.resolve(
        world.users.find((u) => u.id === id)?.premiumUntil ?? null,
      ),
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

const inviter: WorldUser = {
  id: "user-a",
  nickname: "あきら",
  timezone: "Asia/Tokyo",
  pushToken: "token-a",
  premiumUntil: null,
};
const accepter: WorldUser = {
  id: "user-b",
  nickname: "ゆうき",
  timezone: "Asia/Tokyo",
  pushToken: "token-b",
  premiumUntil: null,
};

/** JST 2026-06-10 12:00。受諾者ローカルの当日 = 2026-06-10 */
const NOW = new Date("2026-06-10T03:00:00Z");
const TODAY = "2026-06-10";
const TOKEN = "ABCDefgh";

function makeWorld(overrides: Partial<World> = {}): World {
  return {
    users: [inviter, accepter],
    promises: {
      "user-a": { id: "prom-a", title: "筋トレ", emoji: "💪" },
    },
    invites: new Map([[TOKEN, {
      fromUser: "user-a",
      expiresAtIso: "2026-06-11T00:00:00.000Z", // 期限内
      usedAtIso: null,
    }]]),
    existingPairOf: {},
    createdPair: null,
    ledger: [],
    plants: [],
    checkins: new Map(),
    claimFails: false,
    ...overrides,
  };
}

function deps(world: World, pusher: Pusher) {
  return { repo: makeRepo(world), pusher, now: () => NOW };
}

// ---- 本体テスト ----

Deno.test("invite-accept: 成立 — pairs+members+plants 作成・初期チケット2枚・両者へ pair_update push", async () => {
  const world = makeWorld();
  // 受諾者はソロ期間に今日のチェックイン済み(招待待ちでも使える — REQUIREMENTS §3.2)
  world.checkins.set(`user-b|${TODAY}`, { photoPath: null });
  const { sent, pusher } = makePusher();

  const result = await handleInviteAccept(deps(world, pusher), {
    userId: "user-b",
    token: TOKEN,
  });

  assertEquals(result.status, 200);
  if (result.status !== 200) throw new Error("unreachable");
  assertEquals(result.body.pairId, "pair-new");

  // pairs: started_on = 受諾者ローカルの当日。初期チケット free 2枚(migration 0001 の決定)
  assertEquals(world.createdPair, {
    pairId: "pair-new",
    startedOn: TODAY,
    ticketBalance: 2,
    memberIds: ["user-a", "user-b"],
  });
  assertEquals(world.ledger, [
    { pairId: "pair-new", delta: 2, reason: "monthly", dateLocal: TODAY },
  ]);
  // plants 行作成(ペア成立で種が植えられる — REQUIREMENTS §3.9)
  assertEquals(world.plants, [
    { pairId: "pair-new", species: DEFAULT_PLANT_SPECIES },
  ]);
  // 1回限り: used_at 打刻
  assert(world.invites.get(TOKEN)!.usedAtIso !== null, "used_at が打刻される");

  // 両者へ pair_update push(title は相手名 — DESIGN §4)
  assertEquals(sent.length, 2);
  assertEquals(sent[0].deviceToken, "token-a", "先に発行者へ");
  const toInviter = sent[0].payload as {
    aps: { alert: { title: string; body: string } };
    lien: { type: string; snapshot: PairSnapshot };
  };
  assertEquals(toInviter.aps.alert.title, "ゆうき");
  assertEquals(
    toInviter.aps.alert.body,
    "ペアが成立したよ!今日からふたりで育てよう🌱",
  );
  assertEquals(toInviter.lien.type, "pair_update");
  assertEquals(toInviter.lien.snapshot.pairId, "pair-new");
  assertEquals(toInviter.lien.snapshot.partnerName, "ゆうき");
  assertEquals(
    toInviter.lien.snapshot.todayPartnerDone,
    true,
    "発行者視点: 相手(受諾者)は今日チェックイン済み",
  );
  assertEquals(toInviter.lien.snapshot.plantStage, 0, "成立直後は種");

  assertEquals(sent[1].deviceToken, "token-b");
  const toAccepter = sent[1].payload as typeof toInviter;
  assertEquals(toAccepter.aps.alert.title, "あきら");
  assertEquals(toAccepter.lien.snapshot.partnerName, "あきら");

  // 受諾者視点の snapshot 返却
  const s = result.body.snapshot;
  assertEquals(s.pairId, "pair-new");
  assertEquals(s.todayMeDone, true);
  assertEquals(s.todayPartnerDone, false);
  assertEquals(s.partnerName, "あきら");
  assertEquals(
    s.streakCurrent,
    0,
    "ふたりストリークは成立日から(まだ確定なし)",
  );
});

Deno.test("invite-accept: メンバーが premium なら初期チケット5枚(REQUIREMENTS §5 から導出)", async () => {
  const premiumInviter = {
    ...inviter,
    premiumUntil: "2026-12-31T00:00:00.000Z",
  };
  const world = makeWorld({ users: [premiumInviter, accepter] });
  const { pusher } = makePusher();

  const result = await handleInviteAccept(deps(world, pusher), {
    userId: "user-b",
    token: TOKEN,
  });

  assertEquals(result.status, 200);
  assertEquals(world.createdPair!.ticketBalance, 5);
  assertEquals(world.ledger, [
    { pairId: "pair-new", delta: 5, reason: "monthly", dateLocal: TODAY },
  ]);
});

Deno.test("invite-accept: 期限切れは 410(境界: expires_at ちょうども期限切れ)", async () => {
  for (
    const expiresAtIso of [
      "2026-06-09T00:00:00.000Z", // 過去
      NOW.toISOString(), // ちょうど
    ]
  ) {
    const world = makeWorld();
    world.invites.get(TOKEN)!.expiresAtIso = expiresAtIso;
    const { sent, pusher } = makePusher();

    const result = await handleInviteAccept(deps(world, pusher), {
      userId: "user-b",
      token: TOKEN,
    });

    assertEquals(result.status, 410, `expiresAt=${expiresAtIso}`);
    if (result.status !== 410) throw new Error("unreachable");
    assertEquals(result.body.error, "invite_expired");
    assertEquals(world.createdPair, null);
    assertEquals(world.invites.get(TOKEN)!.usedAtIso, null, "クレームしない");
    assertEquals(sent.length, 0);
  }
});

Deno.test("invite-accept: 使用済みは 410(1リンク1回限り — REQUIREMENTS §3.2)", async () => {
  const world = makeWorld();
  world.invites.get(TOKEN)!.usedAtIso = "2026-06-09T12:00:00.000Z";
  const { pusher } = makePusher();

  const result = await handleInviteAccept(deps(world, pusher), {
    userId: "user-b",
    token: TOKEN,
  });

  assertEquals(result.status, 410);
  if (result.status !== 410) throw new Error("unreachable");
  assertEquals(result.body.error, "invite_already_used");
  assertEquals(world.createdPair, null);
});

Deno.test("invite-accept: 同時受諾の競合(claim 失敗)は 410・ペアを作らない", async () => {
  const world = makeWorld({ claimFails: true });
  const { pusher } = makePusher();

  const result = await handleInviteAccept(deps(world, pusher), {
    userId: "user-b",
    token: TOKEN,
  });

  assertEquals(result.status, 410);
  if (result.status !== 410) throw new Error("unreachable");
  assertEquals(result.body.error, "invite_already_used");
  assertEquals(world.createdPair, null);
  assertEquals(world.ledger.length, 0);
});

Deno.test("invite-accept: 自分の招待は受諾できない(400)", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();

  const result = await handleInviteAccept(deps(world, pusher), {
    userId: "user-a",
    token: TOKEN,
  });

  assertEquals(result.status, 400);
  if (result.status !== 400) throw new Error("unreachable");
  assertEquals(result.body.error, "cannot_accept_own_invite");
});

Deno.test("invite-accept: 既ペア拒否 — 受諾者・発行者どちらが既ペアでも 409(DESIGN §5.3)", async () => {
  const somePair: SnapshotPairRow = {
    pairId: "pair-old",
    startedOn: "2026-05-01",
    partner: { ...inviter, id: "user-z" },
  };

  // 受諾者が既ペア
  const w1 = makeWorld({ existingPairOf: { "user-b": somePair } });
  const { pusher: p1 } = makePusher();
  const r1 = await handleInviteAccept(deps(w1, p1), {
    userId: "user-b",
    token: TOKEN,
  });
  assertEquals(r1.status, 409);
  if (r1.status !== 409) throw new Error("unreachable");
  assertEquals(r1.body.error, "already_paired");
  assertEquals(w1.invites.get(TOKEN)!.usedAtIso, null, "token は消費しない");

  // 発行者が既ペア(発行後に別の相手と成立したケース)
  const w2 = makeWorld({ existingPairOf: { "user-a": somePair } });
  const { pusher: p2 } = makePusher();
  const r2 = await handleInviteAccept(deps(w2, p2), {
    userId: "user-b",
    token: TOKEN,
  });
  assertEquals(r2.status, 409);
  if (r2.status !== 409) throw new Error("unreachable");
  assertEquals(r2.body.error, "partner_already_paired");
  assertEquals(w2.invites.get(TOKEN)!.usedAtIso, null, "token は消費しない");
});

Deno.test("invite-accept: token 形式不正は 400・存在しない token は 404", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const d = deps(world, pusher);

  for (const bad of ["", "abc", "ABCDEFGHI", "ABC-EFGH", "ABCD EFG"]) {
    const r = await handleInviteAccept(d, { userId: "user-b", token: bad });
    assertEquals(r.status, 400, `token=${JSON.stringify(bad)}`);
    if (r.status !== 400) throw new Error("unreachable");
    assertEquals(r.body.error, "invalid_token");
  }

  const notFound = await handleInviteAccept(d, {
    userId: "user-b",
    token: "zzzzzzzz",
  });
  assertEquals(notFound.status, 404);
  if (notFound.status !== 404) throw new Error("unreachable");
  assertEquals(notFound.body.error, "invite_not_found");
});

Deno.test("invite-accept: push_token が無いメンバーには送らない(処理は成功)", async () => {
  const noTokenInviter = { ...inviter, pushToken: null };
  const world = makeWorld({ users: [noTokenInviter, accepter] });
  const { sent, pusher } = makePusher();

  const result = await handleInviteAccept(deps(world, pusher), {
    userId: "user-b",
    token: TOKEN,
  });

  assertEquals(result.status, 200);
  assertEquals(sent.length, 1, "受諾者にだけ送る");
  assertEquals(sent[0].deviceToken, "token-b");
});

Deno.test("invite-accept: push が throw しても成立は成功扱い(DESIGN §5.5)", async () => {
  const world = makeWorld();
  const pusher: Pusher = {
    send: () => Promise.reject(new Error("apns down")),
  };

  const result = await handleInviteAccept(deps(world, pusher), {
    userId: "user-b",
    token: TOKEN,
  });

  assertEquals(result.status, 200);
  assert(world.createdPair !== null);
});

Deno.test("invite-accept: ユーザー不在は 404", async () => {
  const world = makeWorld();
  const { pusher } = makePusher();
  const result = await handleInviteAccept(deps(world, pusher), {
    userId: "user-zzz",
    token: TOKEN,
  });
  assertEquals(result.status, 404);
  if (result.status !== 404) throw new Error("unreachable");
  assertEquals(result.body.error, "user_not_found");
});
