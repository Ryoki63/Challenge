// cleanup_test.ts — cleanup.ts の安全装置の deno test。本番には触れない(Management API・Storage API は偽物に差し替える)
//
//   deno test --allow-read products/lien/scripts/e2e/
//
// 後片付けは本番のユーザーを消す操作なので、「通しテストが作ったものだけを消す」安全装置を固定する:
//   匿名ユーザーで、サインアップの目印(lien_e2e)・ニックネーム E2E-A/B/C・約束の「E2E 」接頭辞(--user ではさらに絵文字 🧪)が
//   そろったものだけ・対象外のメンバーがいる(またはメンバーを配列として読めない)ペアは触らない・
//   UUID 以外は SQL に入れない・--dry-run は SELECT だけ・止めたときのメッセージにニックネームなどの中身を出さない。

import {
  identityProblems,
  listE2eUsers,
  planCleanup,
  runCleanup,
} from "./cleanup.ts";
import {
  E2E_EMOJI,
  E2E_META_KEY,
  E2E_NICKNAME_RE,
  E2E_PROMISE_PREFIX,
} from "./marker.ts";
import type { Mgmt } from "./mgmt.ts";
import { assertEquals, assertRejects } from "./test_util.ts";

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const C = "33333333-3333-4333-8333-333333333333";
const OUTSIDER = "99999999-9999-4999-8999-999999999999";
const PAIR = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

interface FakeData {
  users: Array<Record<string, unknown>>;
  pairs: Array<Record<string, unknown>>;
  objects: string[];
  /** listE2eUsers の問い合わせが返す行 */
  list?: Array<Record<string, unknown>>;
}

/** SQL の文面で返す行を決める偽の Management API(実行された SQL を記録する) */
function fakeMgmt(data: FakeData): { mgmt: Mgmt; queries: string[] } {
  const queries: string[] = [];
  const mgmt = {
    sql: (q: string) => {
      queries.push(q);
      if (q.includes("order by a.created_at")) {
        return Promise.resolve(data.list ?? []);
      }
      if (q.includes("from auth.users a left join")) {
        return Promise.resolve(data.users);
      }
      if (q.includes("from public.pairs p")) return Promise.resolve(data.pairs);
      if (q.includes("from storage.objects where bucket_id = 'photos' and (")) {
        // 計画の SELECT(name を返す)。後始末後の件数の確認は as auth_users を含む別の問い合わせ
        return Promise.resolve(data.objects.map((name) => ({ name })));
      }
      return Promise.resolve([]);
    },
    secretKey: () =>
      Promise.reject(new Error("dry-run では secret key を取らない")),
  } as unknown as Mgmt;
  return { mgmt, queries };
}

interface UserOpts {
  anon?: boolean;
  /** サインアップの目印。null = 無い */
  marker?: string | null;
  emoji?: string;
  /** 「E2E 」で始まらないタイトルの約束の数 */
  foreign?: number;
}

/** planCleanup / listE2eUsers が読む列をそろえた行 */
function user(id: string, nickname: string, o: UserOpts = {}) {
  return {
    id,
    is_anonymous: o.anon ?? true,
    nickname,
    avatar_emoji: o.emoji ?? E2E_EMOJI,
    e2e_marker: o.marker === undefined ? "true" : o.marker,
    foreign_promises: o.foreign ?? 0,
    created_jst: "2026-10-13 05:00",
  };
}

const TARGET = {
  userIds: [A, B, C],
  pairIds: [PAIR],
  strict: false,
  source: "test",
};

const STOP = "何も消さずに止める";

Deno.test("通しテストのユーザー(匿名・目印あり・E2E-A/B/C)とそのペアだけが対象になる", async () => {
  const { mgmt } = fakeMgmt({
    users: [user(A, "E2E-A"), user(B, "E2E-B"), user(C, "E2E-C")],
    pairs: [{ pair_id: PAIR, members: [A, B] }],
    objects: [`pairs/${PAIR}/2026-10-13/${A}/photo.jpg`],
  });
  const plan = await planCleanup(mgmt, TARGET);
  assertEquals(plan.users.map((u) => u.id), [A, B, C]);
  assertEquals(plan.pairs, [PAIR]);
  assertEquals(plan.objects.length, 1);
  assertEquals(plan.absentUsers, []);
});

