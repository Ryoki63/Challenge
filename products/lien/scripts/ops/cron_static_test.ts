// cron_static_test.ts — pg_cron の登録(migration)の静的テスト(issue #60 項目6)
//
// 本番の cron は migration の SQL で決まる。そのスケジュール・「JST の1日だけ」の条件・呼び先・認証の鍵が
// 意図どおりであることを、SQL を読んで検査する(DB には触らない)。
//   - 現行の定義 = ジョブ名ごとに「番号がいちばん後ろの migration の cron.schedule」
//   - pg_cron は UTC で動く。cron 式の時刻を JST に直し、1年ぶんの起動日で「毎月1日だけ」を数える
//
// 実行(ファイルを読むので --allow-read が要る。lien-ci の `deno test` には含まれない):
//   deno test --allow-read products/lien/scripts/ops/
//   → .github/workflows/lien-cron-watch.yml の ops-tests ジョブが、関係するファイルの変更ごとに回す

import { JOB_SPECS, jobDrift } from "./cron_check.ts";

const SUPABASE = new URL("../../supabase/", import.meta.url);

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

// ---- 読み込みと解析 ----

interface Migration {
  /** 例: 0007_cron_secret.sql */
  file: string;
  /** 先頭の番号 */
  number: number;
  /** ファイルの全文(コメントを含む) */
  sql: string;
}

async function readMigrations(): Promise<Migration[]> {
  const dir = new URL("migrations/", SUPABASE);
  const files: string[] = [];
  for await (const entry of Deno.readDir(dir)) {
    if (entry.isFile && entry.name.endsWith(".sql")) files.push(entry.name);
  }
  files.sort();
  const migrations: Migration[] = [];
  for (const file of files) {
    const m = /^(\d{4})_[a-z0-9_]+\.sql$/.exec(file);
    if (!m) {
      throw new Error(
        `migration のファイル名が NNNN_name.sql ではない: ${file}`,
      );
    }
    migrations.push({
      file,
      number: Number(m[1]),
      sql: await Deno.readTextFile(new URL(file, dir)),
    });
  }
  return migrations;
}

/** SQL の行コメント(-- ...)を落とす。cron の command にも文字列リテラルにも `--` は使っていない前提 */
function stripSqlComments(sql: string): string {
  return sql.split("\n").map((line) => line.replace(/--.*$/, "")).join("\n");
}

interface CronJob {
  name: string;
  schedule: string;
  command: string;
  migration: string;
}

/** `select cron.schedule('名前', '式', $cron$ ... $cron$)` を全部拾う */
function parseCronJobs(sql: string, migration: string): CronJob[] {
  const text = stripSqlComments(sql);
  const re =
    /cron\.schedule\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*\$cron\$([\s\S]*?)\$cron\$\s*\)/g;
  const jobs: CronJob[] = [];
  for (const m of text.matchAll(re)) {
    jobs.push({ name: m[1], schedule: m[2], command: m[3], migration });
  }
  return jobs;
}

/** 現行のジョブ定義(番号が後ろの migration が前のものを置き換える) */
function effectiveJobs(migrations: Migration[]): Map<string, CronJob> {
  const jobs = new Map<string, CronJob>();
  for (const m of migrations) {
    for (const job of parseCronJobs(m.sql, m.file)) jobs.set(job.name, job);
  }
  return jobs;
}

/** 「M H * * *」(毎日 H:M UTC)だけを受け付ける。それ以外の式は、このテストが想定していない形 */
function parseDailySchedule(expr: string): { minute: number; hour: number } {
  const m = /^(\d{1,2}) (\d{1,2}) \* \* \*$/.exec(expr);
  if (!m) throw new Error(`毎日1回の形(M H * * *)ではない cron 式: ${expr}`);
  const minute = Number(m[1]);
  const hour = Number(m[2]);
  if (minute > 59 || hour > 23) throw new Error(`範囲外の cron 式: ${expr}`);
  return { minute, hour };
}

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

