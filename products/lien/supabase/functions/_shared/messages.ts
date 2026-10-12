// _shared/messages.ts — プッシュ通知文言(語彙の正本)
//
// ※ T04 時点の最小スタブに、T15 で nudge(つつく)/ reply(ワンタップ返事)/
//    reaction(リアクション)の語彙を追加した。残り(streak_risk / milestone /
//    全体レビュー)は T16 の担当(issue #16 にその旨をコメント済み)。
//
// 原則(DESIGN §3.8 / REQUIREMENTS §3.5):
//   - ユーザー向け文言はこのファイル(サーバー側)と Strings.swift(アプリ側)のみに置く
//   - **罰・恥系の表現は禁止**(「枯れる」「サボり」等のワードを使わない)
//   - 相手起点の通知は「相手のニックネーム名義」= alert.title に相手名(DESIGN §4)

/** alert.title 用の表示名。ニックネーム未設定(空)でも空タイトルにしない */
export function pushDisplayName(nickname: string): string {
  const trimmed = nickname.trim();
  return trimmed === "" ? "パートナー" : trimmed;
}

export interface PartnerCheckinMessageInput {
  /** 相手(=チェックインした人)の約束タイトル。例: ランニング */
  promiseTitle?: string | null;
  /** 約束の絵文字。例: 🏃 */
  promiseEmoji?: string | null;
}

// 例(REQUIREMENTS §3.12): 「ゆうき: ランニングやった!🔥」
//   → alert.title = ニックネーム / alert.body = ここで組み立てる本文
const PARTNER_CHECKIN_BODIES: ReadonlyArray<
  (p: { title: string; emoji: string }) => string | null
> = [
  (p) => p.title ? `${p.title}やった!${p.emoji || "🔥"}` : null,
  (p) => p.title ? `${p.title}、今日も完了!${p.emoji || "✨"}` : null,
  () => "今日のぶん、やったよ!",
  () => "チェックイン完了!見てみて🌱",
];

/**
 * 「相手がチェックインした」通知の本文(partner_checkin)。
 * random は注入可能(テストでは固定値を渡して決定論化する)。
 */
export function partnerCheckinBody(
  input: PartnerCheckinMessageInput,
  random: () => number = Math.random,
): string {
  const data = {
    title: (input.promiseTitle ?? "").trim(),
    emoji: (input.promiseEmoji ?? "").trim(),
  };
  const candidates = PARTNER_CHECKIN_BODIES
    .map((f) => f(data))
    .filter((b): b is string => b !== null);
  return pickOne(candidates, random);
}

/** 「写真が届いた」通知の本文(チェックイン済みの日に後から写真を添えたとき) */
export function photoAttachedBody(): string {
  return "今日の写真を添えたよ📷";
}

// ---- T05 追加分(invite-accept / close-day) ----

/**
 * システム(アプリ)名義の alert.title。close-day 等のサーバー起点通知に使う
 * (相手起点の通知は pushDisplayName(相手名)名義 — DESIGN §4)。
 */
export function systemPushTitle(): string {
  return "Lien";
}

/** ペア成立(pair_update)の本文。invite-accept が両者へ送る */
export function pairEstablishedBody(): string {
  return "ペアが成立したよ!今日からふたりで育てよう🌱";
}

/** お休みチケット自動消費(ticket_used)の本文。close-day が両者へ送る */
export function ticketUsedBody(): string {
  return "お休みチケットを1枚つかって、ふたりの記録をまもったよ🎟️";
}

/**
 * ストリークリセットの本文(close-day)。**責めない文言のみ**(REQUIREMENTS §3.5:
 * 「また今日から。最高記録 ○日 はふたりの財産」。相手を責める表現を絶対に置かない)。
 */
export function streakResetBody(bestStreak: number): string {
  if (!Number.isInteger(bestStreak) || bestStreak < 0) {
    throw new Error(`streakResetBody: bestStreak が不正です: ${bestStreak}`);
  }
  if (bestStreak === 0) {
    return "また今日から、ふたりのペースで始めよう🌱";
  }
  return `また今日から。最高記録 ${bestStreak}日 はふたりの財産だよ🌱`;
}

function pickOne(candidates: readonly string[], random: () => number): string {
  if (candidates.length === 0) {
    throw new Error("messages: 候補文言が空です");
  }
  const r = random();
  const index = Math.min(
    candidates.length - 1,
    Math.max(0, Math.floor(r * candidates.length)),
  );
  return candidates[index];
}

// ---- T15 追加分(nudge / react。文言オーナーは本タスク — T16 は残りの型のみ) ----

/**
 * つつく(ナッジ)のスタンプ6種(REQUIREMENTS §3.7)。
 * 自由テキストは入れない方針(チャット化を避ける — §3.7)のため、スタンプは固定語彙のみ。
 * サーバー側が語彙検証の正本(index.ts はここを import して照合する)。
 */