Deno.test("匿名でないユーザーが混じっていたら、何も消さずに止まる", async () => {
  const { mgmt } = fakeMgmt({
    users: [user(A, "E2E-A"), user(B, "E2E-B", { anon: false })],
    pairs: [],
    objects: [],
  });
  await assertRejects(
    () => planCleanup(mgmt, { ...TARGET, userIds: [A, B] }),
    STOP,
  );
});

Deno.test("ニックネームが E2E-A/B/C でないユーザーが混じっていたら止まる", async () => {
  const { mgmt } = fakeMgmt({
    users: [user(A, "E2E-A"), user(B, "ゆうき")],
    pairs: [],
    objects: [],
  });
  await assertRejects(
    () => planCleanup(mgmt, { ...TARGET, userIds: [A, B] }),
    STOP,
  );
});

Deno.test("サインアップの目印が無いユーザーは、ニックネームが E2E-A でも止まる(状態ファイルでも --user でも)", async () => {
  for (const marker of [null, "false", ""]) {
    for (const strict of [false, true]) {
      const { mgmt } = fakeMgmt({
        users: [user(A, "E2E-A", { marker })],
        pairs: [],
        objects: [],
      });
      await assertRejects(
        () => planCleanup(mgmt, { ...TARGET, userIds: [A], strict }),
        STOP,
        `marker=${marker} strict=${strict}`,
      );
    }
  }
});

Deno.test("「E2E 」で始まらないタイトルの約束を持つユーザーは、ほかの目印がそろっていても止まる", async () => {
  for (const strict of [false, true]) {
    const { mgmt } = fakeMgmt({
      users: [user(A, "E2E-A", { foreign: 1 })],
      pairs: [],
      objects: [],
    });
    await assertRejects(
      () => planCleanup(mgmt, { ...TARGET, userIds: [A], strict }),
      "約束のタイトル",
      `strict=${strict}`,
    );
  }
});

Deno.test("ニックネームが空のユーザー: 記録した ID(状態ファイル)なら対象、--user 指定(strict)なら止まる", async () => {
  const data = {
    users: [user(A, "", { emoji: "" })],
    pairs: [],
    objects: [],
  };
  const lenient = await planCleanup(fakeMgmt(data).mgmt, {
    ...TARGET,
    userIds: [A],
    strict: false,
  });
  assertEquals(lenient.users.length, 1);
  await assertRejects(
    () =>
      planCleanup(fakeMgmt(data).mgmt, {
        ...TARGET,
        userIds: [A],
        strict: true,
      }),
    STOP,
  );
});

Deno.test("--user 指定(strict)は絵文字 🧪 も要る。状態ファイルでは要らない", async () => {
  const data = {
    users: [user(A, "E2E-A", { emoji: "🌿" })],
    pairs: [],
    objects: [],
  };
  const lenient = await planCleanup(fakeMgmt(data).mgmt, {
    ...TARGET,
    userIds: [A],
    strict: false,
  });
  assertEquals(lenient.users.length, 1);
  await assertRejects(
    () =>
      planCleanup(fakeMgmt(data).mgmt, {
        ...TARGET,
        userIds: [A],
        strict: true,
      }),
    "絵文字",
  );
});

