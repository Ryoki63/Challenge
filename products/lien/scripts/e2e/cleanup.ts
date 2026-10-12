// cleanup.ts — 通しテストが本番に作ったデータの後片付け(と、残っているものの一覧)
//
// 消すもの(ユーザー単位の完全削除。T23 のアカウント削除の予行にもなる順序):
//   1. Storage: photos バケットの pairs/<pair_id>/ 以下のオブジェクト(Storage API。secret key を使う)
//   2. DB: ペア(pairs → pair_members / plants / streak_days / ticket_ledger / nudges / ticket_grant_runs が CASCADE)
//   3. DB: auth.users(→ public.users → promises / checkins / reactions / invites が CASCADE。セッションも消える)
//   ペアは users から CASCADE されない(pair_members だけが users を参照する)ので、先に明示的に消す。
//
// 安全装置(本番の実ユーザーを消さないために):
//   - 対象は「この実行が記録した ID」か、--user で明示した ID だけ。ニックネームでの一括削除はしない
//   - 匿名ユーザーで、ニックネームが E2E-A / E2E-B / E2E-C(または、記録した ID に限り空)のものだけ消す。
//     それ以外が混じっていたら何も消さずに止まる
//   - 対象のペアに、対象外のメンバーがいたら何も消さずに止まる
//   - --dry-run で、消す予定の一覧だけを出せる(SELECT のみ)
//   - 消したあとで、残りが 0 件であることを SELECT で確かめる(Storage の実体も)

import { request } from "./client.ts";
import type { Mgmt } from "./mgmt.ts";
import { redact } from "./report.ts";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const MARKER_RE = /^E2E-[ABC]$/;

export interface CleanupTarget {
  userIds: string[];
  /** 記録してある pair_id(ペア行・メンバー行がもう無くても、Storage の実体を探すのに使う) */
  pairIds: string[];
  /** true なら、ニックネームが E2E-A/B/C のものだけを対象にする(--user 指定。空のニックネームは対象外) */
  strict: boolean;
  /** 表示用 */
  source: string;
}

export interface CleanupPlan {
  users: Array<{ id: string; nickname: string; createdJst: string }>;
  /** 記録にあるが、もう DB に無い(削除済み) */
  absentUsers: string[];
  pairs: string[];
  objects: string[];
}

type Row = Record<string, unknown>;

function assertUuids(ids: string[], what: string): void {
  for (const id of ids) {
    if (!UUID_RE.test(id)) throw new Error(`${what} が UUID でない: ${id}`);
  }
}

function uuidArray(ids: string[]): string {
  assertUuids(ids, "ID");
  return `array[${ids.map((i) => `'${i}'`).join(",")}]::uuid[]`;
}

