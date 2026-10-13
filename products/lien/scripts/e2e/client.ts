// client.ts — 本番 Supabase への HTTP 呼び出し。アプリ(iOS)が実際に送るヘッダの形に合わせる
//
//   - Edge Functions: `Authorization: Bearer <ユーザー JWT>` だけ(apikey は付けない)。
//     EdgeFunctionTransport.functionRequest と同じ。全関数 verify_jwt = false で、関数が自分で認証する
//   - PostgREST(users / checkins / reactions): `apikey` + `Authorization`。supabase-swift と同じ
//   - Storage の署名付きアップロード: ヘッダは Content-Type と x-upsert だけ(apikey も Authorization も付けない)。
//     EdgeFunctionCheckinClient.uploadPhoto と同じ。トークンはクエリ(?token=)
//   - Storage の署名付きダウンロード: ヘッダなしの GET(AsyncImage / URLSession が署名付き URL を取るのと同じ)
//
// 秘密(JWT・鍵)は戻り値にもログにも出さない。リクエストログにはパスだけを残す(UUID は :id に置き換え)。

import { E2E_META_KEY, E2E_META_VALUE } from "./marker.ts";

export interface Resp {
  status: number;
  /** リクエストの所要時間(ミリ秒) */
  ms: number;
  headers: Headers;
  bytes: Uint8Array<ArrayBuffer>;
  /** UTF-8 として読んだ本文 */
  text: string;
  /** JSON として読めたときの値。読めなければ undefined */
  json: unknown;
}

export interface RequestLogEntry {
  label: string;
  status: number;
  ms: number;
}

/** 実行中のすべてのリクエスト(最遅の確認用。URL のクエリ・本文・ヘッダは持たない) */
export const requestLog: RequestLogEntry[] = [];

const UUID_IN_PATH =
  /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

function labelOf(method: string, url: string): string {
  const u = new URL(url);
  return `${method} ${u.pathname.replace(UUID_IN_PATH, ":id")}`;
}

export interface RequestOptions {
  headers?: Record<string, string>;
  body?: string | Uint8Array<ArrayBuffer>;
  timeoutMs?: number;
}

export async function request(
  method: string,
  url: string,
  opts: RequestOptions = {},
): Promise<Resp> {
  const started = performance.now();
  let res: Response;
  try {
    res = await fetch(url, {
      method,
      headers: opts.headers,
      body: opts.body,
      signal: AbortSignal.timeout(opts.timeoutMs ?? 30_000),
    });
  } catch (e) {
    // 通信エラー・タイムアウト。URL(クエリにトークンがありうる)は出さない
    const name = e instanceof Error ? e.name : "Error";
    throw new Error(`${labelOf(method, url)} の通信に失敗(${name})`);
  }
  const bytes = new Uint8Array(await res.arrayBuffer());
  const ms = Math.round(performance.now() - started);
  const text = new TextDecoder().decode(bytes);
  let json: unknown = undefined;
  if (text.length > 0) {
    try {
      json = JSON.parse(text);
    } catch {
      json = undefined;
    }
  }
  requestLog.push({ label: labelOf(method, url), status: res.status, ms });
  return { status: res.status, ms, headers: res.headers, bytes, text, json };
}

/** JWT の payload を読む(署名は検証しない。中身の確認用) */
export function decodeJwtPayload(jwt: string): Record<string, unknown> | null {
  const parts = jwt.split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
    return JSON.parse(new TextDecoder().decode(
      Uint8Array.from(atob(padded), (c) => c.charCodeAt(0)),
    ));
  } catch {
    return null;
  }
}

export interface FnPayload {
  /** JSON として送る値 */
  json?: unknown;
  /** そのまま送る文字列(壊れた JSON の確認用) */
  raw?: string;
}

export class Api {
  constructor(readonly base: string, readonly anonKey: string) {}

  /**
   * POST /auth/v1/signup — 匿名サインイン(supabase-swift の signInAnonymously と同じ)。
   * アプリと違うのは data に通しテストの印(lien_e2e = true → raw_user_meta_data)を入れる点だけ。
   * 後片付け・一覧が「実ユーザーでない」ことを確かめる目印のひとつ(marker.ts)
   */
  signup(): Promise<Resp> {
    return request("POST", `${this.base}/auth/v1/signup`, {
      headers: {
        apikey: this.anonKey,
        "content-type": "application/json",
      },
      body: JSON.stringify({ data: { [E2E_META_KEY]: E2E_META_VALUE } }),
    });
  }

  /** POST /auth/v1/token?grant_type=refresh_token — セッションの更新(supabase-swift が期限切れの前後に自動で行う経路) */
  refresh(refreshToken: string): Promise<Resp> {
    return request(
      "POST",
      `${this.base}/auth/v1/token?grant_type=refresh_token`,
      {
        headers: {
          apikey: this.anonKey,
          "content-type": "application/json",
        },
        body: JSON.stringify({ refresh_token: refreshToken }),
      },
    );
  }

