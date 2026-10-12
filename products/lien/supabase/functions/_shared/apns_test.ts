// apns_test.ts — apns.ts の deno test(送信はモック。ネットワーク・実キー不要)
// 正本: docs/DESIGN.md §4(ペイロード)/ §5.5(リトライ1回・失敗でも throw しない)

import {
  ApnsClient,
  type ApnsConfig,
  type ApnsEnvironment,
  type ApnsHttpPost,
  type ApnsHttpResponse,
  buildVisiblePushPayload,
  createApnsJwt,
  isInvalidTokenResponse,
  loadApnsConfigFromEnv,
  type PushTokenStore,
  TokenAwarePusher,
} from "./apns.ts";
import { buildSoloSnapshot } from "./snapshot.ts";

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

function assertThrows(fn: () => unknown, msg = ""): void {
  let threw = false;
  try {
    fn();
  } catch {
    threw = true;
  }
  if (!threw) {
    throw new Error(`assertThrows failed: 例外が発生しなかった ${msg}`);
  }
}

// ---- テスト用の鍵・モック ----

/** P-256 鍵ペアを生成し、秘密鍵を .p8 相当の PEM にして返す */
async function makeTestKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );
  let bin = "";
  for (const b of pkcs8) bin += String.fromCharCode(b);
  const b64 = btoa(bin);
  const lines = b64.match(/.{1,64}/g) ?? [];
  const pem = `-----BEGIN PRIVATE KEY-----\n${
    lines.join("\n")
  }\n-----END PRIVATE KEY-----\n`;
  return { pem, publicKey: pair.publicKey };
}

function base64UrlDecodeBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") +
    "=".repeat((4 - s.length % 4) % 4);
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function base64UrlDecodeJson(s: string): unknown {
  return JSON.parse(new TextDecoder().decode(base64UrlDecodeBytes(s)));
}

interface RecordedCall {
  url: string;
  headers: Record<string, string>;
  body: string;
}

/** 応答スクリプト(順に消費。Error なら reject)付きの送信モック */
function mockTransport(script: Array<ApnsHttpResponse | Error> = []): {
  calls: RecordedCall[];
  post: ApnsHttpPost;
} {
  const calls: RecordedCall[] = [];
  const post: ApnsHttpPost = (url, headers, body) => {
    calls.push({ url, headers, body });
    const next = script.shift();
    if (next === undefined) return Promise.resolve({ status: 200, body: "" });
    if (next instanceof Error) return Promise.reject(next);
    return Promise.resolve(next);
  };
  return { calls, post };
}

function makeConfig(
  pem: string,
  env: "sandbox" | "production" = "sandbox",
): ApnsConfig {
  return {
    keyPem: pem,
    keyId: "KEY1234567",
    teamId: "TEAM123456",
    environment: env,
    topic: "com.example.lien",
  };
}

// ---- JWT(ES256) ----

Deno.test("createApnsJwt: header/claims が正しく、ES256 署名が公開鍵で検証できる", async () => {
  const { pem, publicKey } = await makeTestKey();
  const issuedAt = new Date("2026-06-10T12:00:00Z");
  const jwt = await createApnsJwt({
    keyPem: pem,
    keyId: "KEY1234567",
    teamId: "TEAM123456",
    issuedAt,
  });

  const parts = jwt.split(".");
  assertEquals(parts.length, 3, "JWT は3パート");
  assertEquals(base64UrlDecodeJson(parts[0]), {
    alg: "ES256",
    kid: "KEY1234567",
  });
  assertEquals(base64UrlDecodeJson(parts[1]), {
    iss: "TEAM123456",
    iat: Math.floor(issuedAt.getTime() / 1000),
  });

  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    base64UrlDecodeBytes(parts[2]).buffer as ArrayBuffer,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  assertEquals(verified, true, "署名検証");
});