Deno.test("読めない値・欠けた列は、問題として数える(確かめられないユーザーは消さない)", () => {
  assertEquals(identityProblems(user(A, "E2E-A"), true), []);
  assertEquals(identityProblems(user(A, "E2E-A"), false), []);
  // 列が欠けている / 想定外の型
  for (const key of ["is_anonymous", "e2e_marker", "foreign_promises"]) {
    const row: Record<string, unknown> = user(A, "E2E-A");
    delete row[key];
    assertEquals(identityProblems(row, false).length, 1, `${key} が無い`);
  }
  const noNickname: Record<string, unknown> = user(A, "E2E-A");
  delete noNickname.nickname;
  assertEquals(identityProblems(noNickname, false).length, 1);
  assertEquals(
    identityProblems({ ...user(A, "E2E-A"), foreign_promises: "x" }, false)
      .length,
    1,
  );
  assertEquals(
    identityProblems({ ...user(A, "E2E-A"), is_anonymous: "true" }, false)
      .length,
    1,
  );
  // 複数の理由はそれぞれ数える
  assertEquals(
    identityProblems(
      user(A, "ゆうき", { anon: false, marker: null, emoji: "", foreign: 2 }),
      true,
    ).length,
    5,
  );
});

Deno.test("止めたときのメッセージには、ユーザー ID と理由だけを出し、ニックネームの中身は出さない", async () => {
  const { mgmt } = fakeMgmt({
    users: [user(A, "E2E-A"), user(B, "ゆうき", { marker: null })],
    pairs: [],
    objects: [],
  });
  try {
    await planCleanup(mgmt, { ...TARGET, userIds: [A, B] });
    throw new Error("例外が出なかった");
  } catch (e) {
    const text = e instanceof Error ? e.message : String(e);
    assertEquals(text.includes(B), true, text);
    assertEquals(text.includes("ゆうき"), false, text);
    assertEquals(text.includes(A), false, "対象外でないユーザーは出さない");
  }
});

Deno.test("対象のペアに対象外のメンバーがいたら止まる", async () => {
  const { mgmt } = fakeMgmt({
    users: [user(A, "E2E-A")],
    pairs: [{ pair_id: PAIR, members: [A, OUTSIDER] }],
    objects: [],
  });
  await assertRejects(
    () => planCleanup(mgmt, { ...TARGET, userIds: [A] }),
    "対象外のメンバー",
  );
});

Deno.test("ペアのメンバー一覧が配列として読めないときは、メンバーなしとして素通りせず止まる(fail-closed)", async () => {
  for (const members of ["{a,b}", null, undefined, { 0: A }, 5]) {
    const { mgmt } = fakeMgmt({
      users: [user(A, "E2E-A")],
      pairs: [{ pair_id: PAIR, members }],
      objects: [],
    });
    await assertRejects(
      () => planCleanup(mgmt, { ...TARGET, userIds: [A] }),
      "配列として読めない",
      `members=${JSON.stringify(members)}`,
    );
  }
  // 配列でも、文字列でない要素は対象外のメンバーとして数える
  const { mgmt } = fakeMgmt({
    users: [user(A, "E2E-A")],
    pairs: [{ pair_id: PAIR, members: [A, 5] }],
    objects: [],
  });
  await assertRejects(
    () => planCleanup(mgmt, { ...TARGET, userIds: [A] }),
    "対象外のメンバー",
  );
  // メンバーのいないペアは(空の配列として読めるので)対象になる
  const empty = await planCleanup(
    fakeMgmt({
      users: [user(A, "E2E-A")],
      pairs: [{ pair_id: PAIR, members: [] }],
      objects: [],
    }).mgmt,
    { ...TARGET, userIds: [A] },
  );
  assertEquals(empty.pairs, [PAIR]);
});

Deno.test("UUID でない ID は SQL に入れない", async () => {
  const { mgmt, queries } = fakeMgmt({ users: [], pairs: [], objects: [] });
  await assertRejects(
    () =>
      planCleanup(mgmt, { ...TARGET, userIds: ["x'; drop table users; --"] }),
    "UUID でない",
  );
  assertEquals(queries.length, 0);
  await assertRejects(
    () => planCleanup(mgmt, { ...TARGET, pairIds: ["nope"] }),
    "UUID でない",
  );
});

