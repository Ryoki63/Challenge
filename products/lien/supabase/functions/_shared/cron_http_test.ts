// cron_http_test.ts — _shared/cron_http.ts の deno test(ネットワーク・DB 不要)
// 正本: docs/DESIGN.md §5.3(close-day / grant-tickets)/ §7 / issue #60(cron 専用シークレット)

import {
  bearerToken,
  handleCronRequest,
  isAuthorizedCronRequest,
  MIN_CRON_SECRET_LENGTH,
  type ParseResult,
  readOptionalJsonObject,
  rejectUnknownKeys,
  timingSafeEqual,
} from "./cron_http.ts";

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

/** テスト用の秘密(本物ではない。32 文字以上) */
const SECRET =
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

// ---- bearerToken / timingSafeEqual ----

Deno.test("bearerToken: Bearer 接頭辞つきのトークンだけを取り出す", () => {
  assertEquals(bearerToken("Bearer abc"), "abc");
  assertEquals(
    bearerToken("bearer abc"),
    "abc",
    "接頭辞は大文字小文字を問わない",
  );
  assertEquals(bearerToken("Bearer   abc  "), "abc", "前後の空白は無視");
  // 接頭辞が無い・空・トークンが空・空白を含む → 空文字(認証失敗扱い)
  assertEquals(bearerToken(null), "");
  assertEquals(bearerToken(""), "");
  assertEquals(bearerToken("abc"), "", "接頭辞なしの生のトークンは通さない");
  assertEquals(bearerToken("Bearer "), "");
  assertEquals(bearerToken("Basic abc"), "");
  assertEquals(bearerToken("Bearer a b"), "");
});

Deno.test("timingSafeEqual: 一致のときだけ true(長さ違い・1文字違いは false)", () => {
  assertEquals(timingSafeEqual("abc", "abc"), true);
  assertEquals(timingSafeEqual("", ""), true);
  assertEquals(timingSafeEqual("abc", "abd"), false);
  assertEquals(timingSafeEqual("abc", "ab"), false);
  assertEquals(timingSafeEqual("ab", "abc"), false);
  assertEquals(timingSafeEqual("abc", ""), false);
  assertEquals(
    timingSafeEqual("あいう", "あいう"),
    true,
    "UTF-8 でも比較できる",
  );
  assertEquals(timingSafeEqual("あいう", "あいえ"), false);
});

// ---- isAuthorizedCronRequest ----

Deno.test("isAuthorizedCronRequest: 秘密と完全一致する Bearer だけ通す", () => {
  assertEquals(isAuthorizedCronRequest(`Bearer ${SECRET}`, SECRET), true);
  assertEquals(
    isAuthorizedCronRequest(`Bearer ${SECRET}x`, SECRET),
    false,
    "末尾に1文字足したら不一致",
  );
  assertEquals(
    isAuthorizedCronRequest(`Bearer ${SECRET.slice(0, -1)}`, SECRET),
    false,
    "1文字足りなくても不一致",
  );
  assertEquals(isAuthorizedCronRequest(SECRET, SECRET), false, "接頭辞なし");
  assertEquals(isAuthorizedCronRequest(null, SECRET), false, "ヘッダなし");
  assertEquals(isAuthorizedCronRequest("Bearer ", SECRET), false);
});

Deno.test("isAuthorizedCronRequest: 秘密が未設定・短すぎるときは何を送っても拒否(空文字どうしの一致を許さない)", () => {
  assertEquals(isAuthorizedCronRequest("Bearer ", ""), false);
  assertEquals(isAuthorizedCronRequest("Bearer x", ""), false);
  assertEquals(isAuthorizedCronRequest("Bearer x", undefined), false);
  const short = "a".repeat(MIN_CRON_SECRET_LENGTH - 1);
  assertEquals(
    isAuthorizedCronRequest(`Bearer ${short}`, short),
    false,
    "短い秘密は設定ミスとして全拒否",
  );
  const minimum = "a".repeat(MIN_CRON_SECRET_LENGTH);
  assertEquals(isAuthorizedCronRequest(`Bearer ${minimum}`, minimum), true);
});

