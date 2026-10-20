// revenuecat-webhook/core.ts — RevenueCat Webhook の本体ロジック(純粋。I/O は注入)
//
// 正本: docs/REQUIREMENTS.md §3.14(実装: RevenueCat。Webhook で users.premium_until を更新)
//        / docs/DESIGN.md §3.4・§7
//
// 役割:
//   - RevenueCat ダッシュボードの Webhook から届くイベントを、users.premium_until に反映する
//   - app_user_id は Supabase の user id(Purchases.logIn(supabaseUserId) の規約。T33 の iOS 側)
//   - 課金の正は RevenueCat で、こちらは表示用の控え(premium_until)を更新するだけ
//
// イベントの扱い:
//   - INITIAL_PURCHASE / RENEWAL / UNCANCELLATION / PRODUCT_CHANGE / NON_RENEWING_PURCHASE /
//     SUBSCRIPTION_EXTENDED → premium_until = expiration_at_ms(未来のとき)
//   - EXPIRATION → 期限切れ。**いまの premium_until がこのイベントの期限以下のときだけ** null にする
//     (順不同で古い EXPIRATION が後から届いても、新しい期限を消さない)
//   - CANCELLATION(自動更新の停止)は期限まで有効なので何もしない
//   - TEST(ダッシュボードの疎通確認)・TRANSFER・BILLING_ISSUE・未知の種別は 200 で無視する
//     (RevenueCat は 2xx 以外を再送する。知らない種別で無限に再送させない)
//
// 認証:
//   - RevenueCat の Webhook は、ダッシュボードで設定した Authorization ヘッダの値をそのまま送る
//     (Bearer は付けない)。Function secrets の REVENUECAT_WEBHOOK_AUTH と定数時間で比較する
//   - 秘密が未設定・短すぎるときは全拒否(空文字どうしの一致で通さない)
//
// 依存は _shared/cron_http.ts の timingSafeEqual だけ。supabase-js は index.ts に隔離する。

import { MIN_CRON_SECRET_LENGTH, timingSafeEqual } from "../_shared/cron_http.ts";

/** 期限を延ばすイベント(RevenueCat のイベント種別) */
export const GRANT_EVENT_TYPES: ReadonlySet<string> = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "UNCANCELLATION",
  "PRODUCT_CHANGE",
  "NON_RENEWING_PURCHASE",
  "SUBSCRIPTION_EXTENDED",
]);

/** 期限切れのイベント */
export const EXPIRATION_EVENT_TYPE = "EXPIRATION";

/** 無視する(200 を返す)イベント。未知の種別も同じ扱い */
export const IGNORED_EVENT_TYPES: ReadonlySet<string> = new Set([
  "TEST",
  "TRANSFER",
  "CANCELLATION",
  "BILLING_ISSUE",
  "SUBSCRIBER_ALIAS",
  "PRODUCT_CHANGE_PENDING",
]);

/** RevenueCat Webhook の本文(event の中の、こちらが読むキーだけ) */
export interface RevenueCatEvent {
  /** RevenueCat のイベント id(冪等キー。今は期限の単調性で守るのでログ用) */
  id?: string;
  /** イベント種別(INITIAL_PURCHASE など) */
  type?: string;
  /** Supabase の user id(Purchases.logIn の規約) */
  app_user_id?: string;
  /** 期限(ミリ秒 epoch)。EXPIRATION では通常は過去 */
  expiration_at_ms?: number;
  /** 購入時刻(ミリ秒 epoch。ログ用) */
  purchased_at_ms?: number;
  /** イベント発生時刻(ミリ秒 epoch) */
  event_timestamp_ms?: number;
  /** 商品 id(ログ用) */
  product_id?: string;
  /** 対象の entitlement(ログ用) */
  entitlement_ids?: string[] | null;
}

export interface RevenueCatWebhookBody {
  api_version?: string;
  event?: RevenueCatEvent;
}

/** 注入する I/O。index.ts が Supabase で実装する */
export interface RevenueCatWebhookDeps {
  /** users.premium_until を未来の期限へ更新する */
  grantPremium(userId: string, premiumUntilIso: string): Promise<void>;
  /**
   * 期限切れにする。**いまの premium_until が expiredAtIso 以下のときだけ** null にする
   * (順不同で古い EXPIRATION が後から届いても、新しい期限を消さない)
   */
  expirePremium(userId: string, expiredAtIso: string): Promise<void>;
  /** 現在時刻(テストで固定する) */
  now?: () => Date;
}

