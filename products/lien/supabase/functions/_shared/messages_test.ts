// messages_test.ts — messages.ts(T04 最小スタブ)の deno test
// 正本: docs/REQUIREMENTS.md §3.5 / §3.12、docs/DESIGN.md §3.8(罰・恥系の文言禁止)

import {
  allMessageBodiesForReview,
  partnerCheckinBody,
  photoAttachedBody,
  pushDisplayName,
} from "./messages.ts";

// ---- 自作 assert ヘルパ(外部モジュールを使わない) ----

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  if (!Object.is(actual, expected)) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${
        JSON.stringify(actual)
      }\n  expected: ${JSON.stringify(expected)}`,
    );
  }
}

function assert(cond: boolean, msg = ""): void {
  if (!cond) throw new Error(`assert failed: ${msg}`);
}

// ---- 罰なし原則(最重要。文言を追加したら必ずここを通す) ----

/** 罰・恥・煽り系の禁止ワード(REQUIREMENTS §3.5 / DESIGN §3.8。T16 で拡充) */
const BANNED_PATTERN = /枯れ|サボ|罰|恥|ダメ|怒|遅い|まだやってない/;

Deno.test("全文言: 罰・恥系の表現を含まない", () => {
  for (const body of allMessageBodiesForReview()) {
    assert(
      !BANNED_PATTERN.test(body),
      `禁止ワードを含む文言: ${body}`,
    );
    assert(body.trim().length > 0, "空文言は不可");
  }
});

// ---- partner_checkin ----

Deno.test("partnerCheckinBody: 約束タイトル+絵文字入りの文言(§3.12 の例の形)", () => {
  const body = partnerCheckinBody(
    { promiseTitle: "ランニング", promiseEmoji: "🏃" },
    () => 0,
  );
  assertEquals(body, "ランニングやった!🏃");
});

Deno.test("partnerCheckinBody: 絵文字未設定ならフォールバック絵文字", () => {
  const body = partnerCheckinBody(
    { promiseTitle: "筋トレ", promiseEmoji: "" },
    () => 0,
  );
  assertEquals(body, "筋トレやった!🔥");
});

Deno.test("partnerCheckinBody: タイトルが無くても汎用文言で成立する", () => {
  const body = partnerCheckinBody({}, () => 0);
  assertEquals(body, "今日のぶん、やったよ!");
});

Deno.test("partnerCheckinBody: random 注入で決定論的に選べる(境界値でも範囲内)", () => {
  const first = partnerCheckinBody(
    { promiseTitle: "ランニング", promiseEmoji: "🏃" },
    () => 0,
  );
  const last = partnerCheckinBody(
    { promiseTitle: "ランニング", promiseEmoji: "🏃" },
    () => 0.999999,
  );
  assert(first.length > 0 && last.length > 0);
  // random が 1 を返す異常系でも範囲外アクセスしない
  const clamped = partnerCheckinBody({ promiseTitle: "x" }, () => 1);
  assert(clamped.length > 0);
});

// ---- その他 ----

Deno.test("photoAttachedBody: 写真添付の文言", () => {
  assertEquals(photoAttachedBody(), "今日の写真を添えたよ📷");
});

Deno.test("pushDisplayName: ニックネーム未設定でも空タイトルにしない", () => {
  assertEquals(pushDisplayName("ゆうき"), "ゆうき");
  assertEquals(pushDisplayName("  ゆうき  "), "ゆうき");
  assertEquals(pushDisplayName(""), "パートナー");
  assertEquals(pushDisplayName("   "), "パートナー");
});
