// partner_lib_test.ts — 審査用デモの相手役(partner)の純粋な部分の単体テスト
//
// ネットワークは使わない(--allow-read も不要)。CI の e2e-tests ジョブで回す。
//   deno test products/lien/scripts/review-demo/
//   deno check products/lien/scripts/review-demo/partner.ts

import {
  assertInviteToken,
  assertLength,
  DEFAULT_EMOJI,
  DEFAULT_PROMISE,
  defaultNickname,
  formatJst,
  graphemeLength,
  INVITE_TOKEN_RE,
  isExpired,
  jstDate,
  NUDGE_STAMPS,
  parseArgs,
  parseState,
  serializeState,
  type SessionState,
  stateDir,
  stateFileName,
  UsageError,
} from "./partner_lib.ts";

// ---- 自作 assert ヘルパ(外部モジュールを使わない) ----

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`assert failed: ${msg}`);
}

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

function assertThrows(fn: () => unknown, includes: string, msg: string): void {
  try {
    fn();
  } catch (e) {
    if (!(e instanceof UsageError)) {
      throw new Error(`${msg}: UsageError ではない: ${String(e)}`);
    }
    if (!e.message.includes(includes)) {
      throw new Error(`${msg}: 文言に「${includes}」が無い: ${e.message}`);
    }
    return;
  }
  throw new Error(`${msg}: 例外が出なかった`);
}

const NOW = new Date("2026-10-20T03:25:00Z"); // 2026-10-20 12:25 JST

// ---- 引数 ----

Deno.test("parseArgs: create の既定値(スロット1)", () => {
  const args = parseArgs(["create"]);
  assertEquals(args.command, "create");
  assertEquals(args.slot, 1);
  assertEquals(args.nickname, defaultNickname(1));
  assertEquals(args.nickname, "レビュー相手1");
  assertEquals(args.promise, DEFAULT_PROMISE);
  assertEquals(args.emoji, DEFAULT_EMOJI);
  assertEquals(args.json, false);
});

Deno.test("parseArgs: 2組目は --slot 2 で別のニックネームになる", () => {
  const args = parseArgs(["create", "--slot", "2"]);
  assertEquals(args.slot, 2);
  assertEquals(args.nickname, "レビュー相手2");
});

Deno.test("parseArgs: ニックネーム・約束・絵文字を指定できる", () => {
  const args = parseArgs([
    "create",
    "--nickname",
    "ゆうき",
    "--promise",
    "ランニング",
    "--emoji",
    "🏃",
    "--json",
  ]);
  assertEquals(args.nickname, "ゆうき");
  assertEquals(args.promise, "ランニング");
  assertEquals(args.emoji, "🏃");
  assertEquals(args.json, true);
});

Deno.test("parseArgs: checkin の写真と nudge のスタンプ", () => {
  const checkin = parseArgs([
    "checkin",
    "--slot",
    "2",
    "--photo",
    "/tmp/a.jpg",
  ]);
  assertEquals(checkin.command, "checkin");
  assertEquals(checkin.slot, 2);
  assertEquals(checkin.photo, "/tmp/a.jpg");

  const nudge = parseArgs(["nudge", "--stamp", "⏰"]);
  assertEquals(nudge.stamp, "⏰");

  // 既定は先頭のスタンプ
  assertEquals(parseArgs(["nudge"]).stamp, NUDGE_STAMPS[0]);
});

Deno.test("parseArgs: 知らないコマンド・オプション・値の欠けは止まる", () => {
  assertThrows(() => parseArgs([]), "コマンドを指定", "コマンドなし");
  assertThrows(
    () => parseArgs(["frobnicate"]),
    "知らないコマンド",
    "知らないコマンド",
  );
  assertThrows(
    () => parseArgs(["status", "--bogus"]),
    "知らないオプション",
    "知らないオプション",
  );
  assertThrows(
    () => parseArgs(["create", "--nickname"]),
    "値がありません",
    "値の欠け",
  );
  assertThrows(
    () => parseArgs(["create", "--nickname", "--json"]),
    "値がありません",
    "次のオプションを値にしない",
  );
  assertThrows(
    () => parseArgs(["create", "--slot", "3"]),
    "--slot は 1 か 2",
    "スロット",
  );
  assertThrows(
    () => parseArgs(["create", "--slot", "x"]),
    "--slot は 1 か 2",
    "スロットの文字",
  );
});

Deno.test("parseArgs: コマンドに合わないオプションは黙って無視しない", () => {
  assertThrows(
    () => parseArgs(["status", "--nickname", "ゆうき"]),
    "--nickname は create",
    "status の nickname",
  );
  assertThrows(
    () => parseArgs(["create", "--photo", "/tmp/a.jpg"]),
    "--photo は checkin",
    "create の photo",
  );
  assertThrows(
    () => parseArgs(["checkin", "--stamp", "👋"]),
    "--stamp は nudge",
    "checkin の stamp",
  );
  assertThrows(
    () => parseArgs(["nudge", "--stamp", "x"]),
    "自由文は送れません",
    "語彙外のスタンプ",
  );
});