/** UTC の瞬間を JST の暦に直す(JST は UTC+9 でサマータイムなし) */
function jstParts(utcMs: number): {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
} {
  const d = new Date(utcMs + JST_OFFSET_MS);
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
  };
}

/** 2026-01-01 〜 2028-12-31(UTC の日付)に毎日 H:M UTC で起動する瞬間 */
function firings(schedule: { minute: number; hour: number }): number[] {
  const out: number[] = [];
  const start = Date.UTC(2026, 0, 1);
  const end = Date.UTC(2028, 11, 31);
  for (let day = start; day <= end; day += 24 * 60 * 60 * 1000) {
    out.push(day + (schedule.hour * 60 + schedule.minute) * 60 * 1000);
  }
  return out;
}

function normalizeSql(command: string): string {
  return command.replace(/\s+/g, " ").trim().toLowerCase();
}

/** SQL の `where extract(day from (now() at time zone 'Asia/Tokyo')) = 1`(JST の1日だけ通す条件)の文面 */
const JST_FIRST_DAY_GUARD =
  "where extract(day from (now() at time zone 'asia/tokyo')) = 1";

// ---- テスト対象のジョブ ----

const EXPECTED = {
  "lien-grant-tickets": {
    fn: "grant-tickets",
    jstHour: 0,
    jstMinute: 5,
    onlyFirstOfMonth: true,
  },
  "lien-close-day": {
    fn: "close-day",
    jstHour: 0,
    jstMinute: 10,
    onlyFirstOfMonth: false,
  },
} as const;

// ---- パーサ自体のテスト ----

Deno.test("parseCronJobs: コメント内の cron.schedule は拾わず、$cron$ の本文を取り出す", () => {
  const sql = `
    -- select cron.schedule('commented-out', '0 0 * * *', $cron$ select 1; $cron$);
    select cron.schedule(
      'job-a',
      '5 15 * * *',
      $cron$
      select 1;  -- コメント
      $cron$
    );
    select cron.schedule('job-b', '10 15 * * *', $cron$ select 2; $cron$);
  `;
  const jobs = parseCronJobs(sql, "x.sql");
  assertEquals(jobs.map((j) => [j.name, j.schedule]), [
    ["job-a", "5 15 * * *"],
    ["job-b", "10 15 * * *"],
  ]);
  assertEquals(normalizeSql(jobs[0].command), "select 1;");
});

Deno.test("effectiveJobs: 番号が後ろの migration が同名ジョブを置き換える", () => {
  const old =
    `select cron.schedule('j', '0 1 * * *', $cron$ select 'old'; $cron$);`;
  const next =
    `select cron.schedule('j', '0 2 * * *', $cron$ select 'new'; $cron$);`;
  const jobs = effectiveJobs([
    { file: "0001_a.sql", number: 1, sql: old },
    { file: "0002_b.sql", number: 2, sql: next },
  ]);
  assertEquals(jobs.get("j")?.schedule, "0 2 * * *");
  assertEquals(jobs.get("j")?.migration, "0002_b.sql");
});

Deno.test("parseDailySchedule: 毎日1回の形だけ受け付ける", () => {
  assertEquals(parseDailySchedule("5 15 * * *"), { minute: 5, hour: 15 });
  for (
    const bad of [
      "*/5 * * * *",
      "5 15 1 * *",
      "5 15 * * 1",
      "60 15 * * *",
      "5 24 * * *",
      "5 15 * *",
    ]
  ) {
    let threw = false;
    try {
      parseDailySchedule(bad);
    } catch {
      threw = true;
    }
    assert(threw, `拒否されるはず: ${bad}`);
  }
});

// ---- 実際の migration の検査 ----

Deno.test("migration: 番号は 0001 から欠番・重複なしで連番(並列の作業で番号が衝突していない)", async () => {
  const migrations = await readMigrations();
  assertEquals(
    migrations.map((m) => m.number),
    migrations.map((_, i) => i + 1),
    "番号が連番でない(欠番または重複)",
  );
});

