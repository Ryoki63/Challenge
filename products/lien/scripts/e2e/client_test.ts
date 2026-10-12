// client_test.ts — client.ts のうち、ネットワークなしで確かめられる部分の deno test(fetch は差し替える。本番には出ない)
//
//   deno test --allow-read products/lien/scripts/e2e/

import { Api } from "./client.ts";
import { E2E_META_KEY } from "./marker.ts";
import { assertEquals } from "./test_util.ts";

Deno.test("signup は data に通しテストの印(lien_e2e = true)だけを入れる(後片付けの安全装置の目印)", async () => {
  const realFetch = globalThis.fetch;
  const seen: Array<{ method: string; url: string; body: string }> = [];
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    seen.push({
      method: init?.method ?? "GET",
      url: String(input),
      body: String(init?.body ?? ""),
    });
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as typeof fetch;
  try {
    await new Api("https://example.invalid", "dummy-key").signup();
  } finally {
    globalThis.fetch = realFetch;
  }
  assertEquals(seen.length, 1);
  assertEquals(seen[0].method, "POST");
  assertEquals(seen[0].url, "https://example.invalid/auth/v1/signup");
  assertEquals(JSON.parse(seen[0].body), { data: { [E2E_META_KEY]: true } });
  assertEquals(E2E_META_KEY, "lien_e2e");
});