Deno.test("isAuthorizedCronRequest: service role key など別の鍵は通らない(cron 専用の秘密だけ)", () => {
  const serviceRoleKey = "sb_secret_" + "x".repeat(31); // 本物ではない。形だけ
  assertEquals(
    isAuthorizedCronRequest(`Bearer ${serviceRoleKey}`, SECRET),
    false,
  );
  assertEquals(
    isAuthorizedCronRequest(`Bearer ${SECRET}`, serviceRoleKey),
    false,
    "鍵の取り違え(逆向き)も不一致",
  );
});

// ---- readOptionalJsonObject / rejectUnknownKeys ----

function post(body: BodyInit | null, headers: Record<string, string> = {}) {
  return new Request("https://example.test/fn", {
    method: "POST",
    headers,
    body,
  });
}

Deno.test("readOptionalJsonObject: 空は {}、JSON オブジェクトはそのまま", async () => {
  assertEquals(await readOptionalJsonObject(post(null)), {
    ok: true,
    value: {},
  });
  assertEquals(await readOptionalJsonObject(post("")), { ok: true, value: {} });
  assertEquals(await readOptionalJsonObject(post("  \n ")), {
    ok: true,
    value: {},
  });
  assertEquals(await readOptionalJsonObject(post("{}")), {
    ok: true,
    value: {},
  });
  assertEquals(
    await readOptionalJsonObject(
      post('{"dateLocal":"2026-10-11","notify":false}'),
    ),
    { ok: true, value: { dateLocal: "2026-10-11", notify: false } },
  );
});

Deno.test("readOptionalJsonObject: 壊れた JSON・オブジェクト以外は invalid_json(空として扱わない)", async () => {
  const bad = [
    '{"dateLocal":"2026-10-11","notify":false', // 途切れた本文
    "not json",
    "null",
    "[]",
    '["a"]',
    "1",
    '"text"',
    "true",
  ];
  for (const text of bad) {
    assertEquals(
      await readOptionalJsonObject(post(text)),
      { ok: false, error: "invalid_json" },
      text,
    );
  }
});

Deno.test("rejectUnknownKeys: 許可したキーだけ通す", () => {
  assertEquals(rejectUnknownKeys({}, ["dateLocal"]), { ok: true, value: true });
  assertEquals(
    rejectUnknownKeys({ dateLocal: "2026-10-11" }, ["dateLocal", "notify"]),
    { ok: true, value: true },
  );
  assertEquals(
    rejectUnknownKeys({ notifiy: false }, ["dateLocal", "notify"]),
    { ok: false, error: "unknown_field" },
    "打ち間違いは通さない",
  );
});

// ---- handleCronRequest ----

interface Call {
  input: unknown;
}

function makeOpts(
  overrides: {
    secret?: string | undefined;
    run?: (input: { dateLocal?: string }) => Promise<
      { status: number; body: unknown }
    >;
  } = {},
) {
  const calls: Call[] = [];
  const opts = {
    label: "test-fn",
    secret: "secret" in overrides ? overrides.secret : SECRET,
    parse: (
      body: Record<string, unknown>,
    ): ParseResult<{ dateLocal?: string }> => {
      const unknown = rejectUnknownKeys(body, ["dateLocal"]);
      if (!unknown.ok) return unknown;
      if (body.dateLocal !== undefined && typeof body.dateLocal !== "string") {
        return { ok: false, error: "invalid_date_local" };
      }
      return { ok: true, value: { dateLocal: body.dateLocal as string } };
    },
    run: overrides.run ?? ((input: { dateLocal?: string }) => {
      calls.push({ input });
      return Promise.resolve({ status: 200, body: { ran: true } });
    }),
  };
  return { opts, calls };
}

async function respond(
  res: Response,
): Promise<{ status: number; body: unknown }> {
  return { status: res.status, body: await res.json() };
}

Deno.test("handleCronRequest: POST 以外は 405(認証より先)", async () => {
  const { opts, calls } = makeOpts();
  const res = await handleCronRequest(
    new Request("https://example.test/fn", { method: "GET" }),
    opts,
  );
  assertEquals(await respond(res), {
    status: 405,
    body: { error: "method_not_allowed" },
  });
  assertEquals(calls.length, 0);
});

