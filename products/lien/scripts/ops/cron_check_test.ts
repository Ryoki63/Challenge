// cron_check_test.ts — cron_check.ts の判定(evaluate)の deno test。ネットワーク・実キー不要
//
// フィクスチャは本番の実際の形(2026-10-13 00:10 JST の初回の定期実行: cron.job_run_details と
// net._http_response の行)から作る。正常な状態を1つ作り、1か所ずつ壊して「赤になること」を確かめる。

import {
  type CheckOptions,
  type CronSnapshot,
  DEFAULT_MAX_AGE_HOURS,
  evaluate,
  type Finding,
  hasError,
  jstDate,
  jstDateTime,
  render,
  SNAPSHOT_SQL,
} from "./cron_check.ts";

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

// ---- フィクスチャ ----

const CRON_SHA = "a".repeat(64);

/** 2026-10-13 00:40 JST(= 10-12 15:40 UTC)。前夜 00:10 の close-day が成功した直後の正常な状態 */
function healthy(): CronSnapshot {
  return {
    now: "2026-10-12T15:40:00.123456+00:00",
    projectStatus: "ACTIVE_HEALTHY",
    postgrestSchemas: ["public", "graphql_public"],
    graphqlEnabled: false,
    jobs: [
      { jobname: "lien-close-day", schedule: "10 15 * * *", active: true },
      { jobname: "lien-grant-tickets", schedule: "5 15 * * *", active: true },
    ],
    runs: [
      {
        jobname: "lien-close-day",
        status: "succeeded",
        returnMessage: "1 row",
        startTime: "2026-10-12T15:10:00.073048+00:00",
      },
      {
        jobname: "lien-grant-tickets",
        status: "succeeded",
        returnMessage: "0 rows",
        startTime: "2026-10-12T15:05:00.154412+00:00",
      },
    ],
    responses: [
      {
        id: 5,
        statusCode: 200,
        timedOut: false,
        errorMsg: null,
        created: "2026-10-12T15:10:00.11488+00:00",
        content:
          '{"dateLocal":"2026-10-12","notify":true,"pairs":6,"recordedBoth":2,"recordedTicket":4,"reset":0,"skipped":0,"errors":[]}',
      },
    ],
    queueDepth: 0,
    vaultSecretNames: ["lien_cron_secret"],
    vaultCronSecretSha256: CRON_SHA,
    functionSecretDigests: {
      LIEN_CRON_SECRET: CRON_SHA,
      SUPABASE_URL: "b".repeat(64),
    },
  };
}

const OPTS: CheckOptions = { maxAgeHours: DEFAULT_MAX_AGE_HOURS };

function byId(findings: Finding[], id: string): Finding {
  const f = findings.find((x) => x.id === id);
  if (!f) {
    throw new Error(
      `検査 ${id} が結果にない: ${findings.map((x) => x.id).join(", ")}`,
    );
  }
  return f;
}

function errorIds(findings: Finding[]): string[] {
  return findings.filter((f) => f.level === "error").map((f) => f.id);
}

function warnIds(findings: Finding[]): string[] {
  return findings.filter((f) => f.level === "warn").map((f) => f.id);
}

/** 月初(JST 11/1 00:05 の付与 → 00:10 の確定)の翌 00:40 JST の状態 */
function firstOfMonth(): CronSnapshot {
  const s = healthy();
  s.now = "2026-10-31T15:40:00+00:00"; // JST 2026-11-01 00:40
  s.runs = [
    {
      jobname: "lien-close-day",
      status: "succeeded",
      returnMessage: "1 row",
      startTime: "2026-10-31T15:10:00.05+00:00",
    },
    {
      jobname: "lien-grant-tickets",
      status: "succeeded",
      returnMessage: "1 row",
      startTime: "2026-10-31T15:05:00.05+00:00",
    },
  ];
  s.responses = [
    {
      id: 11,
      statusCode: 200,
      timedOut: false,
      errorMsg: null,
      created: "2026-10-31T15:10:00.09+00:00",
      content:
        '{"dateLocal":"2026-10-31","notify":true,"pairs":6,"recordedBoth":2,"recordedTicket":4,"reset":0,"skipped":0,"errors":[]}',
    },
    {
      id: 10,
      statusCode: 200,
      timedOut: false,
      errorMsg: null,
      created: "2026-10-31T15:05:00.09+00:00",
      content:
        '{"dateLocal":"2026-11-01","pairs":6,"granted":4,"alreadyGranted":0,"unchanged":2,"errors":[]}',
    },
  ];
  return s;
}

