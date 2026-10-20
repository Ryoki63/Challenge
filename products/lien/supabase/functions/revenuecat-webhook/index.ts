// revenuecat-webhook/index.ts — RevenueCat Webhook の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   Authorization の取り出し → Supabase(service_role)リポジトリ実装 → handleRevenueCatWebhook
// だけを行う。リモート import(supabase-js)はここに隔離する(deno test はネットワーク不要 — DESIGN §8)。
//
// 設定(人間 / G6):
//   1. Supabase Function secrets に REVENUECAT_WEBHOOK_AUTH(32 文字以上のランダム値)を入れる
//   2. RevenueCat ダッシュボード → Integrations → Webhooks に
//      https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook を登録し、
//      Authorization ヘッダに 1 と同じ値を入れる
//   3. ダッシュボードの「Send test event」で 200 が返ることを確かめる
//
// この関数はユーザーの JWT を受け付けない(RevenueCat からの呼び出しだけ)。
// SERVICE_ROLE_KEY で users.premium_until を更新する(migration 0001 のとおり、この列は service_role だけが更新できる)。

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  handleRevenueCatWebhook,
  isWebhookSecretUsable,
  type RevenueCatWebhookBody,
  type RevenueCatWebhookDeps,
} from "./core.ts";

function makeDeps(db: SupabaseClient): RevenueCatWebhookDeps {
  return {
    async grantPremium(userId: string, premiumUntilIso: string): Promise<void> {
      // 期限は延ばす方向にだけ動かす。順不同で古い RENEWAL が後から届いても、
      // いまの期限(未来)を短くしない(条件: 未設定 or いまより未来)
      const { error } = await db
        .from("users")
        .update({ premium_until: premiumUntilIso })
        .eq("id", userId)
        .or(`premium_until.is.null,premium_until.lt.${premiumUntilIso}`);
      if (error) throw error;
    },

    async expirePremium(
      userId: string,
      expiredAtIso: string,
    ): Promise<void> {
      // いまの premium_until が、このイベントの期限以下のときだけ消す。
      // 順不同で古い EXPIRATION が後から届いても、新しい期限を消さない(単調性)
      const { error } = await db
        .from("users")
        .update({ premium_until: null })
        .eq("id", userId)
        .lte("premium_until", expiredAtIso);
      if (error) throw error;
    },
  };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SERVICE_ROLE_KEY") ?? "";
// RevenueCat ダッシュボードの Webhook に設定する Authorization の値(32 文字以上)
const WEBHOOK_AUTH = Deno.env.get("REVENUECAT_WEBHOOK_AUTH") ?? "";

if (!isWebhookSecretUsable(WEBHOOK_AUTH)) {
  console.error(
    "revenuecat-webhook: REVENUECAT_WEBHOOK_AUTH が未設定か短すぎます(32 文字以上が必要)。" +
      "すべての呼び出しを 401 で拒否します(scripts/OPS.md の G6 手順を参照)",
  );
}

const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json(405, { ok: false, error: "method_not_allowed" });
  }

  let body: RevenueCatWebhookBody;
  try {
    const parsed: unknown = await req.json();
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return json(400, { ok: false, error: "invalid_body" });
    }
    body = parsed as RevenueCatWebhookBody;
  } catch {
    return json(400, { ok: false, error: "invalid_json" });
  }

  try {
    const result = await handleRevenueCatWebhook(makeDeps(adminClient), {
      authorization: req.headers.get("authorization"),
      authSecret: WEBHOOK_AUTH,
      body,
    });
    return json(result.status, result.body);
  } catch (e) {
    // 想定外(リポジトリの失敗は core が 500 にする。ここは最後の受け皿)
    console.error("revenuecat-webhook: 予期しないエラー:", e);
    return json(500, { ok: false, error: "internal_error" });
  }
});
