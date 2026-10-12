// pusher_test.ts — pusher.ts の deno test(DB・APNs はモック。ネットワーク・実キー不要)
// 正本: docs/DESIGN.md §4(APNs の環境はトークン単位・無効トークンの掃除)/ §5.5 / §7

import {
  type ApnsHttpPost,
  type ApnsHttpResponse,
  sendOptionsFor,
} from "./apns.ts";
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

// ---- 偽の supabase クライアント(使う部分だけ。DB に触るのは無効トークンの掃除の update だけ)----

interface DbCall {
  table: string;
  op: "select" | "update";
  arg: unknown;
  filters: Array<[string, unknown]>;
}

function fakeDb(responses: { update?: { error: unknown } } = {}): {
  db: PushStoreDb;
  calls: DbCall[];
} {
  const calls: DbCall[] = [];
  const db: PushStoreDb = {
    from(table: string) {
      return {
        // 送信のたびの push_token からの逆引き(select)は無くなった。呼ばれたら検出できるよう記録する
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
            limit() {
              return Promise.resolve({ data: [], error: null });
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

Deno.test("makePushTokenStore: 環境を引く口(getPushEnv)は持たない — push_env は呼び出し側が users 行から渡す(issue #60)", () => {
  const store = makePushTokenStore(fakeDb().db) as unknown as Record<
    string,
    unknown
  >;
  assertEquals(Object.keys(store).sort(), ["clearPushToken"]);
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

Deno.test("createPusher: 設定済み — 呼び出し側が渡した environment で送る。渡されなければ APNS_ENV。DB は引かない", async () => {
  const env = await fullEnv("sandbox");
  const { db, calls } = fakeDb();
  const { urls, post } = mockPost();
  const pusher = createPusher(db, "nudge", { getEnv: (k) => env[k], post });

  // 受信者の users.push_env = production(getUser / getActivePair が push_token と一緒に読んだもの)
  const result = await pusher.send(
    "tok-prod",
    { aps: {} },
    sendOptionsFor({ pushEnv: "production" }),
  );
  assertEquals(result.ok, true);
  // push_env が未設定(null)のトークンは APNS_ENV(sandbox)で送る
  await pusher.send("tok-unset", {}, sendOptionsFor({ pushEnv: null }));
  await pusher.send("tok-noopts", {});

  assertEquals(urls, [
    "https://api.push.apple.com/3/device/tok-prod",
    "https://api.sandbox.push.apple.com/3/device/tok-unset",
    "https://api.sandbox.push.apple.com/3/device/tok-noopts",
  ]);
  assertEquals(
    calls,
    [],
    "送信のたびに push_token から users を逆引きしない(全件走査になる)",
  );
});

Deno.test("createPusher: APNs が 410 を返したトークンは users.push_token を null にする", async () => {
  const env = await fullEnv("production");
  const { db, calls } = fakeDb();
  const { post } = mockPost([
    { status: 410, body: '{"reason":"Unregistered"}' },
  ]);
  const pusher = createPusher(db, "react", { getEnv: (k) => env[k], post });

  const result = await quiet(() =>
    pusher.send("tok-dead", {}, sendOptionsFor({ pushEnv: "production" }))
  );

  assertEquals(result.ok, false);
  // DB に触るのは掃除の update だけ(逆引きの select は無い)
  assertEquals(calls, [{
    table: "users",
    op: "update",
    arg: { push_token: null },
    filters: [["push_token", "tok-dead"]],
  }]);
});
