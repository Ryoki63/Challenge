// e2e.ts — 本番 Supabase に対する 2 ユーザーの API 通しテスト(issue #67。T20 の実機 E2E の前段)
//
// 何をするか:
//   新しい匿名ユーザー 3 人(ペアになる A / B と、ペア外の C)を本番に作り、アプリが実際に呼ぶ API を
//   プロフィール → 約束 → 招待・ペア成立 → チェックイン(写真は署名付きアップロード)→ snapshot →
//   相手が photo_path を読んで署名付き URL を作る(#59 PV)→ nudge / react → 植物の名前 → 取消 →
//   push 登録の読み書き(PushTokenSync)の順に通す。各応答は products/lien/contracts/ のフィクスチャと
//   形(キー・型)で突き合わせ、ずれを報告する。詳しい手順・使い方は scripts/OPS.md の「通しテスト」。
//
// 使い方(リポジトリルートから。本番を叩くので手動実行のみ。CI では動かさない):
//   set -a; source .env; set +a          # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
//   bash products/lien/scripts/e2e/run.sh check                      # 環境の確認だけ(データは作らない)
//   bash products/lien/scripts/e2e/run.sh run                        # 通しテスト(データは残る)
//   bash products/lien/scripts/e2e/run.sh run --cleanup              # 通しテスト → 最後に片付ける
//   bash products/lien/scripts/e2e/run.sh cleanup --dry-run          # 直近の実行の後片付けの予定だけ見る
//   bash products/lien/scripts/e2e/run.sh cleanup                    # 直近の実行が作ったデータを削除
//   bash products/lien/scripts/e2e/run.sh cleanup --user <uuid> ...  # ID を指定して削除(通しテストの目印がそろったものだけ)
//   bash products/lien/scripts/e2e/run.sh list                       # 残っている通しテストのものらしいユーザーを一覧(SELECT のみ)
//
// オプション(run): --cleanup(SUPABASE_ACCESS_TOKEN が要る。無ければ何も作らずに止まる)/ --no-outsider(C を作らない)/
//                 --no-db-checks(最後の DB の SELECT を省く)/
//                 --force-time(JST 23:50〜00:15 の実行制限を無視する。cron と重なるので勧めない)
// 環境変数: SUPABASE_ACCESS_TOKEN(キー取得・DB 確認・後片付けに必要)/ SUPABASE_ANON_KEY(任意。指定すれば
//   Management API なしで run できる)/ PROJECT_REF(既定 lniheehfbtpfhglinfjm)/ E2E_STATE_DIR(状態ファイルの置き場所)
// 終了コード: 0 = すべて PASS / 1 = FAIL、または契約フィクスチャとのずれが 1 件でもある(または後片付けの失敗)/
//   2 = 使い方・環境の誤り
//
// 守っていること: close-day / grant-tickets は呼ばない(OPS §10)/ 鍵・JWT は表示しない / CI(CI=true)では
//   E2E_ALLOW_CI=1 が無い限り動かない / JST 23:50〜00:15 は動かない(cron の 00:05・00:10 と日付の変わり目を避ける)

import { listE2eUsers, runCleanup } from "./cleanup.ts";
import { Api, requestLog } from "./client.ts";
import { loadFixtures } from "./fixtures.ts";
import { E2E_EMOJI, E2E_META_KEY, E2E_NICKNAME_RE } from "./marker.ts";
import { Mgmt } from "./mgmt.ts";
import { Abort, redact, Reporter } from "./report.ts";
import { runScenario } from "./scenario.ts";
import {
  latestStateFile,
  markStateCleaned,
  readState,
  StateStore,
} from "./state.ts";