// ---- 正常 ----

Deno.test("evaluate: 本番の正常な状態(前夜の close-day が 200・errors 空)は赤も黄もない", () => {
  const findings = evaluate(healthy(), OPTS);
  assertEquals(errorIds(findings), []);
  assertEquals(warnIds(findings), []);
  assertEquals(hasError(findings), false);
  // 何を確かめたかが結果に残る(ログで「見ていない」が起きない)
  assertEquals(
    findings.map((f) => f.id),
    [
      "project",
      "job:lien-close-day",
      "job:lien-grant-tickets",
      "close-day:run",
      "close-day:response",
      "grant-tickets:run",
      "grant-tickets:stray",
      "net:queue",
      "vault:cron-secret",
      "vault:master-key",
      "secrets:sync",
      "exposure",
    ],
  );
  assert(
    byId(findings, "close-day:response").message.includes("2026-10-12 を確定"),
    "確定した日がログに出る",
  );
});

Deno.test("evaluate: 月初(JST 11/1)は付与の呼び出し(1 row)とその応答も確かめて、正常なら赤も黄もない", () => {
  const findings = evaluate(firstOfMonth(), OPTS);
  assertEquals(errorIds(findings), []);
  assertEquals(warnIds(findings), []);
  assert(
    byId(findings, "grant-tickets:response").message.includes("付与 4"),
    "付与の結果がログに出る",
  );
  assert(
    byId(findings, "close-day:response").message.includes("2026-10-31 を確定"),
    "月初でも close-day は前日(10/31)を確定する",
  );
});

// ---- close-day の失敗 ----

Deno.test("evaluate: close-day の応答が 401(鍵の不一致)なら赤", () => {
  const s = healthy();
  s.responses[0] = {
    ...s.responses[0],
    statusCode: 401,
    content: '{"error":"unauthorized"}',
  };
  const findings = evaluate(s, OPTS);
  assertEquals(errorIds(findings), ["close-day:response"]);
  assert(byId(findings, "close-day:response").message.includes("401"));
  assertEquals(hasError(findings), true);
});

Deno.test("evaluate: 200 でも errors が空でなければ赤(一部のペアの処理失敗)", () => {
  const s = healthy();
  s.responses[0].content =
    '{"dateLocal":"2026-10-12","pairs":6,"recordedBoth":1,"recordedTicket":4,"reset":0,"skipped":0,"errors":[{"pairId":"p1","message":"db down"}]}';
  const findings = evaluate(s, OPTS);
  assertEquals(errorIds(findings), ["close-day:response"]);
  assert(byId(findings, "close-day:response").message.includes("p1"));
});

Deno.test("evaluate: 500・タイムアウト・エラーメッセージつきの応答は赤", () => {
  for (
    const patch of [
      { statusCode: 500, content: '{"error":"internal_error"}' },
      { statusCode: null, timedOut: true, content: null },
      { statusCode: null, errorMsg: "Couldn't resolve host", content: null },
    ]
  ) {
    const s = healthy();
    s.responses[0] = { ...s.responses[0], ...patch };
    assertEquals(
      errorIds(evaluate(s, OPTS)),
      ["close-day:response"],
      JSON.stringify(patch),
    );
  }
});

Deno.test("evaluate: 確定した日が起動日の前日でなければ赤(昨日ではなく別の日を確定した)", () => {
  const s = healthy();
  s.responses[0].content =
    '{"dateLocal":"2026-10-11","pairs":6,"recordedBoth":0,"recordedTicket":0,"reset":0,"skipped":6,"errors":[]}';
  const findings = evaluate(s, OPTS);
  assertEquals(errorIds(findings), ["close-day:response"]);
  assert(
    byId(findings, "close-day:response").message.includes("期待 2026-10-12"),
  );
});