export const NUDGE_STAMPS: readonly string[] = [
  "👋",
  "⏰",
  "🙏",
  "📣",
  "😤",
  "✨",
];

/** つつき返事(ワンタップ)の定型4種(REQUIREMENTS §3.7)。自由入力は無し */
export const NUDGE_REPLIES: readonly string[] = [
  "今やる!",
  "ごめん寝てた",
  "あと少しで終わる!",
  "今日中にやるよ",
];

/** リアクションのスタンプ6種(REQUIREMENTS §3.8。固定語彙。順序はREQUIREMENTS記載順) */
export const REACTION_STAMPS: readonly string[] = [
  "❤️",
  "🔥",
  "👏",
  "😂",
  "🥹",
  "💪",
];

// 定型文(約20種。REQUIREMENTS §3.7「定型文からランダム」)。
// スタンプを埋め込み、押した側の気持ちを添える体で統一(責める表現は禁止 — DESIGN §3.8)。
// alert.title は呼び出し側が pushDisplayName(送り手) を使う(本文には名前を含めない)
const NUDGE_BODIES: ReadonlyArray<(stamp: string) => string> = [
  (s) => `${s} やってる?`,
  (s) => `${s} そろそろどう?`,
  (s) => `${s} 一緒にやろ!`,
  (s) => `${s} 今日もがんばろ`,
  (s) => `${s} 待ってるよ〜`,
  (s) => `${s} つんつん`,
  (s) => `${s} ふたりの約束、思い出した?`,
  (s) => `${s} ちょっとだけでもどう?`,
  (s) => `${s} 今日のぶん、いつやる?`,
  (s) => `${s} そろそろ一緒にがんばろう`,
  (s) => `${s} 気が向いたらでいいよ`,
  (s) => `${s} 今日も見てるよ`,
  (s) => `${s} 無理しなくていいから、気にかけてね`,
  (s) => `${s} 応援してる!`,
  (s) => `${s} ぼちぼちいこう`,
  (s) => `${s} 今日の分、お待ちしてます`,
  (s) => `${s} ちょっとだけ声かけてみた`,
  (s) => `${s} いつでもいいからね`,
  (s) => `${s} ふたりで続けよう`,
  (s) => `${s} 今日もよろしく!`,
];

/**
 * つつき(nudge)通知の本文。stamp は NUDGE_STAMPS のいずれかを想定するが、
 * 未知の値でも範囲外アクセスをしないよう素通しで埋め込む(語彙検証は core.ts の責務)。
 * random は注入可能(テストでは固定値を渡して決定論化する)。
 */
export function nudgeBody(
  stamp: string,
  random: () => number = Math.random,
): string {
  const candidates = NUDGE_BODIES.map((f) => f(stamp));
  return pickOne(candidates, random);
}

// リアクション本文(REQUIREMENTS §3.8。通知は自分の名前名義 = alert.title が送り手名、
// 本文は「(スタンプ)した」の体で統一。スタンプそのものを文中にも出し、絵文字が
// 伝わらない通知UIでも意味が残るようにする)
export function reactionBody(stamp: string): string {
  return `${stamp} した`;
}

/** テスト用: nudge/reaction の全文言(全スタンプ総当たり)を列挙する(罰なし原則チェック用) */
function allNudgeAndReactionBodies(): string[] {
  const bodies = new Set<string>();
  for (const stamp of NUDGE_STAMPS) {
    for (const f of NUDGE_BODIES) {
      bodies.add(f(stamp));
    }
  }
  for (const reply of NUDGE_REPLIES) {
    bodies.add(reply);
  }
  for (const stamp of REACTION_STAMPS) {
    bodies.add(reactionBody(stamp));
  }
  return [...bodies];
}

/** テスト用: 全文言を列挙する(罰なし原則チェックに使う。T16 で型ごとに拡張) */
export function allMessageBodiesForReview(): string[] {
  const samples: PartnerCheckinMessageInput[] = [
    { promiseTitle: "ランニング", promiseEmoji: "🏃" },
    { promiseTitle: "筋トレ", promiseEmoji: "" },
    {},
  ];
  const bodies = new Set<string>();
  for (const sample of samples) {
    const data = {
      title: (sample.promiseTitle ?? "").trim(),
      emoji: (sample.promiseEmoji ?? "").trim(),
    };
    for (const f of PARTNER_CHECKIN_BODIES) {
      const b = f(data);
      if (b !== null) bodies.add(b);
    }
  }
  bodies.add(photoAttachedBody());
  bodies.add(pushDisplayName(""));
  bodies.add(systemPushTitle());
  bodies.add(pairEstablishedBody());
  bodies.add(ticketUsedBody());
  bodies.add(streakResetBody(0));
  bodies.add(streakResetBody(23));
  for (const b of allNudgeAndReactionBodies()) {
    bodies.add(b);
  }
  return [...bodies];
}