Deno.test("目印の定数は SQL にそのまま埋めてよい文字だけでできている", () => {
  assertEquals(/^[A-Za-z0-9_]+$/.test(E2E_META_KEY), true);
  assertEquals(/^[A-Za-z0-9 ]+$/.test(E2E_PROMISE_PREFIX), true);
  assertEquals(E2E_NICKNAME_RE.test("E2E-A"), true);
  assertEquals(E2E_NICKNAME_RE.test("E2E-D"), false);
  assertEquals(E2E_NICKNAME_RE.test("xE2E-A"), false);
});

Deno.test("もう DB に無いユーザーは absentUsers に出る(削除済みの再実行)", async () => {
  const { mgmt } = fakeMgmt({
    users: [user(A, "E2E-A")],
    pairs: [],
    objects: [],
  });
  const plan = await planCleanup(mgmt, { ...TARGET, userIds: [A, B] });
  assertEquals(plan.absentUsers, [B]);
});

Deno.test("--dry-run は SELECT だけ(delete を流さない・secret key を取らない)", async () => {
  const { mgmt, queries } = fakeMgmt({
    users: [user(A, "E2E-A"), user(B, "E2E-B")],
    pairs: [{ pair_id: PAIR, members: [A, B] }],
    objects: [`pairs/${PAIR}/2026-10-13/${A}/photo.jpg`],
  });
  const lines: string[] = [];
  const r = await runCleanup(mgmt, "https://example.invalid", {
    ...TARGET,
    userIds: [A, B],
  }, {
    dryRun: true,
    log: (l) => lines.push(l),
  });
  assertEquals(r.ok, true);
  assertEquals(queries.some((q) => /\bdelete\b/i.test(q)), false);
  assertEquals(
    lines.some((l) => l.includes("--dry-run のため何も消さない")),
    true,
  );
  assertEquals(r.deleted, { objects: 0, pairs: 0, users: 0 });
});

Deno.test("実行: Storage → ペア → ユーザーの順に、計画した対象だけを消し、残りが 0 件か確かめる", async () => {
  const photo = `pairs/${PAIR}/2026-10-13/${A}/photo.jpg`;
  const statements: string[] = [];
  const events: string[] = [];
  const mgmt = {
    sql: (q: string) => {
      if (q.includes("order by a.created_at")) return Promise.resolve([]);
      if (q.includes("from auth.users a left join")) {
        return Promise.resolve([user(A, "E2E-A"), user(B, "E2E-B")]);
      }
      if (q.includes("from public.pairs p")) {
        return Promise.resolve([{ pair_id: PAIR, members: [A, B] }]);
      }
      if (q.includes("as auth_users")) {
        events.push("確認");
        return Promise.resolve([{
          auth_users: 0,
          profiles: 0,
          pairs: 0,
          members: 0,
          promises: 0,
          checkins: 0,
          plants: 0,
          objects: 0,
        }]);
      }
      if (q.includes("delete from")) {
        events.push("DB の削除");
        statements.push(q);
        return Promise.resolve([]);
      }
      if (q.includes("from storage.objects")) {
        return Promise.resolve([{ name: photo }]);
      }
      return Promise.resolve([]);
    },
    secretKey: () => {
      events.push("secret key");
      return Promise.resolve("sb_secret_x");
    },
  } as unknown as Mgmt;

  // Storage の削除は fetch を差し替えて受ける(本番には出ない)
  const realFetch = globalThis.fetch;
  const storageCalls: Array<{ method: string; url: string; body: string }> = [];
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    events.push("Storage の削除");
    storageCalls.push({
      method: init?.method ?? "GET",
      url: String(input),
      body: String(init?.body ?? ""),
    });
    return Promise.resolve(
      new Response(JSON.stringify([{ name: photo }]), { status: 200 }),
    );
  }) as typeof fetch;
  const lines: string[] = [];
  try {
    const r = await runCleanup(mgmt, "https://example.invalid", {
      ...TARGET,
      userIds: [A, B],
    }, { dryRun: false, log: (l) => lines.push(l) });
    assertEquals(r.ok, true);
    assertEquals(r.deleted, { objects: 1, pairs: 1, users: 2 });
  } finally {
    globalThis.fetch = realFetch;
  }

  assertEquals(storageCalls.length, 1);
  assertEquals(storageCalls[0].method, "DELETE");
  assertEquals(
    storageCalls[0].url,
    "https://example.invalid/storage/v1/object/photos",
  );
  assertEquals(JSON.parse(storageCalls[0].body), { prefixes: [photo] });
  // 順序: secret key → Storage → DB(ペア → ユーザーは 1 回の問い合わせ)→ 確認
  assertEquals(events, ["secret key", "Storage の削除", "DB の削除", "確認"]);
  assertEquals(statements.length, 1);
  const del = statements[0];
  assertEquals(del.indexOf("delete from public.pairs") >= 0, true);
  assertEquals(
    del.indexOf("delete from public.pairs") <
      del.indexOf("delete from auth.users"),
    true,
  );
  // 消す対象は計画した ID だけ(C は計画に入っていない)
  assertEquals(del.includes(A) && del.includes(B) && del.includes(PAIR), true);
  assertEquals(del.includes(C), false);
  assertEquals(lines.some((l) => l.includes("残りは 0 件")), true);
});