Deno.test("evaluate: 本文が JSON でない・errors 配列がない応答は赤", () => {
  for (
    const content of [
      "<html>502 Bad Gateway</html>",
      '{"dateLocal":"2026-10-12","recordedBoth":0}',
      null,
    ]
  ) {
    const s = healthy();
    s.responses[0].content = content;
    assertEquals(
      errorIds(evaluate(s, OPTS)),
      ["close-day:response"],
      String(content),
    );
  }
});

Deno.test("evaluate: 起動が failed(SQL のエラー)なら赤", () => {
  const s = healthy();
  s.runs[0] = {
    ...s.runs[0],
    status: "failed",
    returnMessage: "permission denied for table decrypted_secrets",
  };
  const findings = evaluate(s, OPTS);
  assertEquals(errorIds(findings), ["close-day:run"]);
  assert(byId(findings, "close-day:run").message.includes("permission denied"));
});

Deno.test("evaluate: 起動の記録が無い・古い(1日以上動いていない)なら赤", () => {
  const none = healthy();
  none.runs = none.runs.filter((r) => r.jobname !== "lien-close-day");
  assert(errorIds(evaluate(none, OPTS)).includes("close-day:run"));

  // 30時間前の起動(丸1日スキップされた)。応答は保存期間を過ぎて消えている → 黄
  const stale = healthy();
  stale.now = "2026-10-13T21:10:00+00:00";
  stale.responses = [];
  const findings = evaluate(stale, OPTS);
  assert(errorIds(findings).includes("close-day:run"));
  assertEquals(warnIds(findings), ["close-day:response"]);
});

Deno.test("evaluate: maxAgeHours = 0 にすると必ず赤になる(監視 workflow の失敗時の動作確認用の入力)", () => {
  const findings = evaluate(healthy(), { maxAgeHours: 0 });
  assertEquals(hasError(findings), true);
  assert(errorIds(findings).includes("close-day:run"));
  assert(errorIds(findings).includes("grant-tickets:run"));
});

Deno.test("evaluate: 応答が無いとき — 起動が新しければ赤(送れていない)、保存期間を過ぎていれば黄(確認できない)", () => {
  const recent = healthy();
  recent.responses = [];
  assertEquals(errorIds(evaluate(recent, OPTS)), ["close-day:response"]);

  // 起動から 8 時間後(JST 08:10)に手動で実行した場合。応答は 6 時間で消えている
  const expired = healthy();
  expired.now = "2026-10-12T23:10:00+00:00";
  expired.responses = [];
  const findings = evaluate(expired, OPTS);
  assertEquals(errorIds(findings), []);
  assertEquals(warnIds(findings), ["close-day:response"]);
  assertEquals(hasError(findings), false);
});

Deno.test("evaluate: 起動と無関係な時間帯の応答(別の日の手動実行など)は、その起動の応答として使わない", () => {
  const s = healthy();
  s.responses = [{
    id: 4,
    statusCode: 200,
    timedOut: false,
    errorMsg: null,
    created: "2026-10-12T09:29:00+00:00", // 18:29 JST の手動実行
    content:
      '{"dateLocal":"2026-10-11","pairs":2,"recordedBoth":0,"recordedTicket":0,"reset":0,"skipped":2,"errors":[]}',
  }];
  assertEquals(errorIds(evaluate(s, OPTS)), ["close-day:response"]);
});

Deno.test("evaluate: 形のない応答(401 など)は起動時刻にいちばん近いものを使う", () => {
  const s = healthy();
  s.responses = [
    {
      id: 7,
      statusCode: 401,
      timedOut: false,
      errorMsg: null,
      created: "2026-10-12T15:10:00.2+00:00",
      content: '{"error":"unauthorized"}',
    },
    {
      id: 6,
      statusCode: 200,
      timedOut: false,
      errorMsg: null,
      created: "2026-10-12T15:14:00+00:00",
      content: '{"some":"other"}',
    },
  ];
  const findings = evaluate(s, OPTS);
  assert(byId(findings, "close-day:response").message.includes("401"));
});

// ---- ジョブ・プロジェクト ----