Deno.test("parseArgs: 文字数の上限は書記素で数える(アプリと同じ)", () => {
  // 絵文字1つは1文字(コードポイントでは複数)
  const ok = parseArgs(["create", "--nickname", "🌱🌱🌱🌱🌱🌱🌱🌱"]);
  assertEquals(graphemeLength(ok.nickname ?? ""), 8);

  assertThrows(
    () => parseArgs(["create", "--nickname", "123456789"]),
    "ニックネームは8文字まで",
    "9文字",
  );
  assertThrows(
    () => parseArgs(["create", "--promise", "あ".repeat(21)]),
    "約束のタイトルは20文字まで",
    "21文字",
  );
  assertThrows(
    () => parseArgs(["create", "--nickname", "   "]),
    "ニックネームが空",
    "空白だけ",
  );
});

Deno.test("assertLength: 空と上限の境界", () => {
  assertLength("あ".repeat(8), 8, "ニックネーム"); // 例外なし
  assertThrows(() => assertLength("", 8, "ニックネーム"), "空", "空文字");
  assertThrows(
    () => assertLength("あ".repeat(9), 8, "ニックネーム"),
    "9文字",
    "上限超え",
  );
});

Deno.test("graphemeLength: 結合文字・絵文字を1つと数える", () => {
  assertEquals(graphemeLength("abc"), 3);
  assertEquals(graphemeLength("🌱"), 1);
  assertEquals(graphemeLength("が"), 1); // か + 濁点(結合文字)
  assertEquals(graphemeLength("👨‍👩‍👧"), 1); // ZWJ の家族
});

// ---- 日付 ----

Deno.test("jstDate: JST の日付は UTC の前日と一致しないことがある", () => {
  assertEquals(jstDate(new Date("2026-10-19T14:59:00Z")), "2026-10-19");
  assertEquals(jstDate(new Date("2026-10-19T15:00:00Z")), "2026-10-20");
  assertEquals(jstDate(new Date("2026-10-20T14:59:00Z")), "2026-10-20");
  assertEquals(jstDate(new Date("2026-10-20T15:00:00Z")), "2026-10-21");
  assertEquals(jstDate(NOW), "2026-10-20");
});

Deno.test("formatJst: 期限を JST で表示する", () => {
  assertEquals(
    formatJst("2026-10-23T03:25:00.000Z"),
    "2026-10-23 12:25 JST",
  );
  assertThrows(() => formatJst("not a date"), "日時が読めません", "不正な日時");
});

Deno.test("isExpired: 期限ちょうどは失効", () => {
  assertEquals(isExpired("2026-10-23T03:25:00.000Z", NOW), false);
  assertEquals(isExpired("2026-10-20T03:25:00.000Z", NOW), true);
  assertEquals(isExpired("2026-10-20T03:24:59.000Z", NOW), true);
  assertThrows(() => isExpired("x", NOW), "日時が読めません", "不正な期限");
});

// ---- 状態ファイル ----

const STATE: SessionState = {
  version: 1,
  userId: "a1111111-1111-4111-8111-111111111111",
  refreshToken: "refresh-not-printed",
  nickname: "レビュー相手1",
  promise: { title: "まいにち散歩", emoji: "🚶" },
  invite: { token: "AbCd2345", expiresAt: "2026-10-23T03:25:00.000Z" },
  createdAt: "2026-10-20T03:25:00.000Z",
};

Deno.test("stateFileName / stateDir: リポジトリの外に置く", () => {
  assertEquals(stateFileName(1), "partner-1.json");
  assertEquals(stateFileName(2), "partner-2.json");
  assertEquals(stateDir("/Users/me"), "/Users/me/.lien-review-demo");
  assertEquals(stateDir("/Users/me", "/tmp/demo/"), "/tmp/demo");
  assertEquals(stateDir("/Users/me", ""), "/Users/me/.lien-review-demo");
});

Deno.test("parseState / serializeState: 往復して同じになる", () => {
  const text = serializeState(STATE);
  assert(text.endsWith("\n"), "末尾に改行");
  const parsed = parseState(text);
  assertEquals(parsed, STATE);
});

Deno.test("parseState: invite が null でも読める", () => {
  const parsed = parseState(serializeState({ ...STATE, invite: null }));
  assertEquals(parsed.invite, null);
});

Deno.test("parseState: 壊れたファイル・版違い・項目欠けは止まる(秘密は出さない)", () => {
  assertThrows(() => parseState("{"), "JSON として読めません", "壊れた JSON");
  assertThrows(
    () => parseState(JSON.stringify({ ...STATE, version: 2 })),
    "版が違います",
    "版違い",
  );
  assertThrows(
    () => parseState(JSON.stringify({ ...STATE, refreshToken: "" })),
    "refreshToken がありません",
    "空の refreshToken",
  );
  assertThrows(
    () => parseState(JSON.stringify({ ...STATE, promise: null })),
    "promise がありません",
    "promise なし",
  );
  assertThrows(
    () => parseState(JSON.stringify({ ...STATE, invite: { token: "x" } })),
    "invite が壊れています",
    "invite の期限なし",
  );
});

// ---- 招待コード ----

Deno.test("assertInviteToken: サーバーの文字集合(0/O/1/l を除く8文字)", () => {
  assertInviteToken("AbCd2345");
  assertInviteToken("ABCDEFGH");
  assertInviteToken("23456789");

  for (
    const bad of [
      "AbCd234",
      "AbCd23456",
      "AbCd2340",
      "AbCd234O",
      "AbCd2341",
      "AbCd234l",
      "AbCd-345",
    ]
  ) {
    assertThrows(
      () => assertInviteToken(bad),
      "招待コードの形",
      `不正なコード: ${bad}`,
    );
  }
  assertEquals(INVITE_TOKEN_RE.test("AbCd2345"), true);
});