Deno.test("migration: 秘密らしい文字列を書いていない(JWT・sb_secret_・アクセストークン)", async () => {
  const patterns: Array<[string, RegExp]> = [
    ["JWT(eyJ...)", /eyJ[A-Za-z0-9_-]{20,}/],
    ["sb_secret_ のキー", /sb_secret_[A-Za-z0-9_-]{10,}/],
    ["アクセストークン sbp_", /sbp_[A-Za-z0-9]{20,}/],
    ["APNs の秘密鍵", /BEGIN (EC |RSA )?PRIVATE KEY/],
  ];
  for (const m of await readMigrations()) {
    for (const [label, re] of patterns) {
      assert(!re.test(m.sql), `${m.file} に ${label} が書かれている`);
    }
  }
});

Deno.test("migration: 本番 URL を直書きしているファイルには注意コメントがある(別プロジェクトへ適用する事故の予防)", async () => {
  const config = await Deno.readTextFile(new URL("config.toml", SUPABASE));
  const projectId = /^project_id\s*=\s*"([a-z0-9]+)"/m.exec(config)?.[1];
  assert(!!projectId, "config.toml に project_id がない");
  let found = 0;
  for (const m of await readMigrations()) {
    if (!m.sql.includes(".supabase.co")) continue;
    found++;
    assert(
      m.sql.includes(
        `【注意】本番プロジェクト(${projectId})の URL を直書きしている`,
      ),
      `${m.file} は本番 URL を直書きしているのに、注意コメント(【注意】本番プロジェクト(${projectId})の URL を直書きしている)がない`,
    );
  }
  assert(
    found >= 2,
    "URL を直書きした migration が見つからない(0003 と 0007 のはず)",
  );
});

Deno.test("cron: 現行のジョブは lien-close-day と lien-grant-tickets の2つだけ", async () => {
  const jobs = effectiveJobs(await readMigrations());
  assertEquals([...jobs.keys()].sort(), [
    "lien-close-day",
    "lien-grant-tickets",
  ]);
});

Deno.test("cron: スケジュールは JST の 00:10(close-day)と 00:05(grant-tickets)で、付与が確定より先", async () => {
  const jobs = effectiveJobs(await readMigrations());
  const times: Record<string, number> = {};
  for (const [name, exp] of Object.entries(EXPECTED)) {
    const job = jobs.get(name);
    assert(!!job, `${name} がない`);
    const sched = parseDailySchedule(job!.schedule);
    // 起動する UTC の時刻を JST に直す(UTC 15:05 → JST 翌日 00:05)
    const first = jstParts(firings(sched)[0]);
    assertEquals(
      [first.hour, first.minute],
      [exp.jstHour, exp.jstMinute],
      `${name} の JST の起動時刻(式 ${job!.schedule})`,
    );
    times[name] = first.hour * 60 + first.minute;
  }
  assert(
    times["lien-grant-tickets"] < times["lien-close-day"],
    "月初は付与(00:05)が確定(00:10)より先に動く必要がある(付与で救えるリセットを起こさない)",
  );
});

Deno.test("cron: grant-tickets は「JST の1日だけ」呼ぶ — 毎月1日の 00:05 JST に1回ずつ(文面と、3年36か月ぶんの実際の起動日の両方)", async () => {
  const job = (effectiveJobs(await readMigrations())).get(
    "lien-grant-tickets",
  )!;
  const sql = normalizeSql(job.command);

  // 文面: 条件は select 文の最後の where で、JST の暦の日が 1 のときだけ
  assert(
    sql.endsWith(`${JST_FIRST_DAY_GUARD};`),
    `grant-tickets の command が「${JST_FIRST_DAY_GUARD};」で終わっていない: ${sql}`,
  );
  assert(
    sql.startsWith("select net.http_post("),
    "select net.http_post(...) where ... の形ではない",
  );
  assert(
    !sql.includes("'utc'"),
    "条件を UTC の日付で判定してはいけない(JST の1日は UTC では前月末の 15:00 以降)",
  );

  // 実際の起動日: 毎日 15:05 UTC に起動し、JST の日が 1 のものだけ通すと、毎月ちょうど1回(JST 00:05)
  const sched = parseDailySchedule(job.schedule);
  const calls = firings(sched).map(jstParts).filter((p) => p.day === 1);
  const perMonth = new Map<string, number>();
  for (const p of calls) {
    const key = `${p.year}-${String(p.month).padStart(2, "0")}`;
    perMonth.set(key, (perMonth.get(key) ?? 0) + 1);
    assertEquals([p.hour, p.minute], [0, 5], `${key} の呼び出しは JST 00:05`);
  }
  // 起動の範囲は UTC 2026-01-01 〜 2028-12-31 の 15:05。JST の1日に当たる最初は UTC 2026-01-31 15:05
  // (= JST 2026-02-01 00:05)、最後は UTC 2028-12-31 15:05(= JST 2029-01-01 00:05)なので、
  // 2026-02 〜 2029-01 の36か月で36回
  assertEquals(calls.length, 36, "36か月で36回(毎月ちょうど1回)");
  for (const [key, n] of perMonth) assertEquals(n, 1, `${key} は月に1回`);
});

