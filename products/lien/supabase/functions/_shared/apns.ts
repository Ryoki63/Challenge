// _shared/apns.ts — APNs 送信クライアント(ES256 JWT 発行+HTTP POST)
//
// 正本: docs/DESIGN.md §4(ペイロード仕様)/ §5.5(送信失敗リトライ1回・失敗でも処理成功扱い)
//        / §7(シークレット: APNS_AUTH_KEY / APNS_KEY_ID / APPLE_TEAM_ID / APNS_ENV は
//          Supabase secrets。人間が G0 で設定。**コードにハードコード禁止**)
//
// 設計:
//   - HTTP 送信部(ApnsHttpPost)は注入可能。テストはモックを渡し、ネットワーク不要で
//     deno test が通る(DESIGN §5.3「apns.ts は送信クライアントを注入可能にし、テストではモック」)
//   - 既定実装 fetchApnsHttpPost は Deno の fetch(APNs は HTTP/2 必須。Deno/Edge Runtime の
//     fetch は ALPN で HTTP/2 を選択する)
//   - JWT は ES256(P-256)。WebCrypto(crypto.subtle)のみ使用、外部依存なし(DESIGN §9-1)
//   - JWT はキャッシュして使い回す(Apple の規定: 20分〜60分で更新。ここでは45分で再発行)
//   - send() は決して throw しない。結果は ApnsSendResult で返し、push 失敗の扱い
//     (成功扱いにする等)は呼び出し側のポリシーに委ねる

import type { PairSnapshot } from "./snapshot.ts";

// ---- 設定 ----

export type ApnsEnvironment = "sandbox" | "production";

export interface ApnsConfig {
  /** APNs 認証キー(.p8 の PEM 全文)。env: APNS_AUTH_KEY */
  keyPem: string;
  /** env: APNS_KEY_ID */
  keyId: string;
  /** env: APPLE_TEAM_ID */
  teamId: string;
  /** env: APNS_ENV(sandbox | production。TestFlight は production — DESIGN §10) */
  environment: ApnsEnvironment;
  /** apns-topic ヘッダ(= Bundle ID)。env: APNS_TOPIC */
  topic: string;
}

/**
 * 環境変数から設定を読む。get は注入可能(既定は呼び出し側で Deno.env.get を渡す)。
 * 必須変数が1つでも欠けていれば null(= push 無効で運転。dev/テスト環境用)。
 * APNS_ENV の値が不正なときだけは設定ミスとして throw する。
 */
export function loadApnsConfigFromEnv(
  get: (key: string) => string | undefined,
): ApnsConfig | null {
  const keyPem = get("APNS_AUTH_KEY");
  const keyId = get("APNS_KEY_ID");
  const teamId = get("APPLE_TEAM_ID");
  const environment = get("APNS_ENV");
  const topic = get("APNS_TOPIC");
  if (!keyPem || !keyId || !teamId || !environment || !topic) return null;
  if (environment !== "sandbox" && environment !== "production") {
    throw new Error(
      `APNS_ENV は sandbox | production のいずれかにしてください: ${environment}`,
    );
  }
  return { keyPem, keyId, teamId, environment, topic };
}

// ---- ペイロード(DESIGN §4 と一字一句一致) ----

export type LienPushType =
  | "partner_checkin"
  | "nudge"
  | "reaction"
  | "streak_risk"
  | "milestone"
  | "ticket_used"
  | "pair_update";

/**
 * 可視プッシュのペイロード(mutable-content: 1。NSE が lien.snapshot を App Group へ書く)。
 * 形は DESIGN §4 が正本。変更時は互換性影響を JOURNAL に明記(DESIGN §9-7)。
 */
export function buildVisiblePushPayload(params: {
  /** alert.title。相手起点の通知は相手のニックネーム(messages.ts の pushDisplayName) */
  title: string;
  /** alert.body(messages.ts から) */
  body: string;
  type: LienPushType;
  /** 受信者視点の PairSnapshot */
  snapshot: PairSnapshot;
}): Record<string, unknown> {
  return {
    aps: {
      alert: { title: params.title, body: params.body },
      sound: "default",
      "mutable-content": 1,
    },
    lien: { type: params.type, snapshot: params.snapshot },
  };
}

// ---- HTTP 送信部(注入可能) ----

export interface ApnsHttpResponse {
  status: number;
  body: string;
}

export type ApnsHttpPost = (
  url: string,
  headers: Record<string, string>,
  body: string,
) => Promise<ApnsHttpResponse>;

/** 既定の送信実装(fetch)。テストでは使わない */
export const fetchApnsHttpPost: ApnsHttpPost = async (url, headers, body) => {
  const res = await fetch(url, { method: "POST", headers, body });
  return { status: res.status, body: await res.text() };
};

// ---- ES256 JWT ----

/**
 * APNs provider token(ES256 JWT)を発行する。
 * header: {"alg":"ES256","kid":<keyId>} / claims: {"iss":<teamId>,"iat":<発行時刻(秒)>}
 */