  /**
   * GET /auth/v1/user — 認証サーバーに、このトークンのユーザーを直接たしかめる。アプリの GoTrueSessionVerifier と同じ
   * (apikey + Authorization)。アカウントを削除したあとの JWT が、確かに「ユーザーが居ない」と拒否されるかの確認用
   */
  authUser(jwt: string): Promise<Resp> {
    return request("GET", `${this.base}/auth/v1/user`, {
      headers: { apikey: this.anonKey, Authorization: `Bearer ${jwt}` },
    });
  }

  /** GET /auth/v1/health */
  authHealth(): Promise<Resp> {
    return request("GET", `${this.base}/auth/v1/health`, {
      headers: { apikey: this.anonKey },
    });
  }

  /** Edge Function を呼ぶ。jwt が null なら Authorization なし */
  fn(
    jwt: string | null,
    name: string,
    method: "GET" | "POST",
    payload?: FnPayload,
  ): Promise<Resp> {
    const headers: Record<string, string> = {};
    if (jwt !== null) headers["Authorization"] = `Bearer ${jwt}`;
    let body: string | undefined;
    if (payload?.raw !== undefined) {
      headers["Content-Type"] = "application/json";
      body = payload.raw;
    } else if (payload?.json !== undefined) {
      headers["Content-Type"] = "application/json";
      body = JSON.stringify(payload.json);
    }
    return request(method, `${this.base}/functions/v1/${name}`, {
      headers,
      body,
    });
  }

  /** PostgREST(`/rest/v1/<pathAndQuery>`)。jwt が null なら anon キーを Authorization にも使う */
  rest(
    jwt: string | null,
    method: "GET" | "POST" | "PATCH" | "DELETE",
    pathAndQuery: string,
    opts: { json?: unknown; prefer?: string } = {},
  ): Promise<Resp> {
    const headers: Record<string, string> = {
      apikey: this.anonKey,
      Authorization: `Bearer ${jwt ?? this.anonKey}`,
      Accept: "application/json",
    };
    let body: string | undefined;
    if (opts.json !== undefined) {
      headers["Content-Type"] = "application/json";
      body = JSON.stringify(opts.json);
    }
    if (opts.prefer) headers["Prefer"] = opts.prefer;
    return request(method, `${this.base}/rest/v1/${pathAndQuery}`, {
      headers,
      body,
    });
  }

  /**
   * POST /storage/v1/object/sign/photos/<path> — 署名付きダウンロード URL の発行(#59 PV の経路。
   * 利用者の JWT で作る。supabase-swift の createSignedURL と同じエンドポイント)
   */
  storageSign(
    jwt: string | null,
    objectPath: string,
    expiresIn: number,
  ): Promise<Resp> {
    return request(
      "POST",
      `${this.base}/storage/v1/object/sign/photos/${objectPath}`,
      {
        headers: {
          apikey: this.anonKey,
          Authorization: `Bearer ${jwt ?? this.anonKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ expiresIn }),
      },
    );
  }

  /** 発行された signedURL(`/object/sign/photos/...?token=...`)を、ヘッダなしで取りに行く */
  signedGet(signedUrl: string): Promise<Resp> {
    const url = signedUrl.startsWith("http")
      ? signedUrl
      : `${this.base}/storage/v1${signedUrl}`;
    return request("GET", url);
  }

  /**
   * 署名付きアップロード(DESIGN §5.6)。アプリの EdgeFunctionCheckinClient.uploadPhoto と同じ形:
   * PUT /storage/v1/object/upload/sign/photos/<path>?token=<token>、
   * Content-Type: image/jpeg と x-upsert: true だけ(apikey も Authorization も付けない)
   */
  signedUpload(
    objectPath: string,
    token: string,
    bytes: Uint8Array<ArrayBuffer>,
    extraHeaders: Record<string, string> = {},
  ): Promise<Resp> {
    return request(
      "PUT",
      `${this.base}/storage/v1/object/upload/sign/photos/${objectPath}?token=${
        encodeURIComponent(token)
      }`,
      {
        headers: {
          "Content-Type": "image/jpeg",
          "x-upsert": "true",
          ...extraHeaders,
        },
        body: bytes,
      },
    );
  }

  /** DELETE /storage/v1/object/photos — クライアントの JWT での削除(許可されないことの確認用) */
  storageRemove(jwt: string, objectPaths: string[]): Promise<Resp> {
    return request("DELETE", `${this.base}/storage/v1/object/photos`, {
      headers: {
        apikey: this.anonKey,
        Authorization: `Bearer ${jwt}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ prefixes: objectPaths }),
    });
  }
}