/** 消す予定のものを調べる(SELECT のみ)。安全装置に引っかかったら Error */
export async function planCleanup(
  mgmt: Mgmt,
  t: CleanupTarget,
): Promise<CleanupPlan> {
  assertUuids(t.userIds, "ユーザー ID");
  assertUuids(t.pairIds, "ペア ID");
  const plan: CleanupPlan = {
    users: [],
    absentUsers: [],
    pairs: [],
    objects: [],
  };

  if (t.userIds.length > 0) {
    const rows = await mgmt.sql<Row>(`
      select a.id::text as id, a.is_anonymous, coalesce(u.nickname, '') as nickname,
             to_char(a.created_at at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI') as created_jst
      from auth.users a left join public.users u on u.id = a.id
      where a.id = any(${uuidArray(t.userIds)})
    `);
    const found = new Set<string>();
    const bad: string[] = [];
    for (const r of rows) {
      const id = String(r.id);
      const nickname = String(r.nickname);
      found.add(id);
      const markerOk = MARKER_RE.test(nickname) ||
        (!t.strict && nickname === "");
      if (r.is_anonymous !== true || !markerOk) {
        bad.push(
          `${id}(匿名=${r.is_anonymous}・ニックネーム=${
            JSON.stringify(nickname)
          })`,
        );
      }
      plan.users.push({ id, nickname, createdJst: String(r.created_jst) });
    }
    if (bad.length > 0) {
      throw new Error(
        `通しテストが作ったユーザーに見えないものが対象に混じっている。何も消さずに止める: ${
          bad.join(", ")
        }`,
      );
    }
    plan.absentUsers = t.userIds.filter((id) => !found.has(id));
  }

  const present = plan.users.map((u) => u.id);
  const pairRows = await mgmt.sql<Row>(`
    select p.id::text as pair_id,
           coalesce((select array_agg(pm.user_id::text) from public.pair_members pm where pm.pair_id = p.id), '{}') as members
    from public.pairs p
    where ${
    t.pairIds.length > 0 ? `p.id = any(${uuidArray(t.pairIds)}) or ` : ""
  }p.id in (
      select pair_id from public.pair_members where user_id = any(${
    uuidArray(
      present.length > 0 ? present : ["00000000-0000-0000-0000-000000000000"],
    )
  })
    )
  `);
  const targets = new Set(t.userIds);
  for (const r of pairRows) {
    const members = Array.isArray(r.members) ? (r.members as string[]) : [];
    const outsiders = members.filter((m) => !targets.has(m));
    if (outsiders.length > 0) {
      throw new Error(
        `ペア ${r.pair_id} に、対象外のメンバー(${outsiders.length} 人)がいる。何も消さずに止める`,
      );
    }
    plan.pairs.push(String(r.pair_id));
  }

  const pairIdsForObjects = [...new Set([...t.pairIds, ...plan.pairs])];
  if (pairIdsForObjects.length > 0) {
    const cond = pairIdsForObjects.map((p) => `name like 'pairs/${p}/%'`).join(
      " or ",
    );
    const objs = await mgmt.sql<Row>(
      `select name from storage.objects where bucket_id = 'photos' and (${cond}) order by name`,
    );
    plan.objects = objs.map((o) => String(o.name));
  }
  return plan;
}

export interface CleanupResult {
  ok: boolean;
  plan: CleanupPlan;
  deleted: { objects: number; pairs: number; users: number };
}