Deno.test("createApnsJwt: PEM でない鍵は reject", async () => {
  let threw = false;
  try {
    await createApnsJwt({
      keyPem: "not-a-pem",
      keyId: "K",
      teamId: "T",
      issuedAt: new Date(),
    });
  } catch {
    threw = true;
  }
  assert(threw, "不正な鍵で例外");
});

// ---- 設定読み込み ----

const FULL_ENV: Record<string, string> = {
  APNS_AUTH_KEY: "-----BEGIN PRIVATE KEY-----\nxxx\n-----END PRIVATE KEY-----",
  APNS_KEY_ID: "KEY1234567",
  APPLE_TEAM_ID: "TEAM123456",
  APNS_ENV: "sandbox",
  APNS_TOPIC: "com.example.lien",
};

Deno.test("loadApnsConfigFromEnv: 全変数あり → 設定を返す", () => {
  const config = loadApnsConfigFromEnv((k) => FULL_ENV[k]);
  assertEquals(config, {
    keyPem: FULL_ENV.APNS_AUTH_KEY,
    keyId: "KEY1234567",
    teamId: "TEAM123456",
    environment: "sandbox",
    topic: "com.example.lien",
  });
});

Deno.test("loadApnsConfigFromEnv: 1つでも欠けたら null(push 無効で運転)", () => {
  for (const missing of Object.keys(FULL_ENV)) {
    const config = loadApnsConfigFromEnv((k) =>
      k === missing ? undefined : FULL_ENV[k]
    );
    assertEquals(config, null, `${missing} 欠落`);
  }
});

Deno.test("loadApnsConfigFromEnv: APNS_ENV が不正値なら throw(設定ミスは大声で)", () => {
  assertThrows(() =>
    loadApnsConfigFromEnv((k) => k === "APNS_ENV" ? "prod" : FULL_ENV[k])
  );
});

// ---- ペイロード(DESIGN §4 と一字一句一致) ----

Deno.test("buildVisiblePushPayload: §4 の形(mutable-content: 1, lien.type, snapshot同梱)", () => {
  const snapshot = buildSoloSnapshot({
    updatedAtIso: "2026-06-10T03:00:00.000Z",
    todayMeDone: true,
    myPromise: { title: "筋トレ", emoji: "💪" },
  });
  const payload = buildVisiblePushPayload({
    title: "ゆうき",
    body: "ランニングやった!🔥",
    type: "partner_checkin",
    snapshot,
  });
  assertEquals(payload, {
    aps: {
      alert: { title: "ゆうき", body: "ランニングやった!🔥" },
      sound: "default",
      "mutable-content": 1,
    },
    lien: { type: "partner_checkin", snapshot },
  });
});

// ---- ApnsClient(送信・リトライ・キャッシュ) ----

Deno.test("ApnsClient: 成功時 — URL/ヘッダ/本文が正しい", async () => {
  const { pem } = await makeTestKey();
  const { calls, post } = mockTransport([{ status: 200, body: "" }]);
  const client = new ApnsClient(makeConfig(pem), {
    post,
    now: () => new Date("2026-06-10T12:00:00Z"),
  });

  const result = await client.send("device-token-1", { hello: "world" });
  assertEquals(result, { ok: true, status: 200, attempts: 1 });
  assertEquals(calls.length, 1);
  assertEquals(
    calls[0].url,
    "https://api.sandbox.push.apple.com/3/device/device-token-1",
  );
  assertEquals(calls[0].headers["apns-topic"], "com.example.lien");
  assertEquals(calls[0].headers["apns-push-type"], "alert");
  assertEquals(calls[0].headers["apns-priority"], "10");
  assertEquals(calls[0].headers["content-type"], "application/json");
  assert(
    calls[0].headers.authorization.startsWith("bearer "),
    "bearer トークン",
  );
  assertEquals(JSON.parse(calls[0].body), { hello: "world" });
});