Deno.test("cron: close-day は毎日呼ぶ(日付の条件なし)— 起動日ごとに JST の昨日を確定して、抜けも重複もない", async () => {
  const job = (effectiveJobs(await readMigrations())).get("lien-close-day")!;
  const sql = normalizeSql(job.command);
  assert(
    !sql.includes("extract("),
    "close-day に日付の条件を付けてはいけない(毎日呼ぶ)",
  );
  assert(
    sql.endsWith(");"),
    "close-day の command は net.http_post(...) の閉じ括弧で終わる(外側に where を付けない)",
  );

  // 毎日 15:10 UTC = JST 翌日 00:10。起動日(JST)が1日ずつ進む = 確定する昨日が1日ずつ進む
  const days = firings(parseDailySchedule(job.schedule)).map(jstParts);
  for (let i = 1; i < days.length; i++) {
    const prev = Date.UTC(
      days[i - 1].year,
      days[i - 1].month - 1,
      days[i - 1].day,
    );
    const cur = Date.UTC(days[i].year, days[i].month - 1, days[i].day);
    assertEquals(
      (cur - prev) / (24 * 60 * 60 * 1000),
      1,
      `起動 ${i} の JST の日付が前日の翌日になっていない`,
    );
  }
});

Deno.test("cron: 認証は Vault の lien_cron_secret だけ — 万能鍵(lien_service_role_key)を参照しない", async () => {
  const jobs = effectiveJobs(await readMigrations());
  for (const [name, job] of jobs) {
    const sql = normalizeSql(job.command);
    assert(
      sql.includes(
        "from vault.decrypted_secrets where name = 'lien_cron_secret'",
      ),
      `${name}: Vault の lien_cron_secret を引いていない`,
    );
    assert(
      !sql.includes("lien_service_role_key"),
      `${name}: 万能鍵を参照している`,
    );
    assert(
      sql.includes("'authorization', 'bearer ' || ("),
      `${name}: Authorization: Bearer <秘密> の形ではない`,
    );
    // 秘密を command の文字列に直接書かない(Vault から実行時に引く)
    assert(
      !/'bearer [a-z0-9]{20,}'/.test(sql),
      `${name}: Bearer に秘密を直書きしている`,
    );
    assert(
      /timeout_milliseconds := \d+/.test(sql),
      `${name}: timeout を指定していない`,
    );
  }
});

Deno.test("cron: 本文は {}(close-day は昨日・通知あり、grant-tickets は今月)— notify や日付を固定していない", async () => {
  const jobs = effectiveJobs(await readMigrations());
  for (const [name, job] of jobs) {
    assert(
      normalizeSql(job.command).includes("body := '{}'::jsonb"),
      `${name}: 本文が {} ではない(notify:false や日付を固定すると、通知が黙って止まる・毎晩同じ日を確定するのに起動は succeeded のまま)`,
    );
  }
});

