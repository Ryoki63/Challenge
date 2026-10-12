// cron_check.ts — 本番の cron(close-day / grant-tickets)の健全性チェック(読み取りだけ)
//
// 何をするか(issue #60 項目3。docs/GROWTH.md §7.1 の「余力があれば」を実装したもの):
//   毎朝 00:40 JST の GitHub Actions(.github/workflows/lien-cron-watch.yml)と、手元の /status から使う。
//   Supabase の Management API で本番 DB を **読むだけ**(SELECT)。確かめること:
//   - 直近の予定の回(close-day は JST 00:10、grant-tickets は JST 00:05。数分の猶予つき)に cron が **起動したか**
//     (起動の記録が予定時刻以降にあること。前夜の回が丸ごと抜けたら赤。月初の付与の回が抜けても赤)
//   - 起動が succeeded か、close-day の応答が 200・errors 空・確定した日が昨日か、
//     月初(JST の1日)の grant-tickets が 1 row で応答も 200・errors 空か(それ以外の日は呼ばれていないか)
//   - ジョブの定義が migration 0007 のとおりか(スケジュール・呼び先・鍵・本文 {}・JST の1日の条件)・想定外のジョブが無いか
//   - 鍵の整合(Vault と Function secrets が同じ値か・万能鍵が Vault に残っていないか)
//   - 公開 API から net / cron / vault に届かないこと
//   失敗があれば終了コード 1(= workflow が赤)。
//
// 使い方:
//   set -a; source .env; set +a       # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
//   bash products/lien/scripts/ops/check-cron.sh         # この .ts を deno で実行するラッパ
//   MAX_AGE_HOURS=0 bash .../check-cron.sh               # 必ず赤になる(失敗時の動作確認用)
//
// 環境変数: SUPABASE_ACCESS_TOKEN(必須) / PROJECT_REF(任意) / MAX_AGE_HOURS(任意。既定 26。
//   最後の起動の許容経過時間の上限で、通常は予定の回の検査が先に働く。0 にすると必ず赤になる動作確認用)
//
// 判定の中身は evaluate(純粋関数。cron_check_test.ts がフィクスチャで検査する)。
// 秘密の値は取得も表示もしない: 照合は SHA-256 のダイジェスト同士(Function secrets API が返す値が SHA-256)

export type Level = "ok" | "warn" | "error";

export interface Finding {
  level: Level;
  /** 検査の識別子(例 close-day:response) */
  id: string;
  message: string;
}

export interface CronSnapshot {
  /** DB の now()(ISO 8601) */
  now: string;
  /** 監視対象のプロジェクトの ref(cron の呼び先 URL の照合に使う) */
  projectRef: string;
  /** Management API のプロジェクト状態(ACTIVE_HEALTHY など) */
  projectStatus: string;
  /** PostgREST の公開スキーマ(db_schema をカンマで分けたもの) */
  postgrestSchemas: string[];
  /** pg_graphql 拡張が入っているか(入っていると GraphQL の API が net の表を反映しうる) */
  graphqlEnabled: boolean;
  /** cron.job(登録されているジョブすべて。command は pg_cron が実行する SQL で、秘密は入っていない) */
  jobs: Array<{
    jobname: string;
    schedule: string;
    active: boolean;
    command: string;
  }>;
  /** cron.job_run_details(lien のジョブ分だけ。新しい順)。jobname は結合した cron.job の名前 */
  runs: Array<{
    jobname: string | null;
    status: string;
    returnMessage: string | null;
    startTime: string;
  }>;
  /** net._http_response(新しい順。pg_net の保存期間 = 6時間) */
  responses: Array<{
    id: number;
    statusCode: number | null;
    timedOut: boolean | null;
    errorMsg: string | null;
    created: string;
    content: string | null;
  }>;
  /** net.http_request_queue の行数(処理待ちのリクエスト) */
  queueDepth: number;
  vaultSecretNames: string[];
  /** Vault の lien_cron_secret の SHA-256(16進)。無ければ null */
  vaultCronSecretSha256: string | null;
  /** Function secrets API の name → SHA-256(16進) */
  functionSecretDigests: Record<string, string>;
}

export interface CheckOptions {
  /**
   * 最後の起動の許容経過時間(時間)の上限。起動が抜けたことの検知は予定の回の検査(latestScheduledStartMs)が
   * 担うので、通常はこちらに先に当たらない(正常なら最後の起動は 24 時間と数分以内)。0 にすると必ず赤になる
   * (失敗時の動作確認: workflow が実際に赤になるかを、本番を変えずに確かめる)
   */
  maxAgeHours: number;
  /**
   * true なら、件数・ペア ID・応答の本文を結果に出さない。公開リポジトリの Actions のログ・ジョブサマリは
   * 誰でも読めるので、ペア数などの運用の数字(ユーザー数に近い情報)を載せない。詳細は Function のログ
   * (Supabase)か、手元の check-cron.sh(redact なし)で見る。GitHub Actions 上では自動で true
   */
  redact?: boolean;
}

export const DEFAULT_MAX_AGE_HOURS = 26;