Deno.test("evaluate: ジョブが無い・無効なら赤", () => {
  const missing = healthy();
  missing.jobs = missing.jobs.filter((j) => j.jobname !== "lien-grant-tickets");
  assertEquals(errorIds(evaluate(missing, OPTS)), ["job:lien-grant-tickets"]);

  const inactive = healthy();
  inactive.jobs[0].active = false;
  assertEquals(errorIds(evaluate(inactive, OPTS)), ["job:lien-close-day"]);
});

Deno.test("evaluate: プロジェクトが ACTIVE_HEALTHY でなければ赤(無料枠の自動停止)", () => {
  for (const status of ["INACTIVE", "PAUSED", "COMING_UP", "UNKNOWN"]) {
    const s = healthy();
    s.projectStatus = status;
    assertEquals(errorIds(evaluate(s, OPTS)), ["project"], status);
  }
});

Deno.test("evaluate: 削除済みのジョブ(jobname = null)の起動記録・一時ジョブは数えない", () => {
  const s = healthy();
  s.runs.unshift({
    jobname: null,
    status: "succeeded",
    returnMessage: "0 rows",
    startTime: "2026-10-12T15:30:00+00:00",
  });
  assertEquals(errorIds(evaluate(s, OPTS)), []);
});

// ---- grant-tickets ----

Deno.test("evaluate: 月初なのに付与を呼んでいない(0 rows)なら赤", () => {
  const s = firstOfMonth();
  s.runs[1].returnMessage = "0 rows";
  s.responses = s.responses.filter((r) => !r.content?.includes("granted"));
  const findings = evaluate(s, OPTS);
  assertEquals(errorIds(findings), ["grant-tickets:run"]);
  assert(
    byId(findings, "grant-tickets:run").message.includes("付与が走っていない"),
  );
});

Deno.test("evaluate: 月初の付与が 200 でも errors が空でない、401、応答が無いなら赤", () => {
  const withErrors = firstOfMonth();
  withErrors.responses[1].content =
    '{"dateLocal":"2026-11-01","pairs":6,"granted":3,"alreadyGranted":0,"unchanged":2,"errors":[{"pairId":"p9","message":"rpc down"}]}';
  assertEquals(errorIds(evaluate(withErrors, OPTS)), [
    "grant-tickets:response",
  ]);

  const unauthorized = firstOfMonth();
  unauthorized.responses = [unauthorized.responses[0], {
    id: 10,
    statusCode: 401,
    timedOut: false,
    errorMsg: null,
    created: "2026-10-31T15:05:00.09+00:00",
    content: '{"error":"unauthorized"}',
  }];
  assertEquals(errorIds(evaluate(unauthorized, OPTS)), [
    "grant-tickets:response",
  ]);

  const missing = firstOfMonth();
  missing.responses = [missing.responses[0]];
  assertEquals(errorIds(evaluate(missing, OPTS)), ["grant-tickets:response"]);
});

Deno.test("evaluate: 1日でない日に付与が呼ばれた(1 row)なら赤", () => {
  const s = healthy();
  s.runs[1].returnMessage = "1 row";
  const findings = evaluate(s, OPTS);
  assertEquals(errorIds(findings), ["grant-tickets:run"]);
  assert(
    byId(findings, "grant-tickets:run").message.includes(
      "月の途中に付与が呼ばれた",
    ),
  );
});

Deno.test("evaluate: 保存期間内の応答に、JST の1日でない日の grant-tickets の応答があれば赤(手動の pg_net 実行も含む)", () => {
  const s = healthy();
  s.responses.push({
    id: 4,
    statusCode: 200,
    timedOut: false,
    errorMsg: null,
    created: "2026-10-12T14:00:00+00:00", // JST 10/12 23:00
    content:
      '{"dateLocal":"2026-10-12","pairs":6,"granted":2,"alreadyGranted":0,"unchanged":4,"errors":[]}',
  });
  assertEquals(errorIds(evaluate(s, OPTS)), ["grant-tickets:stray"]);
});

// ---- 鍵・公開範囲・キュー ----

Deno.test("evaluate: Vault に cron 専用の秘密が無ければ赤・万能鍵が残っていれば赤", () => {
  const noSecret = healthy();
  noSecret.vaultSecretNames = [];
  noSecret.vaultCronSecretSha256 = null;
  assertEquals(errorIds(evaluate(noSecret, OPTS)), ["vault:cron-secret"]);

  const masterKey = healthy();
  masterKey.vaultSecretNames = ["lien_cron_secret", "lien_service_role_key"];
  assertEquals(errorIds(evaluate(masterKey, OPTS)), ["vault:master-key"]);
});