export interface RevenueCatWebhookRequest {
  /** Authorization ヘッダの値(そのまま。Bearer は付かない) */
  authorization: string | null;
  /** REVENUECAT_WEBHOOK_AUTH(未設定なら undefined) */
  authSecret: string | undefined;
  /** パース済みの本文(壊れた JSON は呼び出し側で 400 にする) */
  body: RevenueCatWebhookBody;
}

export interface RevenueCatWebhookResponse {
  status: number;
  body: Record<string, unknown>;
}

/** 秘密が使える状態か(未設定・短すぎるときは全拒否) */
export function isWebhookSecretUsable(
  secret: string | undefined,
): secret is string {
  return !!secret && secret.length >= MIN_CRON_SECRET_LENGTH;
}

/**
 * Webhook の認証。秘密が未設定・短すぎるときは常に false。
 * RevenueCat は `Authorization: <設定した値>` をそのまま送る(Bearer ではない)
 */
export function isAuthorizedWebhook(
  authorization: string | null,
  secret: string | undefined,
): boolean {
  if (!isWebhookSecretUsable(secret)) return false;
  if (!authorization) return false;
  return timingSafeEqual(authorization.trim(), secret);
}

/** Supabase の user id(uuid v4 とは限らないので、一般的な uuid の形だけ見る) */
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isSupabaseUserId(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

/** ミリ秒 epoch → ISO8601。数値でない・有限でないときは null */
export function msToIso(value: unknown): string | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const date = new Date(value);
  const time = date.getTime();
  if (!Number.isFinite(time)) return null;
  return date.toISOString();
}

/**
 * Webhook 1件を処理する。HTTP の status と応答本文を返す(例外は投げない。
 * リポジトリの失敗は 500 にして RevenueCat に再送させる)。
 */
export async function handleRevenueCatWebhook(
  deps: RevenueCatWebhookDeps,
  req: RevenueCatWebhookRequest,
): Promise<RevenueCatWebhookResponse> {
  if (!isAuthorizedWebhook(req.authorization, req.authSecret)) {
    return { status: 401, body: { ok: false, error: "unauthorized" } };
  }

  const event = req.body?.event;
  if (!event || typeof event !== "object") {
    return { status: 400, body: { ok: false, error: "invalid_body" } };
  }
  const type = typeof event.type === "string" ? event.type : "";
  if (type === "") {
    return { status: 400, body: { ok: false, error: "invalid_event_type" } };
  }

  // 知らない種別・無視する種別は 200(再送させない)
  if (!GRANT_EVENT_TYPES.has(type) && type !== EXPIRATION_EVENT_TYPE) {
    return {
      status: 200,
      body: { ok: true, ignored: true, type },
    };
  }

  // TEST などの疎通確認は app_user_id を持たないことがある。期限を動かす種別だけ検証する
  if (!isSupabaseUserId(event.app_user_id)) {
    // RevenueCat の匿名 id($RCAnonymousID:...)など、Supabase のユーザーではないイベントは無視する
    return { status: 200, body: { ok: true, ignored: true, reason: "unknown_user", type } };
  }
  const userId = event.app_user_id;
  const now = deps.now ? deps.now() : new Date();

  if (type === EXPIRATION_EVENT_TYPE) {
    // expiration_at_ms が無い EXPIRATION は、受信時刻を期限として扱う
    const expiredAtIso = msToIso(event.expiration_at_ms) ?? now.toISOString();
    try {
      await deps.expirePremium(userId, expiredAtIso);
    } catch (error) {
      console.error("revenuecat-webhook: expirePremium に失敗", error);
      return { status: 500, body: { ok: false, error: "update_failed" } };
    }
    return { status: 200, body: { ok: true, type, userId } };
  }

  const premiumUntilIso = msToIso(event.expiration_at_ms);
  if (!premiumUntilIso) {
    return { status: 400, body: { ok: false, error: "invalid_expiration" } };
  }
  // 期限が既に過去なら、その時点で終わっているものとして扱う
  if (new Date(premiumUntilIso).getTime() <= now.getTime()) {
    try {
      await deps.expirePremium(userId, premiumUntilIso);
    } catch (error) {
      console.error("revenuecat-webhook: expirePremium に失敗", error);
      return { status: 500, body: { ok: false, error: "update_failed" } };
    }
    return {
      status: 200,
      body: { ok: true, type, userId, expired: true },
    };
  }

  try {
    await deps.grantPremium(userId, premiumUntilIso);
  } catch (error) {
    console.error("revenuecat-webhook: grantPremium に失敗", error);
    return { status: 500, body: { ok: false, error: "update_failed" } };
  }
  return { status: 200, body: { ok: true, type, userId, premiumUntil: premiumUntilIso } };
}
