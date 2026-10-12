// e2e_test.ts — e2e.ts の引数の解釈と、run の前提の確認の deno test。ネットワーク・本番は使わない
//
//   deno test --allow-read products/lien/scripts/e2e/
//
// 見るもの: `--user=`(空の値)が黙って「直近の状態ファイルの削除」に切り替わらないこと・--user と --state の同時指定を断ること・
// `run --cleanup` を Management API のトークン無しで流すと、本番に何かを作る前に止まること・実行制限の時間帯。

import {
  checkRunPrerequisites,
  inQuietWindow,
  parseArgs,
  UsageError,
} from "./e2e.ts";
import { assertEquals, assertThrows } from "./test_util.ts";

const ID1 = "11111111-1111-4111-8111-111111111111";
const ID2 = "22222222-2222-4222-8222-222222222222";

function assertUsageError(argv: string[], includes: string): void {
  try {
    parseArgs(argv);
  } catch (e) {
    assertEquals(
      e instanceof UsageError,
      true,
      `${argv.join(" ")} は UsageError`,
    );
    const text = e instanceof Error ? e.message : String(e);
    assertEquals(
      text.includes(includes),
      true,
      `「${includes}」が無い: ${text}`,
    );
    return;
  }
  throw new Error(`例外が出なかった: ${argv.join(" ")}`);
}

Deno.test("--user の値が空・空白・カンマだけのときは、使い方の誤りとして止める(直近の状態ファイルへ切り替えない)", () => {
  for (
    const argv of [
      ["cleanup", "--user="],
      ["cleanup", "--user", ""],
      ["cleanup", "--user", "  "],
      ["cleanup", "--user=,"],
      ["cleanup", "--user", ", ,"],
      ["cleanup", "--dry-run", "--user="],
    ]
  ) {
    assertUsageError(argv, "UUID が要る");
  }
  // 値そのものが無い
  assertUsageError(["cleanup", "--user"], "値が要る");
});

Deno.test("--user は UUID を小文字にそろえ、複数回・カンマ区切りで足せる", () => {
  const a = parseArgs([
    "cleanup",
    `--user=${ID1.toUpperCase()}`,
    "--user",
    `${ID2}, ${ID1}`,
  ]);
  assertEquals(a.cmd, "cleanup");
  assertEquals(a.userIds, [ID1, ID2, ID1]);
  assertEquals(a.stateFile, null);
});

Deno.test("--user と --state は同時に指定できない・--state の値が空も止める", () => {
  assertUsageError(
    ["cleanup", "--user", ID1, "--state", "/tmp/x.json"],
    "同時に指定できない",
  );
  assertUsageError(
    ["cleanup", "--state=/tmp/x.json", `--user=${ID1}`],
    "同時に指定できない",
  );
  assertUsageError(["cleanup", "--state="], "パスが要る");
  assertUsageError(["cleanup", "--state", " "], "パスが要る");
  assertEquals(
    parseArgs(["cleanup", "--state", "/tmp/x.json"]).stateFile,
    "/tmp/x.json",
  );
});

Deno.test("--user も --state も無い cleanup は、直近の状態ファイルを使う指定のまま(userIds が空)", () => {
  const a = parseArgs(["cleanup", "--dry-run"]);
  assertEquals(a.userIds, []);
  assertEquals(a.stateFile, null);
  assertEquals(a.dryRun, true);
});

Deno.test("コマンド・オプションの既定と誤り", () => {
  assertEquals(parseArgs([]).cmd, "run");
  assertEquals(parseArgs(["run", "--cleanup"]).cleanupAfter, true);
  assertEquals(parseArgs(["run", "--no-outsider"]).outsider, false);
  assertEquals(parseArgs(["-h"]).cmd, "help");
  assertUsageError(["nope"], "知らないコマンド");
  assertUsageError(["run", "--nope"], "知らないオプション");
});

Deno.test("run --cleanup は、Management API のトークンが無ければ、何も作る前に止まる", () => {
  // トークン無し・公開キーだけ: run はできるが、--cleanup は後片付けできないので止める
  assertThrows(
    () =>
      checkRunPrerequisites(
        { cleanupAfter: true },
        { accessToken: false, anonKey: true },
      ),
    "SUPABASE_ACCESS_TOKEN",
  );
  // --cleanup なしなら、公開キーだけでも流せる
  checkRunPrerequisites(
    { cleanupAfter: false },
    { accessToken: false, anonKey: true },
  );
  // トークンがあれば --cleanup もよい
  checkRunPrerequisites(
    { cleanupAfter: true },
    { accessToken: true, anonKey: false },
  );
  checkRunPrerequisites(
    { cleanupAfter: true },
    { accessToken: true, anonKey: true },
  );
  // どちらも無い
  assertThrows(
    () =>
      checkRunPrerequisites(
        { cleanupAfter: false },
        { accessToken: false, anonKey: false },
      ),
    "SUPABASE_ACCESS_TOKEN か SUPABASE_ANON_KEY",
  );
  // 止めるのは UsageError(終了コード 2)
  try {
    checkRunPrerequisites(
      { cleanupAfter: true },
      { accessToken: false, anonKey: true },
    );
  } catch (e) {
    assertEquals(e instanceof UsageError, true);
  }
});

Deno.test("実行制限の時間帯: JST 23:50〜00:14 は動かさない", () => {
  assertEquals(inQuietWindow(23, 49), false);
  assertEquals(inQuietWindow(23, 50), true);
  assertEquals(inQuietWindow(23, 59), true);
  assertEquals(inQuietWindow(0, 0), true);
  assertEquals(inQuietWindow(0, 14), true);
  assertEquals(inQuietWindow(0, 15), false);
  assertEquals(inQuietWindow(5, 30), false);
});