const DEFAULT_REF = "lniheehfbtpfhglinfjm";
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const USAGE = `使い方: run.sh <コマンド> [オプション]

  check                    環境の確認だけ(キー・プロジェクトの状態・フィクスチャ。データは作らない)
  run [--cleanup]          通しテスト。--cleanup で最後に作ったデータを片付ける
        --no-outsider      ペア外のユーザー C を作らない
        --no-db-checks     最後の DB の SELECT を省く
        --force-time       JST 23:50〜00:15 の実行制限を無視する(勧めない)
                           ※ --cleanup には SUPABASE_ACCESS_TOKEN が要る(無ければ何も作らずに止まる)
  cleanup [--dry-run]      直近の run が作ったデータを削除する(--dry-run は予定を出すだけ)
        --state <file>     状態ファイルを指定する
        --user <uuid>      ID を指定する(複数可。通しテストの目印がそろった匿名ユーザーだけ。
                           --state とは同時に指定できない・空の値は誤りとして止める)
  list                     残っている通しテストのものらしいユーザーを一覧する(SELECT のみ)

環境変数: SUPABASE_ACCESS_TOKEN / SUPABASE_ANON_KEY(任意)/ PROJECT_REF / E2E_STATE_DIR
`;

export interface Args {
  cmd: "run" | "check" | "cleanup" | "list" | "help";
  cleanupAfter: boolean;
  outsider: boolean;
  dbChecks: boolean;
  forceTime: boolean;
  dryRun: boolean;
  stateFile: string | null;
  userIds: string[];
}

export function parseArgs(argv: string[]): Args {
  const a: Args = {
    cmd: "run",
    cleanupAfter: false,
    outsider: true,
    dbChecks: true,
    forceTime: false,
    dryRun: false,
    stateFile: null,
    userIds: [],
  };
  const rest = [...argv];
  const first = rest[0];
  if (first && !first.startsWith("-")) {
    if (!["run", "check", "cleanup", "list", "help"].includes(first)) {
      throw new UsageError(`知らないコマンド: ${first}`);
    }
    a.cmd = first as Args["cmd"];
    rest.shift();
  }
  while (rest.length > 0) {
    const f = rest.shift() as string;
    const value = (name: string): string => {
      const eq = f.indexOf("=");
      if (eq >= 0) return f.slice(eq + 1);
      const v = rest.shift();
      if (v === undefined) throw new UsageError(`${name} には値が要る`);
      return v;
    };
    if (f === "--cleanup") a.cleanupAfter = true;
    else if (f === "--no-outsider") a.outsider = false;
    else if (f === "--no-db-checks") a.dbChecks = false;
    else if (f === "--force-time") a.forceTime = true;
    else if (f === "--dry-run") a.dryRun = true;
    else if (f === "--state" || f.startsWith("--state=")) {
      const v = value("--state").trim();
      if (v === "") {
        throw new UsageError("--state にはファイルのパスが要る(空だった)");
      }
      a.stateFile = v;
    } else if (f === "--user" || f.startsWith("--user=")) {
      const ids = value("--user").split(",").map((s) => s.trim().toLowerCase())
        .filter(Boolean);
      // 空の値を黙って捨てると、ID を指定したつもりで「直近の状態ファイルを消す」に切り替わってしまう
      if (ids.length === 0) {
        throw new UsageError(
          "--user には UUID が要る(空だった。直近の状態ファイルの削除に切り替えることはしない)",
        );
      }
      a.userIds.push(...ids);
    } else if (f === "-h" || f === "--help") a.cmd = "help";
    else throw new UsageError(`知らないオプション: ${f}`);
  }
  if (a.userIds.length > 0 && a.stateFile !== null) {
    throw new UsageError(
      "--user と --state は同時に指定できない(どちらを消すのか曖昧になる)",
    );
  }
  return a;
}

export class UsageError extends Error {}

/**
 * run の前提を、本番に何かを作る前に確かめる(純粋関数。環境変数の読み取りは呼び出し側)。
 * --cleanup は後片付けに Management API を使うので、トークンが無いまま流すと、本番にデータを作ったあとで
 * 「後片付けできない」(終了コード 2)で終わってしまう。それを S01 の前に止める
 */
export function checkRunPrerequisites(
  args: Pick<Args, "cleanupAfter">,
  have: { accessToken: boolean; anonKey: boolean },
): void {
  if (!have.accessToken && !have.anonKey) {
    throw new UsageError(
      "SUPABASE_ACCESS_TOKEN か SUPABASE_ANON_KEY が要る(set -a; source .env; set +a)",
    );
  }
  if (args.cleanupAfter && !have.accessToken) {
    throw new UsageError(
      "--cleanup には SUPABASE_ACCESS_TOKEN が要る(後片付けは Management API を使う)。このまま流すと本番にデータを作ったあとで片付けられないので、何も作らずに止める(set -a; source .env; set +a)",
    );
  }
}