Deno.test("handleCronRequest: 認証なし・別の鍵は 401 で、本体は動かない", async () => {
  const { opts, calls } = makeOpts();
  for (
    const authorization of [undefined, "Bearer wrong", `Bearer ${SECRET}x`]
  ) {
    const headers: Record<string, string> = authorization
      ? { Authorization: authorization }
      : {};
    const res = await handleCronRequest(post("{}", headers), opts);
    assertEquals(await respond(res), {
      status: 401,
      body: { error: "unauthorized" },
    }, String(authorization));
  }
  assertEquals(calls.length, 0);
});

Deno.test("handleCronRequest: 秘密が未設定なら正しそうな Bearer でも 401", async () => {
  for (const secret of [undefined, "", "short"]) {
    const { opts, calls } = makeOpts({ secret });
    const res = await handleCronRequest(
      post("{}", { Authorization: `Bearer ${secret ?? ""}` }),
      opts,
    );
    assertEquals(res.status, 401, String(secret));
    assertEquals(calls.length, 0);
  }
});

Deno.test("handleCronRequest: 認証が先 — 認証前の呼び出し元には本文の検証結果を見せない", async () => {
  const { opts } = makeOpts();
  const res = await handleCronRequest(post("{broken"), opts);
  assertEquals(
    await respond(res),
    { status: 401, body: { error: "unauthorized" } },
    "壊れた本文でも、認証なしなら 401(400 にしない)",
  );
});

Deno.test("handleCronRequest: 認証済みで本文が壊れていれば 400 invalid_json・知らないキーは 400 unknown_field", async () => {
  const { opts, calls } = makeOpts();
  const auth = { Authorization: `Bearer ${SECRET}` };

  const broken = await handleCronRequest(
    post('{"dateLocal":"2026-10-11"', auth),
    opts,
  );
  assertEquals(await respond(broken), {
    status: 400,
    body: { error: "invalid_json" },
  });

  const typo = await handleCronRequest(
    post('{"datelocal":"2026-10-11"}', auth),
    opts,
  );
  assertEquals(await respond(typo), {
    status: 400,
    body: { error: "unknown_field" },
  });

  const wrongType = await handleCronRequest(
    post('{"dateLocal":20261011}', auth),
    opts,
  );
  assertEquals(await respond(wrongType), {
    status: 400,
    body: { error: "invalid_date_local" },
  });

  assertEquals(calls.length, 0, "400 のときは本体を動かさない");
});

Deno.test("handleCronRequest: 認証済み — 空の本文(cron の素朴な POST)も JSON も本体へ渡る", async () => {
  const { opts, calls } = makeOpts();
  const auth = { Authorization: `Bearer ${SECRET}` };

  const empty = await handleCronRequest(post(null, auth), opts);
  assertEquals(await respond(empty), { status: 200, body: { ran: true } });
  const withDate = await handleCronRequest(
    post('{"dateLocal":"2026-10-11"}', auth),
    opts,
  );
  assertEquals(withDate.status, 200);

  assertEquals(calls, [
    { input: {} },
    { input: { dateLocal: "2026-10-11" } },
  ]);
});

Deno.test("handleCronRequest: 本体が返した status・body をそのまま返す(400 など)", async () => {
  const { opts } = makeOpts({
    run: () =>
      Promise.resolve({ status: 400, body: { error: "invalid_date_local" } }),
  });
  const res = await handleCronRequest(
    post("{}", { Authorization: `Bearer ${SECRET}` }),
    opts,
  );
  assertEquals(await respond(res), {
    status: 400,
    body: { error: "invalid_date_local" },
  });
});

Deno.test("handleCronRequest: 本体が throw したら 500 internal_error(詳細は返さずログに残す)", async () => {
  const { opts } = makeOpts({
    run: () => Promise.reject(new Error("db down: secret detail")),
  });
  const origError = console.error;
  const logs: string[] = [];
  console.error = (...args: unknown[]) => logs.push(args.map(String).join(" "));
  try {
    const res = await handleCronRequest(
      post("{}", { Authorization: `Bearer ${SECRET}` }),
      opts,
    );
    assertEquals(await respond(res), {
      status: 500,
      body: { error: "internal_error" },
    });
  } finally {
    console.error = origError;
  }
  assertEquals(logs.length > 0, true, "例外はログに残す");
  assertEquals(
    logs.some((l) => l.includes(SECRET)),
    false,
    "秘密はログに出さない",
  );
});