Deno.test("ApnsClient: production は api.push.apple.com(DESIGN §10: APNS_ENV で切替)", async () => {
  const { pem } = await makeTestKey();
  const { calls, post } = mockTransport();
  const client = new ApnsClient(makeConfig(pem, "production"), { post });
  await client.send("tok", {});
  assertEquals(calls[0].url, "https://api.push.apple.com/3/device/tok");
});

Deno.test("ApnsClient: 5xx は1回だけリトライして成功できる(DESIGN §5.5)", async () => {
  const { pem } = await makeTestKey();
  const { calls, post } = mockTransport([
    { status: 503, body: "unavailable" },
    { status: 200, body: "" },
  ]);
  const client = new ApnsClient(makeConfig(pem), { post });
  const result = await client.send("tok", {});
  assertEquals(result, { ok: true, status: 200, attempts: 2 });
  assertEquals(calls.length, 2);
});

Deno.test("ApnsClient: 2回失敗したらそれ以上リトライせず ok:false(throw しない)", async () => {
  const { pem } = await makeTestKey();
  const { calls, post } = mockTransport([
    { status: 500, body: "e1" },
    { status: 500, body: "e2" },
  ]);
  const client = new ApnsClient(makeConfig(pem), { post });
  const result = await client.send("tok", {});
  assertEquals(result.ok, false);
  assertEquals(result.attempts, 2);
  assertEquals(calls.length, 2, "リトライは1回まで");
});

Deno.test("ApnsClient: 送信例外(ネットワーク断)もリトライ対象。最終失敗でも throw しない", async () => {
  const { pem } = await makeTestKey();
  const { calls, post } = mockTransport([
    new Error("network down"),
    { status: 200, body: "" },
  ]);
  const client = new ApnsClient(makeConfig(pem), { post });
  const result = await client.send("tok", {});
  assertEquals(result, { ok: true, status: 200, attempts: 2 });
  assertEquals(calls.length, 2);

  const both = mockTransport([new Error("down1"), new Error("down2")]);
  const client2 = new ApnsClient(makeConfig(pem), { post: both.post });
  const result2 = await client2.send("tok", {});
  assertEquals(result2.ok, false);
  assertEquals(result2.attempts, 2);
});

Deno.test("ApnsClient: 4xx(BadDeviceToken 等)はリトライしない", async () => {
  const { pem } = await makeTestKey();
  const { calls, post } = mockTransport([
    { status: 410, body: '{"reason":"Unregistered"}' },
  ]);
  const client = new ApnsClient(makeConfig(pem), { post });
  const result = await client.send("tok", {});
  assertEquals(result.ok, false);
  assertEquals(calls.length, 1, "4xx は再送しても無駄");
});

Deno.test("ApnsClient: JWT は45分間キャッシュされ、期限後に再発行される", async () => {
  const { pem } = await makeTestKey();
  const { calls, post } = mockTransport();
  let nowMs = Date.parse("2026-06-10T00:00:00Z");
  const client = new ApnsClient(makeConfig(pem), {
    post,
    now: () => new Date(nowMs),
  });

  await client.send("tok", {});
  nowMs += 10 * 60 * 1000; // +10分: キャッシュ内
  await client.send("tok", {});
  assertEquals(
    calls[1].headers.authorization,
    calls[0].headers.authorization,
    "45分以内は同じ JWT",
  );

  nowMs += 40 * 60 * 1000; // 計+50分: 期限切れ
  await client.send("tok", {});
  assert(
    calls[2].headers.authorization !== calls[0].headers.authorization,
    "期限切れ後は再発行",
  );
});

// ---- APNs の環境はトークン単位(issue #53 / DESIGN §4) ----