function color(): boolean {
  try {
    return Deno.stdout.isTerminal() && Deno.env.get("NO_COLOR") === undefined;
  } catch {
    return false;
  }
}

/** JST の「今」: 日付・時・分 */
function jstNow(
  now = new Date(),
): { date: string; hour: number; minute: number; text: string } {
  const date = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Tokyo" })
    .format(now);
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Tokyo",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(now);
  const hour = Number(parts.find((p) => p.type === "hour")?.value) % 24;
  const minute = Number(parts.find((p) => p.type === "minute")?.value);
  return {
    date,
    hour,
    minute,
    text: `${date} ${String(hour).padStart(2, "0")}:${
      String(minute).padStart(2, "0")
    } JST`,
  };
}

/** JST 23:50〜00:15 か(cron の 00:05 / 00:10 と、日付の変わり目を避ける) */
export function inQuietWindow(hour: number, minute: number): boolean {
  const t = hour * 60 + minute;
  return t >= 23 * 60 + 50 || t < 15;
}

function stateDir(): string {
  const dir = Deno.env.get("E2E_STATE_DIR");
  if (dir) return dir.replace(/\/+$/, "");
  const tmp = (Deno.env.get("TMPDIR") ?? "/tmp").replace(/\/+$/, "");
  return `${tmp}/lien-e2e`;
}

interface Env {
  ref: string;
  base: string;
  mgmt: Mgmt | null;
}

function readEnv(): Env {
  const ref = Deno.env.get("PROJECT_REF") || DEFAULT_REF;
  const token = Deno.env.get("SUPABASE_ACCESS_TOKEN");
  return {
    ref,
    base: `https://${ref}.supabase.co`,
    mgmt: token ? new Mgmt(token, ref) : null,
  };
}

function guardCi(): void {
  if (Deno.env.get("CI") && Deno.env.get("E2E_ALLOW_CI") !== "1") {
    throw new UsageError(
      "CI 上では動かさない(本番にユーザーを作る手動実行専用)。意図して流すなら E2E_ALLOW_CI=1",
    );
  }
}

function slowest(n: number): string {
  const top = [...requestLog].sort((x, y) => y.ms - x.ms).slice(0, n);
  return top.map((r) => `${r.label} ${r.ms}ms`).join(" / ");
}

async function cmdCheck(): Promise<number> {
  guardCi();
  const env = readEnv();
  const now = jstNow();
  console.log(`プロジェクト: ${env.ref}(${env.base})`);
  console.log(
    `いま: ${now.text}${
      inQuietWindow(now.hour, now.minute)
        ? "  ← 実行制限の時間帯(JST 23:50〜00:15)"
        : ""
    }`,
  );
  const fx = await loadFixtures();
  console.log(
    `フィクスチャ: ${Object.keys(fx.raw).length} ファイルを読んだ(contracts/)`,
  );
  if (!env.mgmt) {
    console.log(
      "SUPABASE_ACCESS_TOKEN: 無し(キー取得・DB 確認・後片付けは使えない)",
    );
    if (!Deno.env.get("SUPABASE_ANON_KEY")) {
      console.log("SUPABASE_ANON_KEY も無いので run できない");
      return 2;
    }
  } else {
    console.log(`プロジェクトの状態: ${await env.mgmt.projectStatus()}`);
    const k = await env.mgmt.publicKey();
    console.log(`公開キー: ${k.kind}(値は表示しない)`);
  }
  console.log(`状態ファイルの置き場所: ${stateDir()}`);
  return 0;
}

