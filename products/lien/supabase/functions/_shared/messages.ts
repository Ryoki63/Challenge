// _shared/messages.ts — プッシュ通知文言(最小スタブ)
//
// ※ 本ファイルは T04 時点の最小スタブ。**T16(通知一式)で全文言化する**:
//    nudge 定型20種+スタンプ、reaction、streak_risk、ticket_used、milestone、
//    reset 系(責めない文言)などを追加し、罰なし原則チェック付きでレビューする。
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
  return [...bodies];
}
