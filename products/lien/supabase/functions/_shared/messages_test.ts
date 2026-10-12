// messages_test.ts — messages.ts の deno test(T15 で nudge/reply/reaction 分を追加)
// 正本: docs/REQUIREMENTS.md §3.5 / §3.7 / §3.8 / §3.12、docs/DESIGN.md §3.8(罰・恥系の文言禁止)

import {
  allMessageBodiesForReview,
  NUDGE_REPLIES,
  NUDGE_STAMPS,
  nudgeBody,
  partnerCheckinBody,
  photoAttachedBody,
  pushDisplayName,
  REACTION_STAMPS,
  reactionBody,
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

// ---- T15: nudge(つつく) ----

Deno.test("NUDGE_STAMPS: 6種(REQUIREMENTS §3.7)", () => {
  assertEquals(NUDGE_STAMPS.length, 6);
  // 重複が無いこと(語彙検証の前提)
  assertEquals(new Set(NUDGE_STAMPS).size, 6);
});

Deno.test("NUDGE_REPLIES: 定型4種(自由入力は入れない方針 — §3.7)", () => {
  assertEquals(NUDGE_REPLIES.length, 4);
  assert(NUDGE_REPLIES.includes("今やる!"));
  assert(NUDGE_REPLIES.includes("ごめん寝てた"));
});

Deno.test("nudgeBody: 定型文は約20種(REQUIREMENTS §3.7「20種程度」)", () => {
  const seen = new Set<string>();
  for (let i = 0; i < 20; i++) {
    const r = i / 20;
    seen.add(nudgeBody("👋", () => r));
  }
  assert(
    seen.size >= 18,
    `定型文の種類が少なすぎる(20種程度のはずが ${seen.size} 種)`,
  );
});

Deno.test("nudgeBody: スタンプを本文に埋め込む(通知UIで絵文字が欠けても意味が残る)", () => {
  const body = nudgeBody("⏰", () => 0);
  assert(body.includes("⏰"), `スタンプが本文に含まれない: ${body}`);
});

Deno.test("nudgeBody: random 注入で決定論的(境界値でも範囲外アクセスしない)", () => {
  const first = nudgeBody("👋", () => 0);
  const last = nudgeBody("👋", () => 0.999999);
  assert(first.length > 0 && last.length > 0);
  // random が 1 を返す異常系でも範囲外アクセスしない
  const clamped = nudgeBody("👋", () => 1);
  assert(clamped.length > 0);
});

Deno.test("nudgeBody: 既定の random(未注入)でも例外にならない", () => {
  const body = nudgeBody("👋");
  assert(body.length > 0);
});

// ---- T15: reaction(リアクション) ----

Deno.test("REACTION_STAMPS: 6種(❤️🔥👏😂🥹💪 — REQUIREMENTS §3.8)", () => {
  assertEquals(REACTION_STAMPS.length, 6);
  assertEquals(REACTION_STAMPS.join(","), "❤️,🔥,👏,😂,🥹,💪");
});

Deno.test("reactionBody: スタンプを本文に反映する", () => {
  assertEquals(reactionBody("❤️"), "❤️ した");
  assertEquals(reactionBody("🔥"), "🔥 した");
});

Deno.test("reactionBody: REACTION_STAMPS 全種で空文言にならない", () => {
  for (const stamp of REACTION_STAMPS) {
    const body = reactionBody(stamp);
    assert(body.trim().length > 0);
    assert(body.includes(stamp));
  }
});

// ---- allMessageBodiesForReview に nudge/reaction が登録されていること ----

Deno.test("allMessageBodiesForReview: nudge/reaction の文言も罰なしチェックの対象になる", () => {
  const all = allMessageBodiesForReview();
  // reactionBody は全スタンプで含まれているはず
  for (const stamp of REACTION_STAMPS) {
    assert(
      all.includes(reactionBody(stamp)),
      `reactionBody(${stamp}) が allMessageBodiesForReview に含まれない`,
    );
  }
  // NUDGE_REPLIES も含まれているはず
  for (const reply of NUDGE_REPLIES) {
    assert(
      all.includes(reply),
      `返事定型文 "${reply}" が allMessageBodiesForReview に含まれない`,
    );
  }
  // nudgeBody の候補が少なくとも1件含まれていること(全スタンプ×全文で網羅されている)
  const anyNudge = nudgeBody(NUDGE_STAMPS[0], () => 0);
  assert(
    all.includes(anyNudge),
    `nudgeBody の文言例が allMessageBodiesForReview に含まれない: ${anyNudge}`,
  );
});