/** pg_net の応答の保存期間(pg_net.ttl)。これより古い応答は消えていて確認できない */
const RESPONSE_TTL_HOURS = 6;
/** 応答が消える少し手前(5.5時間)を過ぎた起動は「応答が無い」を失敗にしない */
const RESPONSE_EXPECTED_WITHIN_HOURS = RESPONSE_TTL_HOURS - 0.5;

/** 監視する cron ジョブの定義(migration 0007 の現行の定義。cron_static_test.ts が照合する) */
export interface JobSpec {
  /** pg_cron のジョブ名 */
  readonly name: string;
  /** 呼び先の Edge Function 名 */
  readonly fn: string;
  /** pg_cron の式(毎日1回)の UTC の時・分。JST = UTC+9 なので 15:10 UTC = 00:10 JST */
  readonly utcHour: number;
  readonly utcMinute: number;
  /** JST の日付が1日の日だけ呼ぶジョブか(それ以外の日は何も呼ばない) */
  readonly onlyFirstOfMonth: boolean;
}

export const JOB_SPECS = {
  /** 毎日 00:10 JST: 前日(JST)の確定 */
  closeDay: {
    name: "lien-close-day",
    fn: "close-day",
    utcHour: 15,
    utcMinute: 10,
    onlyFirstOfMonth: false,
  },
  /** 毎日 00:05 JST に起動し、JST の1日だけ月次付与を呼ぶ */
  grantTickets: {
    name: "lien-grant-tickets",
    fn: "grant-tickets",
    utcHour: 15,
    utcMinute: 5,
    onlyFirstOfMonth: true,
  },
} as const satisfies Record<string, JobSpec>;

const JOBS = {
  closeDay: JOB_SPECS.closeDay.name,
  grantTickets: JOB_SPECS.grantTickets.name,
} as const;

/** now の時点で起動しているはずの、このジョブの直近の予定時刻(UTC の ms) */
function scheduledSlotMs(nowMs: number, spec: JobSpec): number {
  return latestScheduledStartMs(nowMs, spec.utcHour, spec.utcMinute);
}

/** cron.job.command の比較用: 空白をつぶして小文字にする(cron_static_test.ts の normalizeSql と同じ) */
function normalizeCommand(command: string): string {
  return command.replace(/\s+/g, " ").trim().toLowerCase();
}

/** SQL の `where extract(day from (now() at time zone 'Asia/Tokyo')) = 1`(JST の1日だけ通す条件)。正規化後の文面 */
const JST_FIRST_DAY_GUARD =
  "where extract(day from (now() at time zone 'asia/tokyo')) = 1";

/**
 * 本番の cron.job の定義が、migration 0007 の定義(JOB_SPECS)とずれていないか。ずれの一覧を返す(空 = 一致)。
 * ジョブの有無と active だけでは、誰かが手で書き換えた(スケジュール・呼び先・鍵・本文)ことに気づけない。
 * とくに本文: cron は `{}`(= close-day は昨日・通知あり、grant-tickets は今月)で呼ぶ。`{"notify":false}` や
 * 固定の日付が入ると、通知が黙って止まる・毎晩同じ日を確定する、のに起動は succeeded のままになる
 */
export function jobDrift(
  job: { schedule: string; command: string },
  spec: JobSpec,
  projectRef: string,
): string[] {
  const problems: string[] = [];
  const schedule = `${spec.utcMinute} ${spec.utcHour} * * *`;
  if (job.schedule !== schedule) {
    problems.push(`スケジュールが ${job.schedule}(想定 ${schedule} UTC)`);
  }
  const cmd = normalizeCommand(job.command ?? "");
  const url = `https://${projectRef}.supabase.co/functions/v1/${spec.fn}`;
  if (!cmd.includes(`url := '${url}'`.toLowerCase())) {
    problems.push(`呼び先が ${url} ではない`);
  }
  if (
    !cmd.includes(
      `from vault.decrypted_secrets where name = '${CRON_SECRET_VAULT_NAME}'`,
    ) || cmd.includes(MASTER_KEY_VAULT_NAME)
  ) {
    problems.push(
      `Authorization が Vault の ${CRON_SECRET_VAULT_NAME} ではない(万能鍵を参照していないか)`,
    );
  }
  if (!cmd.includes("body := '{}'::jsonb")) {
    problems.push(
      "本文が {} ではない(cron は {} で呼ぶ。notify や日付を固定していないか)",
    );
  }
  if (spec.onlyFirstOfMonth) {
    if (!cmd.endsWith(`${JST_FIRST_DAY_GUARD};`)) {
      problems.push("「JST の日付が1日の日だけ呼ぶ」条件が無い・違う");
    }
  } else if (cmd.includes("extract(")) {
    problems.push("日付の条件が付いている(毎日呼ぶはず)");
  }
  return problems;
}

const CRON_SECRET_VAULT_NAME = "lien_cron_secret";
const CRON_SECRET_ENV_NAME = "LIEN_CRON_SECRET";
const MASTER_KEY_VAULT_NAME = "lien_service_role_key";
/** 公開 API(PostgREST)に出してはいけないスキーマ */
const FORBIDDEN_EXPOSED_SCHEMAS = ["net", "cron", "vault"];

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
const JST_OFFSET_MS = 9 * HOUR_MS;

