// smoke_test.ts — CI(deno test ジョブ)疎通確認用のプレースホルダテスト。
// T03 で streak.ts / tickets.ts の本実装とそのテストが追加されたら役目を終える(削除可)。
import { assertEquals } from "jsr:@std/assert@1";

Deno.test("smoke: deno test ハーネスが動作する", () => {
  assertEquals(1 + 1, 2);
});