/** 後片付けを実行する(dryRun なら計画を出すだけ) */
export async function runCleanup(
  mgmt: Mgmt,
  base: string,
  t: CleanupTarget,
  opts: { dryRun: boolean; log: (line: string) => void },
): Promise<CleanupResult> {
  const { log } = opts;
  const plan = await planCleanup(mgmt, t);
  log(`後片付けの対象(${t.source})`);
  for (const u of plan.users) {
    log(
      `  ユーザー ${u.id}  ${
        u.nickname || "(ニックネーム空)"
      }  作成 ${u.createdJst} JST`,
    );
  }
  for (const id of plan.absentUsers) {
    log(`  ユーザー ${id}  もう DB に無い(削除済み)`);
  }
  for (const p of plan.pairs) log(`  ペア ${p}`);
  log(`  Storage のオブジェクト ${plan.objects.length} 件`);
  const result: CleanupResult = {
    ok: true,
    plan,
    deleted: { objects: 0, pairs: 0, users: 0 },
  };
  if (opts.dryRun) {
    log("  --dry-run のため何も消さない");
    return result;
  }

  // 1. Storage の実体(DB の行より先に。ペアの行が無くなっても、オブジェクトは自動では消えない)
  if (plan.objects.length > 0) {
    const secret = await mgmt.secretKey(); // 万能鍵。この削除にだけ使い、表示しない
    const r = await request("DELETE", `${base}/storage/v1/object/photos`, {
      headers: { apikey: secret, "Content-Type": "application/json" },
      body: JSON.stringify({ prefixes: plan.objects }),
    });
    if (r.status !== 200) {
      throw new Error(
        `Storage の削除に失敗(HTTP ${r.status}) ${
          redact(r.text).slice(0, 200)
        }`,
      );
    }
    result.deleted.objects = Array.isArray(r.json) ? r.json.length : 0;
    log(`  Storage: ${result.deleted.objects} 件を削除`);
  }

  // 2. DB(ペア → ユーザーの順。1 回の問い合わせ = 1 トランザクション)
  const present = plan.users.map((u) => u.id);
  if (plan.pairs.length > 0 || present.length > 0) {
    const stmts: string[] = [];
    if (plan.pairs.length > 0) {
      stmts.push(
        `delete from public.pairs where id = any(${uuidArray(plan.pairs)});`,
      );
    }
    if (present.length > 0) {
      stmts.push(
        `delete from auth.users where id = any(${uuidArray(present)});`,
      );
    }
    await mgmt.sql(stmts.join("\n"));
    result.deleted.pairs = plan.pairs.length;
    result.deleted.users = present.length;
    log(
      `  DB: ペア ${plan.pairs.length} 件・ユーザー ${present.length} 人を削除`,
    );
  }

  // 3. 残りが 0 であることを確かめる
  const uArr = uuidArray(
    t.userIds.length > 0 ? t.userIds : ["00000000-0000-0000-0000-000000000000"],
  );
  const pairIds = [...new Set([...t.pairIds, ...plan.pairs])];
  const pArr = uuidArray(
    pairIds.length > 0 ? pairIds : ["00000000-0000-0000-0000-000000000000"],
  );
  const objCond = pairIds.length > 0
    ? pairIds.map((p) => `name like 'pairs/${p}/%'`).join(" or ")
    : "false";
  const left = (await mgmt.sql<Row>(`
    select
      (select count(*) from auth.users where id = any(${uArr})) as auth_users,
      (select count(*) from public.users where id = any(${uArr})) as profiles,
      (select count(*) from public.pairs where id = any(${pArr})) as pairs,
      (select count(*) from public.pair_members where pair_id = any(${pArr}) or user_id = any(${uArr})) as members,
      (select count(*) from public.promises where user_id = any(${uArr})) as promises,
      (select count(*) from public.checkins where user_id = any(${uArr})) as checkins,
      (select count(*) from public.plants where pair_id = any(${pArr})) as plants,
      (select count(*) from storage.objects where bucket_id = 'photos' and (${objCond})) as objects
  `))[0] ?? {};
  const remaining = Object.entries(left).filter(([, v]) => Number(v) !== 0);
  if (remaining.length > 0) {
    result.ok = false;
    log(`  残りがある: ${remaining.map(([k, v]) => `${k}=${v}`).join(" ")}`);
  } else {
    log(
      "  確認: 残りは 0 件(ユーザー・ペア・メンバー・約束・チェックイン・植物・Storage)",
    );
  }
  return result;
}

/** 通しテストのマーカー(ニックネーム E2E-A/B/C の匿名ユーザー)がまだ残っているものの一覧(SELECT のみ) */
export async function listMarked(
  mgmt: Mgmt,
): Promise<
  Array<
    { id: string; nickname: string; createdJst: string; pairId: string | null }
  >
> {
  const rows = await mgmt.sql<Row>(`
    select a.id::text as id, u.nickname,
           to_char(a.created_at at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI') as created_jst,
           (select pm.pair_id::text from public.pair_members pm where pm.user_id = a.id limit 1) as pair_id
    from auth.users a join public.users u on u.id = a.id
    where a.is_anonymous and u.nickname ~ '^E2E-[ABC]$'
    order by a.created_at
  `);
  return rows.map((r) => ({
    id: String(r.id),
    nickname: String(r.nickname),
    createdJst: String(r.created_jst),
    pairId: r.pair_id === null || r.pair_id === undefined
      ? null
      : String(r.pair_id),
  }));
}
