// core_test.ts — revenuecat-webhook/core.ts の deno test(リポジトリはモック。ネットワーク不要)
// 正本: docs/REQUIREMENTS.md §3.14(RevenueCat Webhook で users.premium_until を更新)/ §5

import {
  handleRevenueCatWebhook,
  isAuthorizedWebhook,
  isSupabaseUserId,
  isWebhookSecretUsable,
  msToIso,
  type RevenueCatEvent,
  type RevenueCatWebhookDeps,
  type RevenueCatWebhookRequest,
} from "./core.ts";

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

function assert(condition: boolean, msg = ""): void {
  if (!condition) throw new Error(`assert failed: ${msg}`);
}

const SECRET = "0123456789abcdef0123456789abcdef"; // 32 文字
const USER_ID = "a1111111-1111-4111-8111-111111111111";
const NOW = new Date("2026-10-20T03:00:00.000Z");
const FUTURE_MS = new Date("2026-11-20T03:00:00.000Z").getTime();
const PAST_MS = new Date("2026-10-01T03:00:00.000Z").getTime();

interface Calls {
  granted: Array<{ userId: string; premiumUntilIso: string }>;
  expired: Array<{ userId: string; expiredAtIso: string }>;
}

function makeDeps(calls: Calls, fail = false): RevenueCatWebhookDeps {
  return {
    now: () => NOW,
    grantPremium: (userId, premiumUntilIso) => {
      if (fail) return Promise.reject(new Error("db down"));
      calls.granted.push({ userId, premiumUntilIso });
      return Promise.resolve();
    },
    expirePremium: (userId, expiredAtIso) => {
      if (fail) return Promise.reject(new Error("db down"));
      calls.expired.push({ userId, expiredAtIso });
      return Promise.resolve();
    },
  };
}

function request(
  event: RevenueCatEvent | undefined,
  overrides: Partial<RevenueCatWebhookRequest> = {},
): RevenueCatWebhookRequest {
  return {
    authorization: SECRET,
    authSecret: SECRET,
    body: event === undefined ? {} : { event },
    ...overrides,
  };
}

// ---- 認証 ----

Deno.test("isWebhookSecretUsable: 未設定・短すぎる秘密は使えない", () => {
  assertEquals(isWebhookSecretUsable(undefined), false);
  assertEquals(isWebhookSecretUsable(""), false);
  assertEquals(isWebhookSecretUsable("a".repeat(31)), false);
  assertEquals(isWebhookSecretUsable("a".repeat(32)), true);
});

Deno.test("isAuthorizedWebhook: 完全一致のときだけ true(Bearer は付けない)", () => {
  assertEquals(isAuthorizedWebhook(SECRET, SECRET), true);
  assertEquals(isAuthorizedWebhook(` ${SECRET} `, SECRET), true, "前後の空白は許す");
  assertEquals(isAuthorizedWebhook(SECRET + "x", SECRET), false);
  assertEquals(isAuthorizedWebhook(`Bearer ${SECRET}`, SECRET), false);
  assertEquals(isAuthorizedWebhook(null, SECRET), false);
  assertEquals(isAuthorizedWebhook("", SECRET), false);
  assertEquals(isAuthorizedWebhook(SECRET, undefined), false, "秘密が未設定なら全拒否");
});

Deno.test("handleRevenueCatWebhook: 認証が違えば 401。リポジトリは呼ばない", async () => {
  const calls: Calls = { granted: [], expired: [] };
  const result = await handleRevenueCatWebhook(makeDeps(calls), request(
    { type: "INITIAL_PURCHASE", app_user_id: USER_ID, expiration_at_ms: FUTURE_MS },
    { authorization: "wrong" },
  ));
  assertEquals(result.status, 401);
  assertEquals(calls, { granted: [], expired: [] });
});

Deno.test("handleRevenueCatWebhook: 秘密が未設定なら、正しい Authorization でも 401", async () => {
  const calls: Calls = { granted: [], expired: [] };
  const result = await handleRevenueCatWebhook(makeDeps(calls), request(
    { type: "INITIAL_PURCHASE", app_user_id: USER_ID, expiration_at_ms: FUTURE_MS },
    { authSecret: undefined },
  ));
  assertEquals(result.status, 401);
  assertEquals(calls.granted.length, 0);
});

// ---- 期限を延ばすイベント ----

Deno.test("handleRevenueCatWebhook: INITIAL_PURCHASE は premium_until を期限へ更新する", async () => {
  const calls: Calls = { granted: [], expired: [] };
  const result = await handleRevenueCatWebhook(makeDeps(calls), request({
    type: "INITIAL_PURCHASE",
    app_user_id: USER_ID,
    expiration_at_ms: FUTURE_MS,
  }));
  assertEquals(result.status, 200);
  assertEquals(calls.granted, [{
    userId: USER_ID,
    premiumUntilIso: new Date(FUTURE_MS).toISOString(),
  }]);
  assertEquals(calls.expired.length, 0);
});

Deno.test("handleRevenueCatWebhook: RENEWAL / UNCANCELLATION / PRODUCT_CHANGE / NON_RENEWING_PURCHASE / SUBSCRIPTION_EXTENDED も同じ", async () => {
  for (
    const type of [
      "RENEWAL",
      "UNCANCELLATION",
      "PRODUCT_CHANGE",
      "NON_RENEWING_PURCHASE",
      "SUBSCRIPTION_EXTENDED",
    ]
  ) {
    const calls: Calls = { granted: [], expired: [] };
    const result = await handleRevenueCatWebhook(makeDeps(calls), request({
      type,
      app_user_id: USER_ID,
      expiration_at_ms: FUTURE_MS,
    }));
    assertEquals(result.status, 200, type);
    assertEquals(calls.granted.length, 1, type);
  }
});