Deno.test("ApnsClient: opts.environment で送信先を上書きできる(省略時は設定の APNS_ENV)", async () => {
  const { pem } = await makeTestKey();
  const { calls, post } = mockTransport();
  const sandboxDefault = new ApnsClient(makeConfig(pem, "sandbox"), { post });
  await sandboxDefault.send("t1", {});
  await sandboxDefault.send("t2", {}, { environment: "production" });
  const productionDefault = new ApnsClient(makeConfig(pem, "production"), {
    post,
  });
  await productionDefault.send("t3", {}, { environment: "sandbox" });
  await productionDefault.send("t4", {});

  assertEquals(calls.map((c) => c.url), [
    "https://api.sandbox.push.apple.com/3/device/t1",
    "https://api.push.apple.com/3/device/t2",
    "https://api.sandbox.push.apple.com/3/device/t3",
    "https://api.push.apple.com/3/device/t4",
  ]);
});

Deno.test("isInvalidTokenResponse: 410 と 400 BadDeviceToken だけがトークン無効", () => {
  const table: Array<[number, string, boolean]> = [
    [410, '{"reason":"Unregistered"}', true],
    [410, '{"reason":"ExpiredToken"}', true],
    [410, "", true],
    [400, '{"reason":"BadDeviceToken"}', true],
    // トークンのせいとは限らない失敗は false(設定ミスで全員のトークンを消さない)
    [400, '{"reason":"DeviceTokenNotForTopic"}', false],
    [400, '{"reason":"BadTopic"}', false],
    [400, '{"reason":"PayloadEmpty"}', false],
    [400, "", false],
    [400, "not json", false],
    [400, "null", false],
    [403, '{"reason":"InvalidProviderToken"}', false],
    [403, '{"reason":"ExpiredProviderToken"}', false],
    [404, '{"reason":"BadPath"}', false],
    [413, '{"reason":"PayloadTooLarge"}', false],
    [429, '{"reason":"TooManyRequests"}', false],
    [500, '{"reason":"InternalServerError"}', false],
    [503, '{"reason":"ServiceUnavailable"}', false],
    [200, "", false],
  ];
  for (const [status, body, expected] of table) {
    assertEquals(
      isInvalidTokenResponse(status, body),
      expected,
      `${status} ${body}`,
    );
  }
});

Deno.test("ApnsClient: 失敗結果の invalidToken — 410 / BadDeviceToken は true、それ以外の失敗は false", async () => {
  const { pem } = await makeTestKey();
  const cases: Array<{
    label: string;
    script: Array<ApnsHttpResponse | Error>;
    invalid: boolean;
    attempts: number;
  }> = [
    {
      label: "410 Unregistered",
      script: [{ status: 410, body: '{"reason":"Unregistered"}' }],
      invalid: true,
      attempts: 1,
    },
    {
      label: "400 BadDeviceToken",
      script: [{ status: 400, body: '{"reason":"BadDeviceToken"}' }],
      invalid: true,
      attempts: 1,
    },
    {
      label: "400 DeviceTokenNotForTopic",
      script: [{ status: 400, body: '{"reason":"DeviceTokenNotForTopic"}' }],
      invalid: false,
      attempts: 1,
    },
    {
      label: "403 ExpiredProviderToken",
      script: [{ status: 403, body: '{"reason":"ExpiredProviderToken"}' }],
      invalid: false,
      attempts: 1,
    },
    {
      label: "5xx が2回",
      script: [{ status: 500, body: "e1" }, { status: 500, body: "e2" }],
      invalid: false,
      attempts: 2,
    },
    {
      label: "送信例外が2回",
      script: [new Error("down1"), new Error("down2")],
      invalid: false,
      attempts: 2,
    },
    {
      label: "1回目 5xx → 2回目 410(リトライ後に無効と分かる)",
      script: [
        { status: 503, body: "" },
        { status: 410, body: '{"reason":"Unregistered"}' },
      ],
      invalid: true,
      attempts: 2,
    },
  ];
  for (const c of cases) {
    const { calls, post } = mockTransport([...c.script]);
    const client = new ApnsClient(makeConfig(pem), { post });
    const result = await client.send("tok", {});
    if (result.ok) throw new Error(`${c.label}: 失敗するはず`);
    assertEquals(result.invalidToken, c.invalid, c.label);
    assertEquals(result.attempts, c.attempts, c.label);
    assertEquals(calls.length, c.attempts, c.label);
  }

  // 成功には invalidToken が付かない
  const ok = await new ApnsClient(makeConfig(pem), {
    post: mockTransport().post,
  })
    .send("tok", {});
  assertEquals(ok, { ok: true, status: 200, attempts: 1 });
});

