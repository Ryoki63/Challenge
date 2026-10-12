// report_test.ts — report.ts(結果の記録と、終了コードを決める判定)の deno test。ネットワーク・本番は使わない
//
//   deno test --allow-read products/lien/scripts/e2e/
//
// 見るもの: 契約フィクスチャとのずれが 1 件でもあれば、FAIL が 0 件でも「問題あり」(終了コード 1)になること。
// 以前は、署名の発行の失敗のずれが「ずれ 1 件」と出ているのに「結果: PASS」(終了コード 0)になっていた。

import { Reporter } from "./report.ts";
import { schemaFrom } from "./shape.ts";
import { assertEquals } from "./test_util.ts";

function reporter(): { rep: Reporter; lines: string[] } {
  const lines: string[] = [];
  return { rep: new Reporter((l) => lines.push(l), false), lines };
}

Deno.test("PASS だけなら問題なし", () => {
  const { rep } = reporter();
  rep.begin("S00", "試験");
  rep.pass("ok");
  rep.note("観測");
  rep.skip("省略");
  assertEquals(rep.hasProblems, false);
  assertEquals(rep.failed, 0);
});

Deno.test("FAIL が 1 件でもあれば問題あり", () => {
  const { rep } = reporter();
  rep.begin("S00", "試験");
  rep.check("x", false, "detail");
  assertEquals(rep.failed, 1);
  assertEquals(rep.hasProblems, true);
});

Deno.test("契約とのずれが単独で 1 件でもあれば、FAIL が 0 件でも問題あり(PASS のまま終わらない)", () => {
  const { rep, lines } = reporter();
  rep.begin("S12", "試験");
  rep.pass("ok");
  rep.deviation("署名の発行の失敗が契約と違う");
  assertEquals(rep.failed, 0);
  assertEquals(rep.deviations.length, 1);
  assertEquals(rep.hasProblems, true);
  // 集計に「ずれ 1 件」と、ずれの一覧が出る
  const summary = rep.summaryLines();
  assertEquals(summary.some((l) => l.includes("ずれ 1 件")), true);
  assertEquals(
    summary.some((l) => l.includes("署名の発行の失敗が契約と違う")),
    true,
  );
  assertEquals(lines.length > 0, true);
});

Deno.test("shape / values のずれは、FAIL とずれの両方に積まれる", () => {
  const { rep } = reporter();
  rep.begin("S00", "試験");
  const schema = schemaFrom({ a: 1, b: "x" });
  assertEquals(rep.shape("形", { a: 1, b: 2 }, schema), false);
  assertEquals(rep.failed, 1);
  assertEquals(rep.deviations.length, 1);
  assertEquals(rep.hasProblems, true);
  assertEquals(rep.shape("形(正しい)", { a: 2, b: "y" }, schema), true);
  assertEquals(rep.failed, 1);
});

Deno.test("鍵・JWT の形をしたものは表示の前に伏せる", () => {
  const { rep, lines } = reporter();
  rep.begin("S00", "試験");
  rep.fail(
    "x",
    "sb_secret_x と eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.c2lnbmF0dXJl",
  );
  const text = lines.join("\n");
  assertEquals(text.includes("sb_secret_x"), false);
  assertEquals(text.includes("eyJhbGciOiJIUzI1NiJ9"), false);
  assertEquals(text.includes("<redacted>"), true);
});
