// mgmt.ts — Supabase Management API(api.supabase.com)の薄いラッパ
//
// 通しテストで使うのは次の 4 つだけ:
//   - プロジェクトの状態(ACTIVE_HEALTHY か。無料枠の自動停止の検知 — OPS §5)
//   - API キー(アプリが使う公開キーを取る。後片付けの Storage 削除のときだけ secret key も取る)
//   - SQL(データの確認の SELECT と、後片付けの DELETE。ops/db-query.sh と同じ経路)
//
// 認証は SUPABASE_ACCESS_TOKEN(sbp_...)。Cloudflare 対策で User-Agent を付ける(OPS の他のスクリプトと同じ)。
// 鍵の値は呼び出し元の変数に入れて使うだけで、表示もログもしない。

import { request } from "./client.ts";

const API = "https://api.supabase.com";
const UA = "lien-agent/1.0";

export interface ApiKeyRow {
  name: string;
  type: string;
  api_key: string;
}

export class Mgmt {
  constructor(private readonly token: string, readonly ref: string) {}

  private async call(
    method: "GET" | "POST",
    path: string,
    json?: unknown,
  ): Promise<{ status: number; json: unknown; text: string }> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.token}`,
      "User-Agent": UA,
    };
    let body: string | undefined;
    if (json !== undefined) {
      headers["Content-Type"] = "application/json";
      body = JSON.stringify(json);
    }
    const r = await request(method, `${API}${path}`, {
      headers,
      body,
      timeoutMs: 120_000,
    });
    return { status: r.status, json: r.json, text: r.text };
  }

  /** プロジェクトの状態(ACTIVE_HEALTHY など) */
  async projectStatus(): Promise<string> {
    const r = await this.call("GET", `/v1/projects/${this.ref}`);
    if (r.status !== 200) {
      throw new Error(
        `Management API: プロジェクトの状態を取れない(HTTP ${r.status})`,
      );
    }
    return String((r.json as Record<string, unknown>)?.status ?? "unknown");
  }

  private async apiKeys(reveal: boolean): Promise<ApiKeyRow[]> {
    const q = reveal ? "?reveal=true" : "";
    const r = await this.call("GET", `/v1/projects/${this.ref}/api-keys${q}`);
    if (r.status !== 200 || !Array.isArray(r.json)) {
      throw new Error(`Management API: API キーを取れない(HTTP ${r.status})`);
    }
    return r.json as ApiKeyRow[];
  }

  /**
   * アプリが使う公開キー。publishable(sb_publishable_...)を優先し、無ければ legacy の anon。
   * どちらも公開してよいキー(iOS アプリに入る)だが、値は表示しない。種別だけ返す
   */
  async publicKey(): Promise<
    { key: string; kind: "publishable" | "legacy-anon" }
  > {
    const keys = await this.apiKeys(false);
    const pub = keys.find((k) => k.type === "publishable");
    if (pub?.api_key) return { key: pub.api_key, kind: "publishable" };
    const anon = keys.find((k) => k.type === "legacy" && k.name === "anon");
    if (anon?.api_key) return { key: anon.api_key, kind: "legacy-anon" };
    throw new Error(
      "Management API: 公開キー(publishable / anon)が見つからない",
    );
  }

  /**
   * secret key(sb_secret_...)。**万能鍵**なので、後片付けの Storage 削除のときだけ取る。
   * 値は戻り値の変数に入れて使うだけで、表示しない(OPS §1「鍵」・§6)
   */
  async secretKey(): Promise<string> {
    const keys = await this.apiKeys(true);
    const sec = keys.find((k) => k.type === "secret" && k.api_key);
    if (!sec) throw new Error("Management API: secret key が見つからない");
    return sec.api_key;
  }

  /**
   * Function secrets の名前だけ(値は SHA-256 のダイジェストが返るが、ここでは名前しか見ない)。
   * APNs の 5 変数がそろっているか(= push が有効か)の確認に使う
   */
  async functionSecretNames(): Promise<string[]> {
    const r = await this.call("GET", `/v1/projects/${this.ref}/secrets`);
    if (r.status !== 200 || !Array.isArray(r.json)) {
      throw new Error(
        `Management API: Function secrets を取れない(HTTP ${r.status})`,
      );
    }
    return (r.json as Array<{ name?: unknown }>)
      .map((x) => String(x.name ?? ""))
      .filter((n) => n !== "");
  }

  /** SQL を 1 回流して、最後の文の結果の行を返す(ops/db-query.sh と同じ経路) */
  async sql<T = Record<string, unknown>>(query: string): Promise<T[]> {
    const r = await this.call(
      "POST",
      `/v1/projects/${this.ref}/database/query`,
      {
        query,
      },
    );
    if (r.status < 200 || r.status >= 300) {
      const msg = (r.json as Record<string, unknown> | undefined)?.message;
      throw new Error(
        `Management API: SQL が失敗(HTTP ${r.status}) ${
          typeof msg === "string" ? msg.slice(0, 300) : r.text.slice(0, 300)
        }`,
      );
    }
    return Array.isArray(r.json) ? (r.json as T[]) : [];
  }
}