Deno.test("cron: 監視(cron_check.ts の JOB_SPECS / jobDrift)が期待する定義が、migration の現行の定義と一致する", async () => {
  const config = await Deno.readTextFile(new URL("config.toml", SUPABASE));
  const projectId = /^project_id\s*=\s*"([a-z0-9]+)"/m.exec(config)?.[1];
  assert(!!projectId, "config.toml に project_id がない");
  const jobs = effectiveJobs(await readMigrations());

  // 監視が知っているジョブ = migration の現行のジョブ(増減したら、監視の想定外のジョブの検知が誤報になる)
  assertEquals(
    [...jobs.keys()].sort(),
    Object.values(JOB_SPECS).map((j) => j.name).sort(),
    "監視(JOB_SPECS)と migration のジョブの組が違う",
  );
  for (const spec of Object.values(JOB_SPECS)) {
    const job = jobs.get(spec.name)!;
    assertEquals(
      jobDrift(job, spec, projectId!),
      [],
      `${spec.name}: migration の定義が監視(cron_check.ts の JOB_SPECS)の期待とずれている。どちらかを直す`,
    );
  }

  // 実際の migration の文面を壊したとき、監視がずれとして検知できること(監視の判定が空振りしていない)
  const grant = jobs.get(JOB_SPECS.grantTickets.name)!;
  const withoutGuard = {
    ...grant,
    command: grant.command.replace(/where extract\([\s\S]*?\)\s*=\s*1/i, ""),
  };
  assert(
    withoutGuard.command !== grant.command,
    "テストの前提: 条件を取り除けていない",
  );
  assert(
    jobDrift(withoutGuard, JOB_SPECS.grantTickets, projectId!).length > 0,
    "「JST の1日だけ」の条件を外した定義を、監視が検知できない",
  );
  const close = jobs.get(JOB_SPECS.closeDay.name)!;
  const withNotifyOff = {
    ...close,
    command: close.command.replace("'{}'::jsonb", `'{"notify":false}'::jsonb`),
  };
  assert(
    jobDrift(withNotifyOff, JOB_SPECS.closeDay, projectId!).length > 0,
    '本文を {"notify":false} に固定した定義を、監視が検知できない',
  );
});

Deno.test("cron: 呼び先の URL は config.toml の project_id と Function 名に一致し、Function は verify_jwt=false で存在する", async () => {
  const config = await Deno.readTextFile(new URL("config.toml", SUPABASE));
  const projectId = /^project_id\s*=\s*"([a-z0-9]+)"/m.exec(config)?.[1];
  assert(!!projectId, "config.toml に project_id がない");
  const jobs = effectiveJobs(await readMigrations());
  for (const [name, exp] of Object.entries(EXPECTED)) {
    const job = jobs.get(name)!;
    const url = /url := '([^']+)'/.exec(job.command)?.[1];
    assertEquals(
      url,
      `https://${projectId}.supabase.co/functions/v1/${exp.fn}`,
      `${name} の呼び先`,
    );
    // verify_jwt=false(cron の秘密は JWT ではないので、gateway の JWT 検証を通せない)
    const section = new RegExp(
      `\\[functions\\.${exp.fn}\\]\\s*\\n\\s*verify_jwt\\s*=\\s*false`,
    );
    assert(
      section.test(config),
      `config.toml に [functions.${exp.fn}] verify_jwt = false がない`,
    );
    const index = await Deno.readTextFile(
      new URL(`functions/${exp.fn}/index.ts`, SUPABASE),
    );
    assert(index.length > 0, `functions/${exp.fn}/index.ts がない`);
  }
});

Deno.test("cron: close-day / grant-tickets の index.ts は LIEN_CRON_SECRET で認証し、service role key は DB 接続だけに使う", async () => {
  for (const fn of ["close-day", "grant-tickets"]) {
    const index = await Deno.readTextFile(
      new URL(`functions/${fn}/index.ts`, SUPABASE),
    );
    assert(
      index.includes('Deno.env.get("LIEN_CRON_SECRET")'),
      `${fn}: LIEN_CRON_SECRET を読んでいない`,
    );
    assert(
      index.includes("secret: CRON_SECRET"),
      `${fn}: handleCronRequest に CRON_SECRET を渡していない`,
    );
    assert(
      !/secret:\s*SERVICE_ROLE_KEY/.test(index),
      `${fn}: service role key で認証している`,
    );
    assert(
      !/token\s*!==\s*SERVICE_ROLE_KEY/.test(index),
      `${fn}: service role key との比較が残っている`,
    );
    assert(
      index.includes("createClient(SUPABASE_URL, SERVICE_ROLE_KEY"),
      `${fn}: DB 接続は service role key で作る`,
    );
  }
});