Deno.test("実行後に残りがあれば ok = false(終了コード 1 になる)", async () => {
  const mgmt = {
    sql: (q: string) => {
      if (q.includes("from auth.users a left join")) {
        return Promise.resolve([user(A, "E2E-A")]);
      }
      if (q.includes("as auth_users")) {
        return Promise.resolve([{ auth_users: 1, objects: 0 }]);
      }
      return Promise.resolve([]);
    },
    secretKey: () => Promise.resolve("sb_secret_x"),
  } as unknown as Mgmt;
  const lines: string[] = [];
  const r = await runCleanup(mgmt, "https://example.invalid", {
    userIds: [A],
    pairIds: [],
    strict: true,
    source: "test",
  }, { dryRun: false, log: (l) => lines.push(l) });
  assertEquals(r.ok, false);
  assertEquals(lines.some((l) => l.includes("残りがある: auth_users=1")), true);
});

Deno.test("list: 目印かニックネームを持つ匿名ユーザーを返し、--user で消せるものと消せないものを区別する", async () => {
  const { mgmt, queries } = fakeMgmt({
    users: [],
    pairs: [],
    objects: [],
    list: [
      { ...user(A, "E2E-A"), pair_id: PAIR },
      // 途中で止まった実行の残り(目印はあるがニックネームが空・絵文字なし)
      { ...user(B, "", { emoji: "" }), pair_id: null },
      // 目印の無い E2E-C(実ユーザーが付けたニックネームかもしれない)
      { ...user(C, "E2E-C", { marker: null }), pair_id: null },
    ],
  });
  const rows = await listE2eUsers(mgmt);
  assertEquals(rows.map((r) => r.id), [A, B, C]);
  assertEquals(rows[0].problems, []);
  assertEquals(rows[0].pairId, PAIR);
  assertEquals(rows[1].pairId, null);
  assertEquals(rows[1].problems.length >= 2, true);
  assertEquals(
    rows[2].problems.some((p) => p.includes("目印")),
    true,
  );
  // SELECT だけ
  assertEquals(queries.length, 1);
  assertEquals(
    /\b(delete|update|insert|truncate|drop)\b/i.test(queries[0]),
    false,
  );
  // 「消せる」と表示されたものは、--user の厳格な確認(planCleanup strict)も通る
  const planned = await planCleanup(
    fakeMgmt({ users: [user(A, "E2E-A")], pairs: [], objects: [] }).mgmt,
    { ...TARGET, userIds: [A], pairIds: [], strict: true },
  );
  assertEquals(planned.users.map((u) => u.id), [A]);
});