Deno.test("evaluate: Vault と Function secrets の値が違う・Function secrets に無いなら赤(SHA-256 の照合)", () => {
  const mismatch = healthy();
  mismatch.functionSecretDigests.LIEN_CRON_SECRET = "c".repeat(64);
  const findings = evaluate(mismatch, OPTS);
  assertEquals(errorIds(findings), ["secrets:sync"]);
  assert(byId(findings, "secrets:sync").message.includes("値が違う"));

  const missing = healthy();
  delete missing.functionSecretDigests.LIEN_CRON_SECRET;
  assertEquals(errorIds(evaluate(missing, OPTS)), ["secrets:sync"]);
});

Deno.test("evaluate: 結果に秘密の値もダイジェストも出さない", () => {
  const s = healthy();
  s.vaultCronSecretSha256 = "d".repeat(64);
  s.functionSecretDigests.LIEN_CRON_SECRET = "e".repeat(64); // 不一致の赤にする
  const text = render(evaluate(s, OPTS));
  assert(
    !text.includes("d".repeat(16)) && !text.includes("e".repeat(16)),
    "ダイジェストを表示していない",
  );
});

Deno.test("evaluate: PostgREST の公開スキーマに net / cron / vault が含まれれば赤", () => {
  for (const schema of ["net", "cron", "vault"]) {
    const s = healthy();
    s.postgrestSchemas = ["public", "graphql_public", schema];
    const findings = evaluate(s, OPTS);
    assertEquals(errorIds(findings), ["exposure"], schema);
    assert(byId(findings, "exposure").message.includes(schema));
  }
});

Deno.test("evaluate: pg_graphql が有効なら赤(PUBLIC に SELECT が付いた net の表が GraphQL に出る恐れ)", () => {
  const s = healthy();
  s.graphqlEnabled = true;
  const findings = evaluate(s, OPTS);
  assertEquals(errorIds(findings), ["exposure"]);
  assert(byId(findings, "exposure").message.includes("pg_graphql"));
});

Deno.test("evaluate: pg_net のキューに処理待ちが残っていれば赤", () => {
  const s = healthy();
  s.queueDepth = 3;
  assertEquals(errorIds(evaluate(s, OPTS)), ["net:queue"]);
});

// ---- 表示・補助 ----

Deno.test("render: 1検査1行で、OK / WARN / FAIL の印が付く", () => {
  const s = healthy();
  s.queueDepth = 1;
  const text = render(evaluate(s, OPTS));
  const lines = text.split("\n");
  assertEquals(lines.length, 12);
  assert(lines.some((l) => l.startsWith("[FAIL] net:queue:")));
  assert(lines.some((l) => l.startsWith("[OK  ] project:")));
});

Deno.test("jstDate / jstDateTime: UTC の瞬間を JST の暦に直す", () => {
  const ms = Date.parse("2026-10-12T15:10:00Z");
  assertEquals(jstDate(ms), "2026-10-13");
  assertEquals(jstDateTime(ms), "2026-10-13 00:10");
  assertEquals(jstDate(Date.parse("2026-12-31T15:00:00Z")), "2027-01-01");
});

Deno.test("SNAPSHOT_SQL: 読み取りだけ(SELECT)で、秘密の値そのものを返さない", () => {
  const sql = SNAPSHOT_SQL.toLowerCase();
  for (
    const word of [
      "insert ",
      "update ",
      "delete ",
      "drop ",
      "alter ",
      "create ",
      "truncate ",
      "grant ",
      "revoke ",
    ]
  ) {
    assert(!sql.includes(word), `書き込み系の語 ${word.trim()} を含む`);
  }
  // 秘密は SHA-256 にして返す(decrypted_secret を素のまま select しない)
  assert(sql.includes("digest(decrypted_secret, 'sha256')"));
  assert(sql.includes("'graphqlenabled'"), "pg_graphql の有無を返す");
  assert(!/select\s+decrypted_secret/.test(sql));
});