Deno.test("grant-tickets: index.ts が呼ぶ RPC の名前・引数名が migration 0006 の関数と一致する", async () => {
  const migrations = await readMigrations();
  const m = migrations.find((x) => x.file.startsWith("0006_"));
  assert(!!m, "0006 の migration がない");
  const sql = stripSqlComments(m!.sql);
  const def = /create or replace function public\.(\w+)\(([\s\S]*?)\)\s*returns/
    .exec(sql);
  assert(!!def, "0006 に create or replace function がない");
  const sqlName = def![1];
  const sqlParams = def![2].split(",").map((p) => p.trim().split(/\s+/)[0])
    .sort();

  const index = await Deno.readTextFile(
    new URL("functions/grant-tickets/index.ts", SUPABASE),
  );
  const call = /db\.rpc\("(\w+)",\s*\{([\s\S]*?)\}\)/.exec(index);
  assert(!!call, "grant-tickets/index.ts に db.rpc(...) がない");
  const tsParams = [...call![2].matchAll(/(\bp_\w+)\s*:/g)].map((x) => x[1])
    .sort();

  assertEquals(call![1], sqlName, "RPC の名前");
  assertEquals(tsParams, sqlParams, "RPC の引数名");

  // service_role 以外から呼べない(PostgREST の /rpc で外から叩かれない)
  assert(
    /revoke all on function public\.apply_monthly_ticket_grant\(uuid, date, date, int\)\s+from public, anon, authenticated/
      .test(sql),
    "0006 が anon / authenticated / public の EXECUTE を剥がしていない",
  );
  assert(
    /grant execute on function public\.apply_monthly_ticket_grant\(uuid, date, date, int\)\s+to service_role/
      .test(sql),
    "0006 が service_role にだけ EXECUTE を渡していない",
  );
});

Deno.test("grant-tickets: 旧来の印(同月の ledger monthly 行)の判定を消さない — invite-accept の初期付与が今もこの印を残す", async () => {
  // 旧来の印は 0006 より前の付与のためだけのものではない。invite-accept は初期付与を
  // reason='monthly'・date_local = started_on で ledger に書き、実行記録(ticket_grant_runs)は作らない。
  // grant-tickets の事前チェックがこの印を見なくなると、ペアを作った月の付与が上乗せされる
  // (月初の直前にできた premium ペアに +5 など)
  const accept = await Deno.readTextFile(
    new URL("functions/invite-accept/core.ts", SUPABASE),
  );
  assert(
    /reason:\s*"monthly",\s*dateLocal:\s*startedOn/.test(accept),
    "invite-accept の初期付与が ledger monthly(date_local = started_on)を書かなくなった。grant-tickets の旧来の印の扱いを見直す",
  );

  const index = await Deno.readTextFile(
    new URL("functions/grant-tickets/index.ts", SUPABASE),
  );
  const from = index.indexOf("async hasMonthlyGrantInMonth(");
  const to = index.indexOf("async applyMonthlyGrant(", from);
  assert(from >= 0 && to > from, "hasMonthlyGrantInMonth が見つからない");
  const check = index.slice(from, to);
  assert(
    check.includes('.from("ticket_grant_runs")'),
    "実行記録(ticket_grant_runs)を見ていない",
  );
  assert(
    check.includes('.from("ticket_ledger")') &&
      check.includes('.eq("reason", "monthly")') &&
      check.includes('.gte("date_local", monthStart)') &&
      check.includes('.lt("date_local", nextMonthStart)'),
    "同月の ledger monthly 行(旧来の印 = invite-accept の初期付与など)を処理済みの判定に使っていない。「旧来だから」と消してはいけない",
  );
});