export async function createApnsJwt(params: {
  keyPem: string;
  keyId: string;
  teamId: string;
  issuedAt: Date;
}): Promise<string> {
  const header = { alg: "ES256", kid: params.keyId };
  const claims = {
    iss: params.teamId,
    iat: Math.floor(params.issuedAt.getTime() / 1000),
  };
  const signingInput = `${base64UrlEncodeString(JSON.stringify(header))}.${
    base64UrlEncodeString(JSON.stringify(claims))
  }`;
  const key = await importPkcs8EcPrivateKey(params.keyPem);
  // WebCrypto の ECDSA 署名は raw(r||s, P-256 で64バイト)= JWT(JWS)が要求する形式そのもの
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64UrlEncodeBytes(new Uint8Array(signature))}`;
}

async function importPkcs8EcPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  if (body === "") {
    throw new Error("APNS_AUTH_KEY が PEM(PKCS#8)形式ではありません");
  }
  const der = base64Decode(body);
  return await crypto.subtle.importKey(
    "pkcs8",
    // base64Decode は新規 ArrayBuffer 上に確保する(SharedArrayBuffer ではない)
    der.buffer as ArrayBuffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

function base64Decode(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function base64UrlEncodeBytes(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlEncodeString(s: string): string {
  return base64UrlEncodeBytes(new TextEncoder().encode(s));
}

// ---- クライアント ----

export type ApnsSendResult =
  | { ok: true; status: number; attempts: number }
  | { ok: false; status?: number; attempts: number; reason: string };

const APNS_HOSTS: Record<ApnsEnvironment, string> = {
  sandbox: "api.sandbox.push.apple.com",
  production: "api.push.apple.com",
};

/** JWT 再発行までの時間(Apple 規定 20〜60 分の内側) */
const JWT_TTL_MS = 45 * 60 * 1000;

/** push 送信の試行回数上限(= 失敗時リトライ1回。DESIGN §5.5) */
const MAX_ATTEMPTS = 2;

export class ApnsClient {
  #config: ApnsConfig;
  #post: ApnsHttpPost;
  #now: () => Date;
  #cachedJwt: { token: string; issuedAtMs: number } | null = null;

  constructor(
    config: ApnsConfig,
    deps: { post?: ApnsHttpPost; now?: () => Date } = {},
  ) {
    this.#config = config;
    this.#post = deps.post ?? fetchApnsHttpPost;
    this.#now = deps.now ?? (() => new Date());
  }

  /**
   * デバイストークンへ payload を送信する。
   * - 失敗(送信例外・5xx)はリトライ1回まで(DESIGN §5.5)
   * - 4xx(BadDeviceToken 等)はリトライしない
   * - 決して throw しない。失敗しても呼び出し側の処理は成功扱いにできる
   *   (自己修復経路 GET /snapshot があるため — DESIGN §4)
   */
  async send(
    deviceToken: string,
    payload: Record<string, unknown>,
    opts: { pushType?: "alert" | "background"; priority?: number } = {},
  ): Promise<ApnsSendResult> {
    let lastReason = "unknown";
    let lastStatus: number | undefined;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      try {
        const jwt = await this.#jwt();
        const url = `https://${
          APNS_HOSTS[this.#config.environment]
        }/3/device/${deviceToken}`;
        const headers: Record<string, string> = {
          authorization: `bearer ${jwt}`,
          "apns-topic": this.#config.topic,
          "apns-push-type": opts.pushType ?? "alert",
          "apns-priority": String(opts.priority ?? 10),
          "content-type": "application/json",
        };
        const res = await this.#post(url, headers, JSON.stringify(payload));
        if (res.status === 200) {
          return { ok: true, status: res.status, attempts: attempt };
        }
        lastStatus = res.status;
        lastReason = `apns status ${res.status}: ${res.body}`;
        if (res.status < 500) {
          // 4xx はリクエスト自体の問題(トークン無効等)。リトライしても無駄
          return {
            ok: false,
            status: res.status,
            attempts: attempt,
            reason: lastReason,
          };
        }
      } catch (e) {
        lastStatus = undefined;
        lastReason = e instanceof Error ? e.message : String(e);
      }
    }
    return {
      ok: false,
      status: lastStatus,
      attempts: MAX_ATTEMPTS,
      reason: lastReason,
    };
  }

  async #jwt(): Promise<string> {
    const nowMs = this.#now().getTime();
    if (
      this.#cachedJwt !== null &&
      nowMs - this.#cachedJwt.issuedAtMs < JWT_TTL_MS
    ) {
      return this.#cachedJwt.token;
    }
    const token = await createApnsJwt({
      keyPem: this.#config.keyPem,
      keyId: this.#config.keyId,
      teamId: this.#config.teamId,
      issuedAt: new Date(nowMs),
    });
    this.#cachedJwt = { token, issuedAtMs: nowMs };
    return token;
  }
}
