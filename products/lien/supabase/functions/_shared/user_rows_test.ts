// user_rows_test.ts — _shared/user_rows.ts の deno test(DB 不要)
// 正本: docs/DESIGN.md §4.1(APNs の環境はトークン単位)/ issue #60 項目7

import {
  PARTNER_SELECT,
  toSnapshotUser,
  USER_COLUMNS,
  type UserDbRow,
} from "./user_rows.ts";

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

function columnsOf(select: string): string[] {
  return select.split(",").map((c) => c.trim());
}

Deno.test("USER_COLUMNS: push_token と push_env を必ず一緒に読む(送信のたびの逆引きをしないため)", () => {
  const columns = columnsOf(USER_COLUMNS);
  assert(columns.includes("push_token"), "push_token を読む");
  assert(columns.includes("push_env"), "push_env を読む");
  assertEquals(columns, [
    "id",
    "nickname",
    "timezone",
    "push_token",
    "push_env",
  ]);
});

Deno.test("PARTNER_SELECT: 相手の users も push_token と push_env を一緒に読む(列は USER_COLUMNS と同じ)", () => {
  const m = /^user_id, users!inner\((.+)\)$/.exec(PARTNER_SELECT);
  assert(!!m, `形が想定と違う: ${PARTNER_SELECT}`);
  assertEquals(columnsOf(m![1]), columnsOf(USER_COLUMNS));
});

Deno.test("toSnapshotUser: DB の行 → SnapshotUserRow(push_token と push_env を持ち出す)", () => {
  const row: UserDbRow = {
    id: "user-a",
    nickname: "あきら",
    timezone: "Asia/Tokyo",
    push_token: "token-a",
    push_env: "production",
  };
  assertEquals(toSnapshotUser(row), {
    id: "user-a",
    nickname: "あきら",
    timezone: "Asia/Tokyo",
    pushToken: "token-a",
    pushEnv: "production",
  });
  assertEquals(
    toSnapshotUser({ ...row, push_env: "sandbox" }).pushEnv,
    "sandbox",
  );
});

Deno.test("toSnapshotUser: null は既定値に、想定外の push_env は null(= APNS_ENV にフォールバック)", () => {
  assertEquals(
    toSnapshotUser({
      id: "u",
      nickname: null,
      timezone: null,
      push_token: null,
      push_env: null,
    }),
    {
      id: "u",
      nickname: "",
      timezone: "Asia/Tokyo",
      pushToken: null,
      pushEnv: null,
    },
  );
  for (const bad of ["", "prod", "Production", "staging"]) {
    const row: UserDbRow = {
      id: "u",
      nickname: "a",
      timezone: "Asia/Tokyo",
      push_token: "t",
      push_env: bad,
    };
    assertEquals(toSnapshotUser(row).pushEnv, null, `push_env=${bad}`);
  }
});