// ---- TokenAwarePusher ----

interface StoreOpts {
  envs?: Record<string, ApnsEnvironment | null>;
  getThrows?: boolean;
  clearThrows?: boolean;
}

function makeStore(opts: StoreOpts = {}): {
  store: PushTokenStore;
  lookups: string[];
  cleared: string[];
} {
  const lookups: string[] = [];
  const cleared: string[] = [];
  const store: PushTokenStore = {
    getPushEnv: (token) => {
      lookups.push(token);
      if (opts.getThrows) return Promise.reject(new Error("db down"));
      return Promise.resolve(opts.envs?.[token] ?? null);
    },
    clearPushToken: (token) => {
      cleared.push(token);
      if (opts.clearThrows) return Promise.reject(new Error("db down"));
      return Promise.resolve();
    },
  };
  return { store, lookups, cleared };
}

/** console.warn / console.error を捕まえて出力を静かにする */
async function captureConsole<T>(
  fn: () => Promise<T>,
): Promise<{ value: T; logs: string[] }> {
  const logs: string[] = [];
  const origWarn = console.warn;
  const origError = console.error;
  console.warn = (...args: unknown[]) => logs.push(args.map(String).join(" "));
  console.error = (...args: unknown[]) => logs.push(args.map(String).join(" "));
  try {
    return { value: await fn(), logs };
  } finally {
    console.warn = origWarn;
    console.error = origError;
  }
}

Deno.test("TokenAwarePusher: トークンごとに push_env で送信先を選び、未設定は APNS_ENV", async () => {
  const { pem } = await makeTestKey();
  for (const fallback of ["sandbox", "production"] as const) {
    const { calls, post } = mockTransport();
    const { store, lookups } = makeStore({
      envs: { "tok-prod": "production", "tok-sb": "sandbox", "tok-null": null },
    });
    const pusher = new TokenAwarePusher(
      new ApnsClient(makeConfig(pem, fallback), { post }),
      store,
    );

    await pusher.send("tok-prod", {});
    await pusher.send("tok-sb", {});
    await pusher.send("tok-null", {}); // push_env 未設定 → APNS_ENV
    await pusher.send("tok-unknown", {}); // 行が無い → APNS_ENV

    const host = (env: ApnsEnvironment) =>
      env === "production"
        ? "https://api.push.apple.com/3/device/"
        : "https://api.sandbox.push.apple.com/3/device/";
    assertEquals(calls.map((c) => c.url), [
      `${host("production")}tok-prod`,
      `${host("sandbox")}tok-sb`,
      `${host(fallback)}tok-null`,
      `${host(fallback)}tok-unknown`,
    ], `APNS_ENV=${fallback}`);
    assertEquals(lookups, ["tok-prod", "tok-sb", "tok-null", "tok-unknown"]);
  }
});

Deno.test("TokenAwarePusher: opts.environment を渡したら DB を引かず、pushType / priority もそのまま渡す", async () => {
  const { pem } = await makeTestKey();
  const { calls, post } = mockTransport();
  const { store, lookups } = makeStore({ envs: { tok: "sandbox" } });
  const pusher = new TokenAwarePusher(
    new ApnsClient(makeConfig(pem, "sandbox"), { post }),
    store,
  );

  const result = await pusher.send("tok", { aps: {} }, {
    environment: "production",
    pushType: "background",
    priority: 5,
  });

  assertEquals(result, { ok: true, status: 200, attempts: 1 });
  assertEquals(lookups, [], "環境指定があれば DB を引かない");
  assertEquals(calls[0].url, "https://api.push.apple.com/3/device/tok");
  assertEquals(calls[0].headers["apns-push-type"], "background");
  assertEquals(calls[0].headers["apns-priority"], "5");
});