Deno.test("handleRevenueCatWebhook: 期限が既に過去の購入イベントは、期限切れとして扱う(未来を見せない)", async () => {
  const calls: Calls = { granted: [], expired: [] };
  const result = await handleRevenueCatWebhook(makeDeps(calls), request({
    type: "RENEWAL",
    app_user_id: USER_ID,
    expiration_at_ms: PAST_MS,
  }));
  assertEquals(result.status, 200);
  assertEquals(calls.granted.length, 0);
  assertEquals(calls.expired, [{
    userId: USER_ID,
    expiredAtIso: new Date(PAST_MS).toISOString(),
  }]);
});

// ---- 期限切れ・無視するイベント ----

Deno.test("handleRevenueCatWebhook: EXPIRATION はその期限で失効させる(新しい期限は消さない判断は repo 側)", async () => {
  const calls: Calls = { granted: [], expired: [] };
  const result = await handleRevenueCatWebhook(makeDeps(calls), request({
    type: "EXPIRATION",
    app_user_id: USER_ID,
    expiration_at_ms: PAST_MS,
  }));
  assertEquals(result.status, 200);
  assertEquals(calls.granted.length, 0);
  assertEquals(calls.expired, [{
    userId: USER_ID,
    expiredAtIso: new Date(PAST_MS).toISOString(),
  }]);
});

Deno.test("handleRevenueCatWebhook: EXPIRATION に期限が無ければ受信時刻で失効させる", async () => {
  const calls: Calls = { granted: [], expired: [] };
  const result = await handleRevenueCatWebhook(makeDeps(calls), request({
    type: "EXPIRATION",
    app_user_id: USER_ID,
  }));
  assertEquals(result.status, 200);
  assertEquals(calls.expired, [{
    userId: USER_ID,
    expiredAtIso: NOW.toISOString(),
  }]);
});

Deno.test("handleRevenueCatWebhook: CANCELLATION(自動更新の停止)は期限まで有効なので何もしない", async () => {
  const calls: Calls = { granted: [], expired: [] };
  const result = await handleRevenueCatWebhook(makeDeps(calls), request({
    type: "CANCELLATION",
    app_user_id: USER_ID,
    expiration_at_ms: FUTURE_MS,
  }));
  assertEquals(result.status, 200);
  assertEquals(calls, { granted: [], expired: [] });
});

Deno.test("handleRevenueCatWebhook: TEST・未知の種別・Supabase 以外のユーザーは 200 で無視する", async () => {
  for (
    const event of [
      { type: "TEST", app_user_id: USER_ID },
      { type: "FUTURE_EVENT_TYPE", app_user_id: USER_ID },
      { type: "INITIAL_PURCHASE", app_user_id: "$RCAnonymousID:abc", expiration_at_ms: FUTURE_MS },
      { type: "INITIAL_PURCHASE", expiration_at_ms: FUTURE_MS },
    ]
  ) {
    const calls: Calls = { granted: [], expired: [] };
    const result = await handleRevenueCatWebhook(makeDeps(calls), request(event));
    assertEquals(result.status, 200, JSON.stringify(event));
    assertEquals(calls, { granted: [], expired: [] }, JSON.stringify(event));
  }
});

// ---- 不正な本文・失敗 ----

Deno.test("handleRevenueCatWebhook: event が無い・type が無い・期限が無い購入は 400", async () => {
  const calls: Calls = { granted: [], expired: [] };
  assertEquals(
    (await handleRevenueCatWebhook(makeDeps(calls), request(undefined))).status,
    400,
  );
  assertEquals(
    (await handleRevenueCatWebhook(makeDeps(calls), request({ app_user_id: USER_ID })))
      .status,
    400,
  );
  assertEquals(
    (await handleRevenueCatWebhook(makeDeps(calls), request({
      type: "INITIAL_PURCHASE",
      app_user_id: USER_ID,
    }))).status,
    400,
  );
  assertEquals(calls, { granted: [], expired: [] });
});

Deno.test("handleRevenueCatWebhook: リポジトリの失敗は 500(RevenueCat に再送させる)", async () => {
  const calls: Calls = { granted: [], expired: [] };
  const grant = await handleRevenueCatWebhook(makeDeps(calls, true), request({
    type: "INITIAL_PURCHASE",
    app_user_id: USER_ID,
    expiration_at_ms: FUTURE_MS,
  }));
  assertEquals(grant.status, 500);
  const expire = await handleRevenueCatWebhook(makeDeps(calls, true), request({
    type: "EXPIRATION",
    app_user_id: USER_ID,
    expiration_at_ms: PAST_MS,
  }));
  assertEquals(expire.status, 500);
});

// ---- 小さなヘルパ ----

Deno.test("msToIso / isSupabaseUserId: 型と形式を検証する", () => {
  assertEquals(msToIso(FUTURE_MS), new Date(FUTURE_MS).toISOString());
  assertEquals(msToIso("123"), null);
  assertEquals(msToIso(Number.NaN), null);
  assertEquals(msToIso(Number.POSITIVE_INFINITY), null);
  assert(isSupabaseUserId(USER_ID));
  assertEquals(isSupabaseUserId("not-a-uuid"), false);
  assertEquals(isSupabaseUserId(null), false);
});
