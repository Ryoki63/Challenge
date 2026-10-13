// auth_errors_test.ts — _shared/auth_errors.ts の deno test(ネットワーク不要)

import { isAuthServiceUnavailable } from "./auth_errors.ts";

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  if (!Object.is(actual, expected)) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${
        JSON.stringify(actual)
      }\n  expected: ${JSON.stringify(expected)}`,
    );
  }
}

Deno.test("isAuthServiceUnavailable: 通信の失敗・認証サーバーの不調は true(503 にする)", () => {
  // fetch が失敗した(AuthRetryableFetchError。status 0)
  assertEquals(
    isAuthServiceUnavailable({ name: "AuthRetryableFetchError", status: 0 }),
    true,
  );
  // 502 / 503 / 504 も AuthRetryableFetchError
  for (const status of [502, 503, 504]) {
    assertEquals(
      isAuthServiceUnavailable({ name: "AuthRetryableFetchError", status }),
      true,
      String(status),
    );
  }
  // 認証サーバーが 500 を JSON で返した(AuthApiError)
  assertEquals(
    isAuthServiceUnavailable({ name: "AuthApiError", status: 500 }),
    true,
  );
  // 応答が JSON で読めなかった(ゲートウェイの HTML など。status が付かない)
  assertEquals(isAuthServiceUnavailable({ name: "AuthUnknownError" }), true);
  // 名前が無くても status で判断できる
  assertEquals(isAuthServiceUnavailable({ status: 503 }), true);
  assertEquals(isAuthServiceUnavailable({ status: 0 }), true);
});

Deno.test("isAuthServiceUnavailable: 確定した拒否(4xx)・判断できないものは false(401 のまま)", () => {
  // 期限切れ・署名の不正・ユーザーが居ない
  for (const status of [400, 401, 403, 404, 422, 429]) {
    assertEquals(
      isAuthServiceUnavailable({ name: "AuthApiError", status }),
      false,
      String(status),
    );
  }
  // JWT が空(AuthSessionMissingError。status 400)
  assertEquals(
    isAuthServiceUnavailable({ name: "AuthSessionMissingError", status: 400 }),
    false,
  );
  // 判断できない(名前も status も無い)エラーは、これまでどおり確定した拒否
  assertEquals(isAuthServiceUnavailable({}), false);
  assertEquals(isAuthServiceUnavailable(null), false);
  assertEquals(isAuthServiceUnavailable(undefined), false);
});
