// cleanup_test.ts — cleanup.ts の安全装置の deno test。本番には触れない(Management API は偽物に差し替える)
//
//   deno test --allow-read products/lien/scripts/e2e/
//
// 後片付けは本番のユーザーを消す操作なので、「通しテストが作ったものだけを消す」安全装置を固定する:
//   匿名ユーザーでニックネームが E2E-A/B/C のものだけ・対象外のメンバーがいるペアは触らない・UUID 以外は SQL に入れない・
//   --dry-run は SELECT だけ。

import type { Mgmt } from "./mgmt.ts";
import { planCleanup, runCleanup } from "./cleanup.ts";

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

async function assertRejects(
  fn: () => Promise<unknown>,
  includes: string,
  msg = "",
): Promise<void> {
  try {
    await fn();
  } catch (e) {
    const text = e instanceof Error ? e.message : String(e);
    if (!text.includes(includes)) {
      throw new Error(
        `期待したメッセージ「${includes}」が無い ${msg}: ${text}`,
      );
    }
    return;
  }
  throw new Error(`例外が出なかった ${msg}`);
}

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const C = "33333333-3333-4333-8333-333333333333";
const OUTSIDER = "99999999-9999-4999-8999-999999999999";
const PAIR = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

interface FakeData {
  users: Array<Record<string, unknown>>;
  pairs: Array<Record<string, unknown>>;
  objects: string[];
}

/** SQL の文面で返す行を決める偽の Management API(実行された SQL を記録する) */
function fakeMgmt(data: FakeData): { mgmt: Mgmt; queries: string[] } {
  const queries: string[] = [];
  const mgmt = {
    sql: (q: string) => {
      queries.push(q);
      if (q.includes("from auth.users a left join")) {
        return Promise.resolve(data.users);
      }
      if (q.includes("from public.pairs p")) return Promise.resolve(data.pairs);
      if (q.includes("from storage.objects")) {
        return Promise.resolve(data.objects.map((name) => ({ name })));
      }
      return Promise.resolve([]);
    },
    secretKey: () =>
      Promise.reject(new Error("dry-run では secret key を取らない")),
  } as unknown as Mgmt;
  return { mgmt, queries };
}

function user(id: string, nickname: string, anon = true) {
  return { id, is_anonymous: anon, nickname, created_jst: "2026-10-13 05:00" };
}

const TARGET = {
  userIds: [A, B, C],
  pairIds: [PAIR],
  strict: false,
  source: "test",
};

Deno.test("通しテストのユーザー(匿名・E2E-A/B/C)とそのペアだけが対象になる", async () => {
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
    users: [user(A, "E2E-A"), user(B, "E2E-B", false)],
    pairs: [],
    objects: [],
  });
  await assertRejects(
    () => planCleanup(mgmt, { ...TARGET, userIds: [A, B] }),
    "何も消さずに止める",
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
    "何も消さずに止める",
  );
});

Deno.test("ニックネームが空のユーザー: 記録した ID なら対象、--user 指定(strict)なら止まる", async () => {
  const data = { users: [user(A, "")], pairs: [], objects: [] };
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
    "何も消さずに止める",
  );
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
