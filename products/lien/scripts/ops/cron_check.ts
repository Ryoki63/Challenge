// cron_check.ts — 本番の cron(close-day / grant-tickets)の健全性チェック(読み取りだけ)
//
// 何をするか(issue #60 項目3。docs/GROWTH.md §7.1 の「余力があれば」を実装したもの):
//   毎朝 00:40 JST の GitHub Actions(.github/workflows/lien-cron-watch.yml)と、手元の /status から使う。
//   Supabase の Management API で本番 DB を **読むだけ**(SELECT)。前夜の close-day が動いて 200・errors 空だったか、
//   cron.job_run_details が succeeded か、月初の grant-tickets が呼ばれたか(それ以外の日は呼ばれていないか)、
//   鍵の整合(Vault と Function secrets が同じ値か・万能鍵が Vault に残っていないか)、
//   公開 API から net / cron / vault に届かないこと、などを確かめる。失敗があれば終了コード 1(= workflow が赤)。
//
// 使い方:
//   set -a; source .env; set +a       # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
//   bash products/lien/scripts/ops/check-cron.sh         # この .ts を deno で実行するラッパ
//   MAX_AGE_HOURS=0 bash .../check-cron.sh               # 必ず赤になる(失敗時の動作確認用)
//
// 環境変数: SUPABASE_ACCESS_TOKEN(必須) / PROJECT_REF(任意) / MAX_AGE_HOURS(任意。既定 26)
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
  /** Management API のプロジェクト状態(ACTIVE_HEALTHY など) */
  projectStatus: string;
  /** PostgREST の公開スキーマ(db_schema をカンマで分けたもの) */
  postgrestSchemas: string[];
  jobs: Array<{ jobname: string; schedule: string; active: boolean }>;
  /** cron.job_run_details(新しい順)。jobname は結合した cron.job の名前(削除済みのジョブは null) */
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
  /** 最後の起動の許容経過時間(時間)。0 にすると必ず赤になる(失敗時の動作確認) */
  maxAgeHours: number;
}

export const DEFAULT_MAX_AGE_HOURS = 26;

/** pg_net の応答の保存期間(pg_net.ttl)。これより古い応答は消えていて確認できない */
const RESPONSE_TTL_HOURS = 6;
/** 応答が消える少し手前(5.5時間)を過ぎた起動は「応答が無い」を失敗にしない */
const RESPONSE_EXPECTED_WITHIN_HOURS = RESPONSE_TTL_HOURS - 0.5;

const JOBS = {
  closeDay: "lien-close-day",
  grantTickets: "lien-grant-tickets",
} as const;

const CRON_SECRET_VAULT_NAME = "lien_cron_secret";
const CRON_SECRET_ENV_NAME = "LIEN_CRON_SECRET";
const MASTER_KEY_VAULT_NAME = "lien_service_role_key";
/** 公開 API(PostgREST)に出してはいけないスキーマ */
const FORBIDDEN_EXPOSED_SCHEMAS = ["net", "cron", "vault"];

const HOUR_MS = 60 * 60 * 1000;
const JST_OFFSET_MS = 9 * HOUR_MS;

// ---- 小さなヘルパ ----

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

/** 応答の本文を短く(ログ用。秘密は入っていない: 件数と日付だけ) */
function brief(content: string | null): string {
  if (!content) return "(本文なし)";
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
    return error(id, `${label}: HTTP ${res.statusCode}(${brief(res.content)})`);
  }
  if (!res.json) {
    return error(id, `${label}: 本文が JSON ではない(${brief(res.content)})`);
  }
  const errors = res.json.errors;
  if (!Array.isArray(errors)) {
    return error(
      id,
      `${label}: 本文に errors 配列がない(${brief(res.content)})`,
    );
  }
  if (errors.length > 0) {
    return error(
      id,
      `${label}: 一部のペアの処理が失敗した errors=${
        JSON.stringify(errors).slice(0, 300)
      }(Function のログで確認する)`,
    );
  }
  return null;
}

// ---- 判定本体(純粋関数) ----