Deno.test("TokenAwarePusher: 410 / BadDeviceToken を受けたトークンだけ push_token を破棄する", async () => {
  const { pem } = await makeTestKey();
  const scenarios: Array<{
    label: string;
    script: Array<ApnsHttpResponse | Error>;
    cleared: boolean;
  }> = [
    {
      label: "410 Unregistered",
      script: [{ status: 410, body: '{"reason":"Unregistered"}' }],
      cleared: true,
    },
    {
      label: "400 BadDeviceToken",
      script: [{ status: 400, body: '{"reason":"BadDeviceToken"}' }],
      cleared: true,
    },
    {
      label: "400 DeviceTokenNotForTopic(設定ミスかもしれないので消さない)",
      script: [{ status: 400, body: '{"reason":"DeviceTokenNotForTopic"}' }],
      cleared: false,
    },
    {
      label: "403 ExpiredProviderToken",
      script: [{ status: 403, body: '{"reason":"ExpiredProviderToken"}' }],
      cleared: false,
    },
    {
      label: "5xx が2回",
      script: [{ status: 500, body: "" }, { status: 500, body: "" }],
      cleared: false,
    },
    {
      label: "送信例外が2回",
      script: [new Error("down"), new Error("down")],
      cleared: false,
    },
    { label: "200 成功", script: [{ status: 200, body: "" }], cleared: false },
  ];
  for (const sc of scenarios) {
    const { post } = mockTransport([...sc.script]);
    const { store, cleared } = makeStore({
      envs: { "token-abcdef123456": "production" },
    });
    const pusher = new TokenAwarePusher(
      new ApnsClient(makeConfig(pem), { post }),
      store,
    );
    const { value: result, logs } = await captureConsole(() =>
      pusher.send("token-abcdef123456", {})
    );

    assertEquals(cleared, sc.cleared ? ["token-abcdef123456"] : [], sc.label);
    assertEquals(result.ok, sc.label === "200 成功", sc.label);
    if (sc.cleared) {
      assertEquals(
        logs.some((l) => l.includes("token-ab")),
        true,
        "ログにはトークンの先頭だけを残す",
      );
      assertEquals(
        logs.some((l) => l.includes("token-abcdef123456")),
        false,
        "トークン全体はログに出さない",
      );
    }
  }
});

Deno.test("TokenAwarePusher: 環境の取得・トークンの破棄に失敗しても throw せず、結果を返す", async () => {
  const { pem } = await makeTestKey();

  // push_env の取得失敗 → APNS_ENV(sandbox)で送る
  const a = mockTransport();
  const getFail = makeStore({ getThrows: true });
  const p1 = new TokenAwarePusher(
    new ApnsClient(makeConfig(pem, "sandbox"), { post: a.post }),
    getFail.store,
  );
  const r1 = await captureConsole(() => p1.send("tok", {}));
  assertEquals(r1.value.ok, true);
  assertEquals(
    a.calls[0].url,
    "https://api.sandbox.push.apple.com/3/device/tok",
  );
  assertEquals(r1.logs.length > 0, true, "失敗はログに残す");

  // 破棄の失敗 → 元の失敗結果をそのまま返す
  const b = mockTransport([{ status: 410, body: '{"reason":"Unregistered"}' }]);
  const clearFail = makeStore({ clearThrows: true });
  const p2 = new TokenAwarePusher(
    new ApnsClient(makeConfig(pem), { post: b.post }),
    clearFail.store,
  );
  const r2 = await captureConsole(() => p2.send("tok", {}));
  assertEquals(r2.value.ok, false);
  assertEquals(clearFail.cleared, ["tok"], "破棄は試みる");
  assertEquals(r2.logs.length > 0, true, "失敗はログに残す");
});
