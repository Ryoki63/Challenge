// pusher_test.ts — pusher.ts の deno test(DB・APNs はモック。ネットワーク・実キー不要)
// 正本: docs/DESIGN.md §4(APNs の環境はトークン単位・無効トークンの掃除)/ §5.5 / §7

import type { ApnsHttpPost, ApnsHttpResponse } from "./apns.ts";
import {
  createPusher,
  makePushTokenStore,
  type PushStoreDb,
} from "./pusher.ts";

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

async function assertRejects(fn: () => Promise<unknown>, msg = "") {
  let threw = false;
  try {
    await fn();
  } catch {
    threw = true;
  }
  if (!threw) {
    throw new Error(`assertRejects failed: 例外が発生しなかった ${msg}`);
  }
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

// ---- 偽の supabase クライアント(使う部分だけ)----

interface DbCall {
  table: string;
  op: "select" | "update";
  arg: unknown;
  filters: Array<[string, unknown]>;
  limit?: number;
}

interface DbResponses {
  select?: { data: Array<{ push_env: string | null }> | null; error: unknown };
  update?: { error: unknown };
}

function fakeDb(responses: DbResponses = {}): {
  db: PushStoreDb;
  calls: DbCall[];
} {
  const calls: DbCall[] = [];
  const db: PushStoreDb = {
    from(table: string) {
      return {
        select(columns: string) {
          const call: DbCall = {
            table,
            op: "select",
            arg: columns,
            filters: [],
          };
          calls.push(call);
          const chain = {
            eq(column: string, value: unknown) {
              call.filters.push([column, value]);
              return chain;
            },
            limit(count: number) {
              call.limit = count;
              return Promise.resolve(
                responses.select ?? { data: [], error: null },
              );
            },
          };
          return chain;
        },
        update(values: unknown) {
          const call: DbCall = {
            table,
            op: "update",
            arg: values,
            filters: [],
          };
          calls.push(call);
          return {
            eq(column: string, value: unknown) {
              call.filters.push([column, value]);
              return Promise.resolve(responses.update ?? { error: null });
            },
          };
        },
      };
    },
  };
  return { db, calls };
}

// ---- makePushTokenStore ----

Deno.test("makePushTokenStore.getPushEnv: users.push_token = token の push_env を引く", async () => {
  for (const env of ["sandbox", "production"] as const) {
    const { db, calls } = fakeDb({
      select: { data: [{ push_env: env }], error: null },
    });
    const result = await makePushTokenStore(db).getPushEnv("tok-1");
    assertEquals(result, env);
    assertEquals(calls, [{
      table: "users",
      op: "select",
      arg: "push_env",
      filters: [["push_token", "tok-1"]],
      limit: 1,
    }]);
  }
});

Deno.test("makePushTokenStore.getPushEnv: 行なし・未設定・不正な値は null(= APNS_ENV にフォールバック)", async () => {
  const cases: Array<
    { data: Array<{ push_env: string | null }> | null; label: string }
  > = [
    { data: [], label: "行なし" },
    { data: null, label: "data が null" },
    { data: [{ push_env: null }], label: "未設定" },
    { data: [{ push_env: "staging" }], label: "不正な値" },
    { data: [{ push_env: "" }], label: "空文字" },
  ];
  for (const c of cases) {
    const { db } = fakeDb({ select: { data: c.data, error: null } });
    assertEquals(await makePushTokenStore(db).getPushEnv("tok"), null, c.label);
  }
});

Deno.test("makePushTokenStore.getPushEnv: DB エラーは throw(呼び出し側 TokenAwarePusher が握る)", async () => {
  const { db } = fakeDb({ select: { data: null, error: new Error("boom") } });
  await assertRejects(() => makePushTokenStore(db).getPushEnv("tok"));
});

Deno.test("makePushTokenStore.clearPushToken: push_token を null にする(条件は push_token = そのトークン)", async () => {
  const { db, calls } = fakeDb();
  await makePushTokenStore(db).clearPushToken("tok-9");
  assertEquals(calls, [{
    table: "users",
    op: "update",
    arg: { push_token: null },
    filters: [["push_token", "tok-9"]],
  }]);

  const failing = fakeDb({ update: { error: new Error("boom") } });
  await assertRejects(() => makePushTokenStore(failing.db).clearPushToken("t"));
});

// ---- createPusher ----

/** P-256 鍵ペアを生成し、秘密鍵を .p8 相当の PEM にして返す */
async function makeTestPem(): Promise<string> {
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
  const lines = btoa(bin).match(/.{1,64}/g) ?? [];
  return `-----BEGIN PRIVATE KEY-----\n${
    lines.join("\n")
  }\n-----END PRIVATE KEY-----\n`;
}

async function fullEnv(apnsEnv = "sandbox"): Promise<Record<string, string>> {
  return {
    APNS_AUTH_KEY: await makeTestPem(),
    APNS_KEY_ID: "KEY1234567",
    APPLE_TEAM_ID: "TEAM123456",
    APNS_ENV: apnsEnv,
    APNS_TOPIC: "com.example.lien",
  };
}

function mockPost(script: ApnsHttpResponse[] = []): {
  urls: string[];
  post: ApnsHttpPost;
} {
  const urls: string[] = [];
  const post: ApnsHttpPost = (url) => {
    urls.push(url);
    return Promise.resolve(script.shift() ?? { status: 200, body: "" });
  };
  return { urls, post };
}

async function quiet<T>(fn: () => Promise<T>): Promise<T> {
  const warn = console.warn;
  const error = console.error;
  console.warn = () => {};
  console.error = () => {};
  try {
    return await fn();
  } finally {
    console.warn = warn;
    console.error = error;
  }
}

Deno.test("createPusher: APNs の環境変数が欠けていたら push をスキップする no-op(DB も APNs も触らない)", async () => {
  const env = await fullEnv();
  for (const missing of Object.keys(env)) {
    const { db, calls } = fakeDb();
    const { urls, post } = mockPost();
    const pusher = createPusher(db, "checkin", {
      getEnv: (k) => k === missing ? undefined : env[k],
      post,
    });
    const result = await quiet(() => pusher.send("tok", {}));
    assertEquals(result, { ok: false }, `${missing} 欠落`);
    assertEquals(calls, [], "DB を引かない");
    assertEquals(urls, [], "APNs へ送らない");
  }
});

Deno.test("createPusher: APNS_ENV が不正値なら throw(設定ミスは起動時に大声で)", async () => {
  const env = await fullEnv("prod");
  assertThrows(() =>
    createPusher(fakeDb().db, "checkin", { getEnv: (k) => env[k] })
  );
});

Deno.test("createPusher: 設定済み — users.push_env でトークンごとに送信先を選ぶ(APNS_ENV はフォールバック)", async () => {
  const env = await fullEnv("sandbox");
  const { db, calls } = fakeDb({
    select: { data: [{ push_env: "production" }], error: null },
  });
  const { urls, post } = mockPost();
  const pusher = createPusher(db, "nudge", { getEnv: (k) => env[k], post });

  const result = await pusher.send("tok-prod", { aps: {} });

  assertEquals(result.ok, true);
  assertEquals(urls, ["https://api.push.apple.com/3/device/tok-prod"]);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].filters, [["push_token", "tok-prod"]]);

  // push_env が未設定のトークンは APNS_ENV(sandbox)で送る
  const unset = fakeDb({ select: { data: [{ push_env: null }], error: null } });
  const second = mockPost();
  const p2 = createPusher(unset.db, "nudge", {
    getEnv: (k) => env[k],
    post: second.post,
  });
  await p2.send("tok-unset", {});
  assertEquals(second.urls, [
    "https://api.sandbox.push.apple.com/3/device/tok-unset",
  ]);
});

Deno.test("createPusher: APNs が 410 を返したトークンは users.push_token を null にする", async () => {
  const env = await fullEnv("production");
  const { db, calls } = fakeDb({
    select: { data: [{ push_env: "production" }], error: null },
  });
  const { post } = mockPost([
    { status: 410, body: '{"reason":"Unregistered"}' },
  ]);
  const pusher = createPusher(db, "react", { getEnv: (k) => env[k], post });

  const result = await quiet(() => pusher.send("tok-dead", {}));

  assertEquals(result.ok, false);
  const update = calls.find((c) => c.op === "update");
  assertEquals(update, {
    table: "users",
    op: "update",
    arg: { push_token: null },
    filters: [["push_token", "tok-dead"]],
  });
});