/**
 * 予定の起動時刻からこの時間(分)が過ぎるまでは、その回の起動が無くても「まだ」として扱う。
 * pg_cron は予定の分の頭に起動するので数秒で足りるが、起動の直後に手動で監視を走らせた場合に
 * 誤って赤にしないための余裕(定時の 00:40 JST は予定の 30 分後なので影響しない)
 */
const SCHEDULE_GRACE_MINUTES = 5;

// ---- 小さなヘルパ ----

/**
 * 毎日 UTC の時:分に起動するジョブの、now の時点で「もう起動しているはずの」直近の予定時刻(UTC の ms)。
 * 予定から graceMinutes が経つまでは、その回を数えない(= 1つ前の回で判定する)。
 * 監視はこの時刻以降の起動を要求する。「最後の起動が 26 時間以内」のような経過時間で見ると、
 * 前夜の回が丸ごと抜けても(最後の起動 = 前々夜 = 24.5 時間前)通ってしまうため、予定の回で見る
 */
export function latestScheduledStartMs(
  nowMs: number,
  utcHour: number,
  utcMinute: number,
  graceMinutes: number = SCHEDULE_GRACE_MINUTES,
): number {
  const limit = nowMs - graceMinutes * 60_000;
  const utcMidnight = Math.floor(limit / DAY_MS) * DAY_MS;
  const slot = utcMidnight + (utcHour * 60 + utcMinute) * 60_000;
  return slot <= limit ? slot : slot - DAY_MS;
}

function toMs(iso: string): number {
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) throw new Error(`日時を読めません: ${iso}`);
  return ms;
}

/** JST の "YYYY-MM-DD" */
export function jstDate(ms: number): string {
  return new Date(ms + JST_OFFSET_MS).toISOString().slice(0, 10);
}

/** JST の "YYYY-MM-DD HH:MM" */
export function jstDateTime(ms: number): string {
  return new Date(ms + JST_OFFSET_MS).toISOString().slice(0, 16).replace(
    "T",
    " ",
  );
}

function jstDayOfMonth(ms: number): number {
  return new Date(ms + JST_OFFSET_MS).getUTCDate();
}