export function evaluate(s: CronSnapshot, o: CheckOptions): Finding[] {
  const findings: Finding[] = [];
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

  // 2. ジョブの登録と有効
  for (const name of Object.values(JOBS)) {
    const job = s.jobs.find((j) => j.jobname === name);
    if (!job) {
      findings.push(
        error(
          `job:${name}`,
          `ジョブ ${name} が登録されていない(migration 0007 の cron.schedule を再実行する)`,
        ),
      );
    } else if (!job.active) {
      findings.push(
        error(`job:${name}`, `ジョブ ${name} が無効(active = false)`),
      );
    } else {
      findings.push(
        ok(
          `job:${name}`,
          `ジョブ ${name} は登録済みで有効(${job.schedule} UTC)`,
        ),
      );
    }
  }

  // 3. close-day: 最後の起動と、その HTTP 応答
  const closeRuns = s.runs.filter((r) => r.jobname === JOBS.closeDay);
  const closeRun = closeRuns[0];
  if (!closeRun) {
    findings.push(
      error(
        "close-day:run",
        "lien-close-day の起動記録(cron.job_run_details)がない",
      ),
    );
  } else {
    const startMs = toMs(closeRun.startTime);
    const ageH = (nowMs - startMs) / HOUR_MS;
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
          `最後の起動 ${jstDateTime(startMs)} JST(${
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
    } else {
      const bad = checkResponseBody("close-day:response", "close-day", res);
      if (bad) {
        findings.push(bad);
      } else {
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
        } else {
          const j = res.json!;
          findings.push(
            ok(
              "close-day:response",
              `HTTP 200・errors 空。${actual} を確定(ペア ${j.pairs}・両者 ${j.recordedBoth}・チケット ${j.recordedTicket}・リセット ${j.reset}・スキップ ${j.skipped})`,
            ),
          );
        }
      }
    }
  }

  // 4. grant-tickets: 毎日起動するが、JST の1日だけ呼ぶ(それ以外の日は 0 rows)
  const grantRun = s.runs.find((r) => r.jobname === JOBS.grantTickets);
  if (!grantRun) {
    findings.push(
      error(
        "grant-tickets:run",
        "lien-grant-tickets の起動記録(cron.job_run_details)がない",
      ),
    );
  } else {
    const startMs = toMs(grantRun.startTime);
    const ageH = (nowMs - startMs) / HOUR_MS;
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
          `最後の起動 ${jstDateTime(startMs)} JST(${
            ago(nowMs, startMs)
          })は succeeded・${rows}(${
            isFirst ? "月初なので呼んだ" : "1日ではないので呼ばない"
          })`,
        ),
      );
    }

    // 月初に呼んだなら、その応答も確かめる
    if (isFirst && rows === "1 row" && grantRun.status === "succeeded") {
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
              `月初の起動 ${
                jstDateTime(startMs)
              } JST に対応する HTTP 応答がない`,
            ),
          );
        }
      } else {
        const bad = checkResponseBody(
          "grant-tickets:response",
          "grant-tickets",
          res,
        );
        findings.push(
          bad ??
            ok(
              "grant-tickets:response",
              `月初の付与は HTTP 200・errors 空(付与 ${
                res.json!.granted
              }・処理済み ${res.json!.alreadyGranted}・上限 ${
                res.json!.unchanged
              })`,
            ),
        );
      }
    }
  }

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

  // 8. 公開 API から net / cron / vault に届かない(net の権限を postgres からは絞れないことの代わりの守り)
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
  } else {
    findings.push(
      ok(
        "exposure",
        `PostgREST の公開スキーマは ${
          s.postgrestSchemas.join(", ")
        }(net / cron / vault は含まれない)`,
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

/** 本番 DB を読む SQL(SELECT だけ)。結果は1行1列の JSON */
export const SNAPSHOT_SQL = `
select jsonb_build_object(
  'now', now(),
  'jobs', (
    select coalesce(jsonb_agg(jsonb_build_object('jobname', jobname, 'schedule', schedule, 'active', active) order by jobname), '[]'::jsonb)
    from cron.job
  ),
  'runs', (
    select coalesce(jsonb_agg(r order by r."startTime" desc), '[]'::jsonb) from (
      select j.jobname as "jobname", d.status as "status", d.return_message as "returnMessage", d.start_time as "startTime"
      from cron.job_run_details d left join cron.job j using (jobid)
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
      "projectStatus" | "postgrestSchemas" | "functionSecretDigests"
    >;
  }>;
  const snap = rows?.[0]?.snapshot;
  if (!snap) throw new Error("database/query の結果が空");
  const functionSecretDigests: Record<string, string> = {};
  for (const s of secrets ?? []) functionSecretDigests[s.name] = s.value;
  return {
    ...snap,
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
    findings = evaluate(snapshot, { maxAgeHours });
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