async function cmdRun(args: Args): Promise<number> {
  guardCi();
  const env = readEnv();
  checkRunPrerequisites(args, {
    accessToken: env.mgmt !== null,
    anonKey: Boolean(Deno.env.get("SUPABASE_ANON_KEY")),
  });
  const now = jstNow();
  if (inQuietWindow(now.hour, now.minute) && !args.forceTime) {
    throw new UsageError(
      `いまは ${now.text}。JST 23:50〜00:15 は cron(00:05 grant-tickets / 00:10 close-day)と日付の変わり目に重なるので動かさない(--force-time で無視できるが勧めない)`,
    );
  }
  const fx = await loadFixtures();

  // 公開キー(アプリが使うキーと同じ種類): 環境変数が優先、無ければ Management API から
  let anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  let keyKind = "環境変数 SUPABASE_ANON_KEY";
  if (!anonKey) {
    if (!env.mgmt) {
      throw new UsageError(
        "SUPABASE_ACCESS_TOKEN か SUPABASE_ANON_KEY が要る(set -a; source .env; set +a)",
      );
    }
    const k = await env.mgmt.publicKey();
    anonKey = k.key;
    keyKind = `Management API の ${k.kind} キー`;
  }
  if (env.mgmt) {
    const status = await env.mgmt.projectStatus();
    if (status !== "ACTIVE_HEALTHY") {
      throw new UsageError(
        `プロジェクトが ${status}(ACTIVE_HEALTHY でない。無料枠の自動停止なら OPS §5)`,
      );
    }
  }
  const api = new Api(env.base, anonKey);
  const health = await api.authHealth();
  if (health.status !== 200) {
    throw new UsageError(
      `Auth が応答しない(GET /auth/v1/health → HTTP ${health.status})`,
    );
  }

  const dir = stateDir();
  await Deno.mkdir(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(
    /\.\d+Z$/,
    "Z",
  );
  const file = `${dir}/run-${stamp}.json`;
  const state = new StateStore(file, {
    ref: env.ref,
    startedAt: new Date().toISOString(),
    today: now.date,
  });
  await state.save();

  const rep = new Reporter(console.log, color());
  console.log(`== Lien API 通しテスト(本番 ${env.ref})${now.text} ==`);
  console.log(
    `公開キー: ${keyKind}(値は表示しない) / 今日(JST): ${now.date} / DB の確認: ${
      args.dbChecks && env.mgmt ? "あり" : "なし"
    }`,
  );

  let aborted = false;
  try {
    await runScenario({
      api,
      rep,
      fx,
      state,
      today: now.date,
      mgmt: env.mgmt,
      options: { outsider: args.outsider, dbChecks: args.dbChecks },
    });
  } catch (e) {
    aborted = true;
    if (!(e instanceof Abort)) {
      rep.fail(
        "予期しない例外で中断",
        e instanceof Error ? e.message : String(e),
      );
    }
  }

  for (const line of rep.summaryLines()) console.log(line);
  console.log("");
  console.log(`リクエスト ${requestLog.length} 回 / 最遅: ${slowest(3)}`);
  console.log("");
  console.log("==== 作ったデータ(OPS §8 の台帳へ。後片付けの入力) ====");
  console.log(`  状態ファイル: ${file}`);
  for (const [label, id] of Object.entries(state.data.users)) {
    console.log(`  ユーザー ${label}: ${id}`);
  }
  console.log(`  ペア: ${state.data.pairId ?? "(なし)"}`);
  console.log(
    `  Storage に置いた写真: ${state.data.storagePaths.length} 件(pairs/<ペア>/ 以下)`,
  );

  // FAIL だけでなく、契約フィクスチャとのずれ(rep.deviations)が 1 件でもあれば失敗として終わる
  let code = rep.hasProblems || aborted ? 1 : 0;
  if (args.cleanupAfter) {
    console.log("");
    console.log("==== 後片付け(--cleanup) ====");
    code = Math.max(code, await doCleanupFromState(env, file, false));
  } else {
    console.log("");
    console.log(
      `後片付け: bash products/lien/scripts/e2e/run.sh cleanup --state ${file}`,
    );
  }
  console.log("");
  console.log(
    code === 0
      ? "結果: PASS"
      : "結果: FAIL(上の「失敗」「契約フィクスチャとのずれ」を見る)",
  );
  return code;
}

async function doCleanupFromState(
  env: Env,
  file: string,
  dryRun: boolean,
): Promise<number> {
  if (!env.mgmt) {
    console.log(
      "SUPABASE_ACCESS_TOKEN が無いので後片付けできない(set -a; source .env; set +a)",
    );
    return 2;
  }
  let st;
  try {
    st = await readState(file);
  } catch (e) {
    // 権限エラー(E2E_STATE_DIR の外)・存在しない・形式違いを、同じ案内にまとめる
    const why = e instanceof Error ? e.message.split("\n")[0] : String(e);
    console.log(
      `状態ファイルを読めない: ${file}\n  ${
        redact(why)
      }\n  状態ファイルは E2E_STATE_DIR(既定 ${stateDir()})の中のものを指定する`,
    );
    return 2;
  }
  if (st.ref !== env.ref) {
    console.log(
      `状態ファイルのプロジェクト(${st.ref})と今のプロジェクト(${env.ref})が違う`,
    );
    return 2;
  }
  const r = await runCleanup(
    env.mgmt,
    env.base,
    {
      userIds: Object.values(st.users),
      pairIds: st.pairId ? [st.pairId] : [],
      strict: false,
      source: `状態ファイル ${file}`,
    },
    { dryRun, log: (l) => console.log(l) },
  );
  if (r.ok && !dryRun) await markStateCleaned(file, new Date().toISOString());
  return r.ok ? 0 : 1;
}

async function cmdCleanup(args: Args): Promise<number> {
  guardCi();
  const env = readEnv();
  if (!env.mgmt) {
    console.log("SUPABASE_ACCESS_TOKEN が要る(set -a; source .env; set +a)");
    return 2;
  }
  if (args.userIds.length > 0) {
    for (const id of args.userIds) {
      if (!UUID_RE.test(id)) {
        throw new UsageError(`--user が UUID でない: ${id}`);
      }
    }
    const r = await runCleanup(
      env.mgmt,
      env.base,
      {
        userIds: args.userIds,
        pairIds: [],
        strict: true,
        source:
          `--user 指定(目印 ${E2E_META_KEY}・ニックネーム ${E2E_NICKNAME_RE.source}・絵文字 ${E2E_EMOJI}・約束 E2E 接頭辞がそろった匿名ユーザーのみ)`,
      },
      { dryRun: args.dryRun, log: (l) => console.log(l) },
    );
    return r.ok ? 0 : 1;
  }
  const file = args.stateFile ?? await latestStateFile(stateDir());
  if (!file) {
    console.log(
      `状態ファイルが無い(${stateDir()})。--state <file> か --user <uuid> を指定するか、list で残りを確認する`,
    );
    return 2;
  }
  return await doCleanupFromState(env, file, args.dryRun);
}

async function cmdList(): Promise<number> {
  guardCi();
  const env = readEnv();
  if (!env.mgmt) {
    console.log("SUPABASE_ACCESS_TOKEN が要る(set -a; source .env; set +a)");
    return 2;
  }
  const rows = await listE2eUsers(env.mgmt);
  if (rows.length === 0) {
    console.log(
      "通しテストのものらしいユーザー(目印か E2E-A/B/C のニックネームを持つ匿名ユーザー)は残っていない",
    );
    return 0;
  }
  console.log(`通しテストのものらしいユーザーが ${rows.length} 人残っている:`);
  for (const r of rows) {
    const blocked = r.problems.length === 0
      ? ""
      : `  ← --user では消せない: ${r.problems.join("・")}`;
    console.log(
      `  ${r.id}  ${
        r.nickname || "(ニックネーム空)"
      }  作成 ${r.createdJst} JST  ペア ${r.pairId ?? "(なし)"}${blocked}`,
    );
  }
  console.log(
    "片付けるには: run.sh cleanup --user <uuid> [--user <uuid> ...](「--user では消せない」と出たものは、中身を確かめて手で判断する)",
  );
  return 0;
}

async function main(): Promise<number> {
  let args: Args;
  try {
    args = parseArgs(Deno.args);
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    console.error(USAGE);
    return 2;
  }
  try {
    switch (args.cmd) {
      case "help":
        console.log(USAGE);
        return 0;
      case "check":
        return await cmdCheck();
      case "run":
        return await cmdRun(args);
      case "cleanup":
        return await cmdCleanup(args);
      case "list":
        return await cmdList();
    }
  } catch (e) {
    const msg = redact(e instanceof Error ? e.message : String(e));
    console.error(`ERROR: ${msg}`);
    return e instanceof UsageError ? 2 : 1;
  }
}

if (import.meta.main) {
  Deno.exit(await main());
}