function addDays(dateLocal: string, days: number): string {
  const [y, m, d] = dateLocal.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

function ago(nowMs: number, thenMs: number): string {
  const minutes = Math.round((nowMs - thenMs) / 60000);
  if (minutes < 90) return `${minutes} 分前`;
  return `${(minutes / 60).toFixed(1)} 時間前`;
}

function ok(id: string, message: string): Finding {
  return { level: "ok", id, message };
}
function warn(id: string, message: string): Finding {
  return { level: "warn", id, message };
}
function error(id: string, message: string): Finding {
  return { level: "error", id, message };
}

interface ParsedResponse {
  statusCode: number | null;
  timedOut: boolean | null;
  errorMsg: string | null;
  created: number;
  content: string | null;
  json: Record<string, unknown> | null;
  /** 応答の形から見た送り主 */
  shape: "close-day" | "grant-tickets" | "other";
}

function parseResponse(r: CronSnapshot["responses"][number]): ParsedResponse {
  let json: Record<string, unknown> | null = null;
  if (r.content) {
    try {
      const v = JSON.parse(r.content);
      if (typeof v === "object" && v !== null && !Array.isArray(v)) {
        json = v as Record<string, unknown>;
      }
    } catch {
      // JSON でない応答(HTML のエラーページなど)は json = null
    }
  }
  let shape: ParsedResponse["shape"] = "other";
  if (json && "recordedBoth" in json && "dateLocal" in json) {
    shape = "close-day";
  } else if (json && "alreadyGranted" in json && "granted" in json) {
    shape = "grant-tickets";
  }
  return {
    statusCode: r.statusCode,
    timedOut: r.timedOut,
    errorMsg: r.errorMsg,
    created: toMs(r.created),
    content: r.content,
    json,
    shape,
  };
}

/** 応答の本文を短く(ログ用。秘密は入っていない: 件数と日付だけ)。redact なら本文は出さない */
function brief(content: string | null, redact: boolean): string {
  if (!content) return "(本文なし)";
  if (redact) return "(本文は公開ログのため省略)";
  return content.length > 200 ? content.slice(0, 200) + "…" : content;
}

/**
 * 起動(startMs)に対応する pg_net の応答を探す。
 * pg_cron の起動は net.http_post を呼ぶだけで、応答は別の表(net._http_response)に非同期で入る。
 * 起動の直前〜15分後に作られた応答のうち、形(close-day / grant-tickets)が合うものを優先し、
 * 形のない応答(401 など)は起動時刻にいちばん近いものを使う
 */
function findResponse(
  responses: ParsedResponse[],
  startMs: number,
  shape: "close-day" | "grant-tickets",
): ParsedResponse | null {
  const inWindow = responses.filter((r) =>
    r.created >= startMs - 60_000 && r.created <= startMs + 15 * 60_000
  );
  const shaped = inWindow.find((r) => r.shape === shape);
  if (shaped) return shaped;
  const others = inWindow.filter((r) => r.shape === "other");
  others.sort((a, b) =>
    Math.abs(a.created - startMs) - Math.abs(b.created - startMs)
  );
  return others[0] ?? null;
}

/** Function の応答(close-day / grant-tickets 共通)が 200・タイムアウトなし・errors 空か */
function checkResponseBody(
  id: string,
  label: string,
  res: ParsedResponse,
  redact: boolean,
): Finding | null {
  if (res.timedOut || res.errorMsg) {
    return error(
      id,
      `${label}: HTTP が失敗(timed_out=${res.timedOut}, error=${
        res.errorMsg ?? "なし"
      })`,
    );
  }
  if (res.statusCode !== 200) {
    return error(
      id,
      `${label}: HTTP ${res.statusCode}(${brief(res.content, redact)})`,
    );
  }
  if (!res.json) {
    return error(
      id,
      `${label}: 本文が JSON ではない(${brief(res.content, redact)})`,
    );
  }
  const errors = res.json.errors;
  if (!Array.isArray(errors)) {
    return error(
      id,
      `${label}: 本文に errors 配列がない(${brief(res.content, redact)})`,
    );
  }
  if (errors.length > 0) {
    return error(
      id,
      redact
        ? `${label}: 一部のペアの処理が失敗した(errors が ${errors.length} 件。詳細は公開ログのため省略。Function のログで確認する)`
        : `${label}: 一部のペアの処理が失敗した errors=${
          JSON.stringify(errors).slice(0, 300)
        }(Function のログで確認する)`,
    );
  }
  return null;
}

// ---- 判定本体(純粋関数) ----

/** 予定の回の起動が記録に無いときの、close-day / grant-tickets 共通の説明 */
function missedSlotDetail(
  slotMs: number,
  lastStartMs: number,
  nowMs: number,
): string {
  return `予定 ${jstDateTime(slotMs)} JST 以降の起動記録が無く、最後の起動は ${
    jstDateTime(lastStartMs)
  } JST(${ago(nowMs, lastStartMs)})`;
}

function checkCloseDay(
  findings: Finding[],
  s: CronSnapshot,
  o: CheckOptions,
  nowMs: number,
  responses: ParsedResponse[],
  redact: boolean,
): void {
  const closeRun = s.runs.find((r) => r.jobname === JOBS.closeDay);
  if (!closeRun) {
    findings.push(
      error(
        "close-day:run",
        "lien-close-day の起動記録(cron.job_run_details)がない",
      ),
    );
    return;
  }
  const startMs = toMs(closeRun.startTime);
  const ageH = (nowMs - startMs) / HOUR_MS;

  // 前夜の回(直近の予定時刻)の起動があること。「最後の起動が N 時間以内」では、前夜の回が丸ごと
  // 抜けても(最後の起動 = 前々夜 = 24.5 時間前)通ってしまうので、予定の回で見る
  const slotMs = scheduledSlotMs(nowMs, JOB_SPECS.closeDay);
  if (startMs < slotMs) {
    findings.push(
      error(
        "close-day:run",
        `前夜の起動が無い: ${missedSlotDetail(slotMs, startMs, nowMs)}(${
          addDays(jstDate(slotMs), -1)
        } の確定が走っていない。cron が動かなかった。OPS.md §2 で切り分け、§4 で取りこぼしを再実行する)`,
      ),
    );
    return; // 起動していない回の応答は探さない(古い起動の応答を黄にして紛らわしくしない)
  }

  if (closeRun.status !== "succeeded") {
    findings.push(
      error(
        "close-day:run",
        `最後の起動 ${jstDateTime(startMs)} JST が ${closeRun.status}(${
          closeRun.returnMessage ?? ""
        })`,
      ),
    );
  } else if (ageH > o.maxAgeHours) {
    // 通常は上の予定の回の検査が先に働く。ここは許容時間を絞って必ず赤にする動作確認用(MAX_AGE_HOURS=0)
    findings.push(
      error(
        "close-day:run",
        `最後の起動が ${jstDateTime(startMs)} JST(${
          ago(nowMs, startMs)
        })で、許容の ${o.maxAgeHours} 時間を超えている(毎日 00:10 JST に動くはず)`,
      ),
    );
  } else {
    findings.push(
      ok(
        "close-day:run",
        `前夜の起動 ${jstDateTime(startMs)} JST(${
          ago(nowMs, startMs)
        })は succeeded`,
      ),
    );
  }

  const res = findResponse(responses, startMs, "close-day");
  if (!res) {
    if (ageH > RESPONSE_EXPECTED_WITHIN_HOURS) {
      findings.push(
        warn(
          "close-day:response",
          `HTTP 応答は pg_net の保存期間(${RESPONSE_TTL_HOURS} 時間)を過ぎて消えている(起動 ${
            ago(nowMs, startMs)
          })。応答の中身は確認できない`,
        ),
      );
    } else {
      findings.push(
        error(
          "close-day:response",
          `起動 ${
            jstDateTime(startMs)
          } JST に対応する HTTP 応答が net._http_response にない(pg_net が送れていない疑い)`,
        ),
      );
    }
    return;
  }
  const bad = checkResponseBody("close-day:response", "close-day", res, redact);
  if (bad) {
    findings.push(bad);
    return;
  }
  // 確定した日は「起動した JST の日付の前日」のはず
  const expected = addDays(jstDate(startMs), -1);
  const actual = String(res.json!.dateLocal);
  if (actual !== expected) {
    findings.push(
      error(
        "close-day:response",
        `確定した日が ${actual}(期待 ${expected})`,
      ),
    );
    return;
  }
  const j = res.json!;
  findings.push(
    ok(
      "close-day:response",
      redact
        ? `HTTP 200・errors 空。${actual} を確定(件数は公開ログのため省略)`
        : `HTTP 200・errors 空。${actual} を確定(ペア ${j.pairs}・両者 ${j.recordedBoth}・チケット ${j.recordedTicket}・リセット ${j.reset}・スキップ ${j.skipped})`,
    ),
  );
}

function checkGrantTickets(
  findings: Finding[],
  s: CronSnapshot,
  o: CheckOptions,
  nowMs: number,
  responses: ParsedResponse[],
  redact: boolean,
): void {
  const grantRun = s.runs.find((r) => r.jobname === JOBS.grantTickets);
  if (!grantRun) {
    findings.push(
      error(
        "grant-tickets:run",
        "lien-grant-tickets の起動記録(cron.job_run_details)がない",
      ),
    );
    return;
  }
  const startMs = toMs(grantRun.startTime);
  const ageH = (nowMs - startMs) / HOUR_MS;

  // 前夜の回(直近の予定時刻)の起動があること。とくに JST の1日の回は、抜けると月次付与が黙って
  // 走らずにその月はチケットで守れなくなる。最後の起動が前日の「0 rows」だと、1日でない日の
  // 正常な起動に見えて通ってしまうので、予定の回で見る
  const slotMs = scheduledSlotMs(nowMs, JOB_SPECS.grantTickets);
  if (startMs < slotMs) {
    findings.push(
      error(
        "grant-tickets:run",
        jstDayOfMonth(slotMs) === 1
          ? `JST の1日(${jstDate(slotMs)})の月次付与が起動していない: ${
            missedSlotDetail(slotMs, startMs, nowMs)
          }(付与が抜けた。その月はチケットで守れない。OPS.md §4「grant-tickets の取りこぼし」で再実行する)`
          : `前夜の起動が無い: ${
            missedSlotDetail(slotMs, startMs, nowMs)
          }(1日ではないので付与は呼ばない回だが、cron が動いていない。OPS.md §2 で切り分ける)`,
      ),
    );
    return;
  }

  const isFirst = jstDayOfMonth(startMs) === 1;
  const rows = (grantRun.returnMessage ?? "").trim();
  if (grantRun.status !== "succeeded") {
    findings.push(
      error(
        "grant-tickets:run",
        `最後の起動 ${jstDateTime(startMs)} JST が ${grantRun.status}(${
          grantRun.returnMessage ?? ""
        })`,
      ),
    );
  } else if (ageH > o.maxAgeHours) {
    findings.push(
      error(
        "grant-tickets:run",
        `最後の起動が ${jstDateTime(startMs)} JST(${
          ago(nowMs, startMs)
        })で、許容の ${o.maxAgeHours} 時間を超えている(毎日 00:05 JST に起動するはず)`,
      ),
    );
  } else if (isFirst && rows !== "1 row") {
    findings.push(
      error(
        "grant-tickets:run",
        `毎月1日(${jstDate(startMs)})の起動なのに ${
          rows || "結果なし"
        }(1 row = 呼んだ、のはず。付与が走っていない)`,
      ),
    );
  } else if (!isFirst && rows !== "0 rows") {
    findings.push(
      error(
        "grant-tickets:run",
        `1日でない日(${
          jstDate(startMs)
        })の起動で ${rows}(0 rows = 呼ばない、のはず。月の途中に付与が呼ばれた)`,
      ),
    );
  } else {
    findings.push(
      ok(
        "grant-tickets:run",
        `前夜の起動 ${jstDateTime(startMs)} JST(${
          ago(nowMs, startMs)
        })は succeeded・${rows}(${
          isFirst ? "月初なので呼んだ" : "1日ではないので呼ばない"
        })`,
      ),
    );
  }

  // 月初に呼んだなら、その応答も確かめる
  if (!(isFirst && rows === "1 row" && grantRun.status === "succeeded")) return;
  const res = findResponse(responses, startMs, "grant-tickets");
  if (!res) {
    if (ageH > RESPONSE_EXPECTED_WITHIN_HOURS) {
      findings.push(
        warn(
          "grant-tickets:response",
          `月初の付与の HTTP 応答は保存期間を過ぎて消えている(起動 ${
            ago(nowMs, startMs)
          })`,
        ),
      );
    } else {
      findings.push(
        error(
          "grant-tickets:response",
          `月初の起動 ${jstDateTime(startMs)} JST に対応する HTTP 応答がない`,
        ),
      );
    }
    return;
  }
  const bad = checkResponseBody(
    "grant-tickets:response",
    "grant-tickets",
    res,
    redact,
  );
  findings.push(
    bad ??
      ok(
        "grant-tickets:response",
        redact
          ? "月初の付与は HTTP 200・errors 空(件数は公開ログのため省略)"
          : `月初の付与は HTTP 200・errors 空(付与 ${
            res.json!.granted
          }・処理済み ${res.json!.alreadyGranted}・上限 ${
            res.json!.unchanged
          })`,
      ),
  );
}

export function evaluate(s: CronSnapshot, o: CheckOptions): Finding[] {
  const findings: Finding[] = [];
  const redact = o.redact === true;
  const nowMs = toMs(s.now);
  const responses = s.responses.map(parseResponse);

  // 1. プロジェクトの状態(無料枠の自動停止 = D5)
  if (s.projectStatus === "ACTIVE_HEALTHY") {
    findings.push(ok("project", `プロジェクトは ACTIVE_HEALTHY`));
  } else {
    findings.push(
      error(
        "project",
        `プロジェクトの状態が ${s.projectStatus}(自動停止なら Dashboard で復元し、OPS.md §4 で止まっていた期間を埋める)`,
      ),
    );
  }

  // 2. ジョブの登録・有効・定義(migration 0007 のとおりか)と、想定外のジョブが無いこと
  for (const spec of Object.values(JOB_SPECS)) {
    const job = s.jobs.find((j) => j.jobname === spec.name);
    if (!job) {
      findings.push(
        error(
          `job:${spec.name}`,
          `ジョブ ${spec.name} が登録されていない(migration 0007 の cron.schedule を再実行する)`,
        ),
      );
    } else if (!job.active) {
      findings.push(
        error(`job:${spec.name}`, `ジョブ ${spec.name} が無効(active = false)`),
      );
    } else {
      const drift = jobDrift(job, spec, s.projectRef);
      if (drift.length > 0) {
        findings.push(
          error(
            `job:${spec.name}`,
            `ジョブ ${spec.name} の定義が migration 0007 と違う: ${
              drift.join(" / ")
            }(0007 の cron.schedule を再実行して戻す。OPS.md §3)`,
          ),
        );
      } else {
        findings.push(
          ok(
            `job:${spec.name}`,
            `ジョブ ${spec.name} は登録済みで有効(${job.schedule} UTC)・定義は migration 0007 のとおり`,
          ),
        );
      }
    }
  }
  const knownJobNames: string[] = Object.values(JOBS);
  const unexpectedJobs = s.jobs.filter((j) =>
    !knownJobNames.includes(j.jobname)
  );
  if (unexpectedJobs.length > 0) {
    findings.push(
      error(
        "job:unexpected",
        `想定外のジョブが登録されている: ${
          unexpectedJobs.map((j) => j.jobname ?? "(名前なし)").join(", ")
        }(スモークなどの一時ジョブの消し忘れなら select cron.unschedule(...) で消す。正式に増やしたなら cron_check.ts の JOB_SPECS と cron_static_test.ts に足す)`,
      ),
    );
  } else {
    findings.push(
      ok(
        "job:unexpected",
        `想定外のジョブはない(${knownJobNames.join(" / ")} の2つだけ)`,
      ),
    );
  }

  // 3. close-day: 前夜(直近の予定の回)の起動と、その HTTP 応答
  checkCloseDay(findings, s, o, nowMs, responses, redact);

  // 4. grant-tickets: 毎日起動するが、JST の1日だけ呼ぶ(それ以外の日は 0 rows)
  checkGrantTickets(findings, s, o, nowMs, responses, redact);

  // 5. 1日でない日に、cron 経由で grant-tickets が呼ばれていないか(応答の形で見る。保存期間内の全部)
  const strayGrant = responses.filter((r) =>
    r.shape === "grant-tickets" && jstDayOfMonth(r.created) !== 1
  );
  if (strayGrant.length > 0) {
    const days = strayGrant.map((r) => jstDate(r.created)).join(", ");
    findings.push(
      error(
        "grant-tickets:stray",
        `JST の1日でない日(${days})に grant-tickets の応答がある(月の途中に cron が呼んだ、または pg_net で手動実行した)`,
      ),
    );
  } else {
    findings.push(
      ok(
        "grant-tickets:stray",
        "月の途中に grant-tickets が呼ばれた形跡はない",
      ),
    );
  }

  // 6. pg_net のキュー(処理待ちが残っていれば、ワーカーが止まっている)
  if (s.queueDepth > 0) {
    findings.push(
      error(
        "net:queue",
        `net.http_request_queue に ${s.queueDepth} 件が残っている(pg_net のワーカーが止まっている疑い)`,
      ),
    );
  } else {
    findings.push(ok("net:queue", "pg_net のキューは空"));
  }

  // 7. 鍵: Vault に cron 専用の秘密があり、万能鍵は無い。Function secrets と同じ値
  const hasCronSecret = s.vaultSecretNames.includes(CRON_SECRET_VAULT_NAME);
  if (!hasCronSecret) {
    findings.push(
      error(
        "vault:cron-secret",
        `Vault に ${CRON_SECRET_VAULT_NAME} がない(cron が 401 になる。OPS.md §6)`,
      ),
    );
  } else {
    findings.push(
      ok("vault:cron-secret", `Vault に ${CRON_SECRET_VAULT_NAME} がある`),
    );
  }
  if (s.vaultSecretNames.includes(MASTER_KEY_VAULT_NAME)) {
    findings.push(
      error(
        "vault:master-key",
        `Vault に万能鍵 ${MASTER_KEY_VAULT_NAME} が残っている(cron は使わない。OPS.md §6 で削除する)`,
      ),
    );
  } else {
    findings.push(
      ok("vault:master-key", "Vault に万能鍵(service role key)はない"),
    );
  }
  if (hasCronSecret) {
    const fnDigest = s.functionSecretDigests[CRON_SECRET_ENV_NAME];
    if (!fnDigest) {
      findings.push(
        error(
          "secrets:sync",
          `Function secrets に ${CRON_SECRET_ENV_NAME} がない(close-day / grant-tickets が全リクエストを 401 にする)`,
        ),
      );
    } else if (
      !s.vaultCronSecretSha256 || fnDigest !== s.vaultCronSecretSha256
    ) {
      findings.push(
        error(
          "secrets:sync",
          `Vault の ${CRON_SECRET_VAULT_NAME} と Function secrets の ${CRON_SECRET_ENV_NAME} の値が違う(cron が 401 になる。OPS.md §6 で合わせる)`,
        ),
      );
    } else {
      findings.push(
        ok(
          "secrets:sync",
          `Vault の ${CRON_SECRET_VAULT_NAME} と Function secrets の ${CRON_SECRET_ENV_NAME} は同じ値(SHA-256 の照合)`,
        ),
      );
    }
  }

  // 8. 公開 API から net / cron / vault に届かない(net の権限を postgres からは絞れないことの代わりの守り)。
  //    REST(PostgREST)の公開スキーマと、GraphQL(pg_graphql。入れると、PUBLIC に SELECT が付いた
  //    net の表を反映しうる)の両方を見る
  const exposed = s.postgrestSchemas.filter((x) =>
    FORBIDDEN_EXPOSED_SCHEMAS.includes(x)
  );
  if (exposed.length > 0) {
    findings.push(
      error(
        "exposure",
        `PostgREST の公開スキーマに ${
          exposed.join(", ")
        } が含まれている(anon / authenticated から net の表・関数に届く。公開スキーマから外す)`,
      ),
    );
  } else if (s.graphqlEnabled) {
    findings.push(
      error(
        "exposure",
        "pg_graphql が有効(PUBLIC に SELECT が付いた net の表が GraphQL の API に出る恐れがある。無効にするか、net が出ないことを確かめてから許可する。OPS.md §9)",
      ),
    );
  } else {
    findings.push(
      ok(
        "exposure",
        `PostgREST の公開スキーマは ${
          s.postgrestSchemas.join(", ")
        }(net / cron / vault は含まれない)・pg_graphql は無効`,
      ),
    );
  }

  return findings;
}

export function hasError(findings: Finding[]): boolean {
  return findings.some((f) => f.level === "error");
}

// ---- 取得(Management API。読み取りだけ) ----

const API = "https://api.supabase.com";
const UA = "lien-agent/1.0"; // Cloudflare 対策(付けないと 403 になることがある)

async function api(
  token: string,
  method: "GET" | "POST",
  path: string,
  body?: unknown,
): Promise<unknown> {
  const res = await fetch(API + path, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      "user-agent": UA,
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    // 本文は Management API のエラー文(秘密は入らない)。長いので切る
    throw new Error(
      `Management API ${method} ${
        path.replace(/\/projects\/[a-z0-9]+/, "/projects/<ref>")
      } が HTTP ${res.status}: ${text.slice(0, 200)}`,
    );
  }
  return text ? JSON.parse(text) : null;
}

/** 起動記録を読むジョブ名の SQL リスト('a', 'b')。他のジョブの起動で 30 行が埋まって lien の起動が押し出されないよう絞る */
const RUN_JOB_NAMES_SQL = Object.values(JOBS).map((n) => `'${n}'`).join(", ");

/** 本番 DB を読む SQL(SELECT だけ)。結果は1行1列の JSON */
export const SNAPSHOT_SQL = `
select jsonb_build_object(
  'now', now(),
  'jobs', (
    select coalesce(jsonb_agg(jsonb_build_object('jobname', jobname, 'schedule', schedule, 'active', active, 'command', command) order by jobname), '[]'::jsonb)
    from cron.job
  ),
  'runs', (
    select coalesce(jsonb_agg(r order by r."startTime" desc), '[]'::jsonb) from (
      select j.jobname as "jobname", d.status as "status", d.return_message as "returnMessage", d.start_time as "startTime"
      from cron.job_run_details d join cron.job j using (jobid)
      where j.jobname in (${RUN_JOB_NAMES_SQL})
      order by d.start_time desc limit 30
    ) r
  ),
  'responses', (
    select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) from (
      select id, status_code as "statusCode", timed_out as "timedOut", error_msg as "errorMsg", created, left(content, 2000) as content
      from net._http_response order by id desc limit 60
    ) x
  ),
  'queueDepth', (select count(*) from net.http_request_queue),
  'vaultSecretNames', (select coalesce(jsonb_agg(name order by name), '[]'::jsonb) from vault.secrets),
  'graphqlEnabled', exists (select 1 from pg_extension where extname = 'pg_graphql'),
  'vaultCronSecretSha256', (
    select encode(extensions.digest(decrypted_secret, 'sha256'), 'hex')
    from vault.decrypted_secrets where name = '${CRON_SECRET_VAULT_NAME}'
  )
) as snapshot
`;

export async function collect(
  token: string,
  ref: string,
): Promise<CronSnapshot> {
  const project = await api(token, "GET", `/v1/projects/${ref}`) as {
    status?: string;
  };
  const postgrest = await api(
    token,
    "GET",
    `/v1/projects/${ref}/postgrest`,
  ) as { db_schema?: string };
  const secrets = await api(
    token,
    "GET",
    `/v1/projects/${ref}/secrets`,
  ) as Array<{ name: string; value: string }>;
  const rows = await api(token, "POST", `/v1/projects/${ref}/database/query`, {
    query: SNAPSHOT_SQL,
  }) as Array<{
    snapshot: Omit<
      CronSnapshot,
      | "projectRef"
      | "projectStatus"
      | "postgrestSchemas"
      | "functionSecretDigests"
    >;
  }>;
  const snap = rows?.[0]?.snapshot;
  if (!snap) throw new Error("database/query の結果が空");
  const functionSecretDigests: Record<string, string> = {};
  for (const s of secrets ?? []) functionSecretDigests[s.name] = s.value;
  return {
    ...snap,
    projectRef: ref,
    projectStatus: project?.status ?? "UNKNOWN",
    postgrestSchemas: (postgrest?.db_schema ?? "").split(",").map((x) =>
      x.trim()
    ).filter(Boolean),
    functionSecretDigests,
  };
}

// ---- 表示(GitHub Actions では注釈とジョブサマリにも出す) ----

export function render(findings: Finding[]): string {
  const mark: Record<Level, string> = {
    ok: "OK  ",
    warn: "WARN",
    error: "FAIL",
  };
  return findings.map((f) => `[${mark[f.level]}] ${f.id}: ${f.message}`).join(
    "\n",
  );
}

function renderMarkdown(findings: Finding[]): string {
  const mark: Record<Level, string> = {
    ok: "OK",
    warn: "WARN",
    error: "**FAIL**",
  };
  const rows = findings.map((f) =>
    `| ${mark[f.level]} | \`${f.id}\` | ${f.message.replace(/\|/g, "\\|")} |`
  );
  return [
    "## lien-cron-watch",
    "",
    "| 結果 | 検査 | 内容 |",
    "|---|---|---|",
    ...rows,
    "",
  ].join("\n");
}

async function main(): Promise<number> {
  const token = Deno.env.get("SUPABASE_ACCESS_TOKEN");
  if (!token) {
    console.error(
      "ERROR: SUPABASE_ACCESS_TOKEN を設定してください(set -a; source .env; set +a)",
    );
    return 2;
  }
  const ref = Deno.env.get("PROJECT_REF") || "lniheehfbtpfhglinfjm";
  const rawMax = Deno.env.get("MAX_AGE_HOURS");
  const maxAgeHours = rawMax ? Number(rawMax) : DEFAULT_MAX_AGE_HOURS;
  if (!Number.isFinite(maxAgeHours) || maxAgeHours < 0) {
    console.error(
      `ERROR: MAX_AGE_HOURS は 0 以上の数にしてください: ${rawMax}`,
    );
    return 2;
  }

  let findings: Finding[];
  try {
    const snapshot = await collect(token, ref);
    // 公開リポジトリの Actions のログは誰でも読めるので、Actions 上では件数などを出さない
    findings = evaluate(snapshot, {
      maxAgeHours,
      redact: Deno.env.get("GITHUB_ACTIONS") === "true",
    });
  } catch (e) {
    // 取得できないこと自体が異常(自動停止・API 障害・トークン失効)。赤にする
    findings = [
      error(
        "collect",
        `本番の状態を取得できなかった: ${
          e instanceof Error ? e.message : String(e)
        }`,
      ),
    ];
  }

  console.log(render(findings));

  if (Deno.env.get("GITHUB_ACTIONS") === "true") {
    for (const f of findings) {
      if (f.level === "error") {
        console.log(`::error title=lien-cron-watch ${f.id}::${f.message}`);
      }
      if (f.level === "warn") {
        console.log(`::warning title=lien-cron-watch ${f.id}::${f.message}`);
      }
    }
    const summary = Deno.env.get("GITHUB_STEP_SUMMARY");
    if (summary) {
      await Deno.writeTextFile(summary, renderMarkdown(findings), {
        append: true,
      });
    }
  }
  return hasError(findings) ? 1 : 0;
}

if (import.meta.main) {
  Deno.exit(await main());
}
