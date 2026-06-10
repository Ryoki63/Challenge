// invite-create/index.ts — POST /functions/v1/invite-create の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   認証 → Supabase リポジトリ実装 → handleInviteCreate → JSON 応答
// だけを行う。リモート import(supabase-js)はこのファイルに隔離し、
// テストから到達しない(deno test はネットワーク不要 — DESIGN §8)。
//
// 招待ページのベースURL は環境変数 INVITE_WEB_BASE_URL(シークレットではない公開URL)。
// 未設定時は GitHub Pages の既定値にフォールバックする(G0 で確定 — DESIGN §6)。

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { handleInviteCreate, type InviteCreateRepo } from "./core.ts";
import type { SnapshotPairRow, SnapshotUserRow } from "../_shared/snapshot.ts";

const PG_UNIQUE_VIOLATION = "23505";

function makeRepo(db: SupabaseClient): InviteCreateRepo {
  return {
    async getUser(userId: string): Promise<SnapshotUserRow | null> {
      const { data, error } = await db
        .from("users")
        .select("id, nickname, timezone, push_token")
        .eq("id", userId)
        .maybeSingle();
      if (error) throw error;
      if (!data) return null;
      return {
        id: data.id,
        nickname: data.nickname ?? "",
        timezone: data.timezone ?? "Asia/Tokyo",
        pushToken: data.push_token ?? null,
      };
    },

    async getActivePair(userId: string): Promise<SnapshotPairRow | null> {
      const { data: membership, error: e1 } = await db
        .from("pair_members")
        .select("pair_id, pairs!inner(id, status, started_on)")
        .eq("user_id", userId)
        .eq("pairs.status", "active")
        .maybeSingle();
      if (e1) throw e1;
      if (!membership) return null;
      const pair = membership.pairs as unknown as {
        id: string;
        started_on: string;
      };
      const { data: partnerRow, error: e2 } = await db
        .from("pair_members")
        .select("user_id, users!inner(id, nickname, timezone, push_token)")
        .eq("pair_id", membership.pair_id)
        .neq("user_id", userId)
        .maybeSingle();
      if (e2) throw e2;
      if (!partnerRow) return null;
      const partner = partnerRow.users as unknown as {
        id: string;
        nickname: string | null;
        timezone: string | null;
        push_token: string | null;
      };
      return {
        pairId: pair.id,
        startedOn: pair.started_on,
        partner: {
          id: partner.id,
          nickname: partner.nickname ?? "",
          timezone: partner.timezone ?? "Asia/Tokyo",
          pushToken: partner.push_token ?? null,
        },
      };
    },

    async insertInvite(params): Promise<{ inserted: boolean }> {
      const { error } = await db.from("invites").insert({
        token: params.token,
        from_user: params.fromUser,
        expires_at: params.expiresAtIso,
      });
      if (error) {
        if (error.code === PG_UNIQUE_VIOLATION) return { inserted: false };
        throw error;
      }
      return { inserted: true };
    },
  };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SERVICE_ROLE_KEY") ?? "";
const INVITE_WEB_BASE_URL = Deno.env.get("INVITE_WEB_BASE_URL") ??
  "https://ryoki63.github.io/Challenge";

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
    return json(405, { error: "method_not_allowed" });
  }

  const token = (req.headers.get("Authorization") ?? "").replace(
    /^Bearer\s+/i,
    "",
  );
  const { data: authData, error: authError } = await adminClient.auth.getUser(
    token,
  );
  if (authError || !authData?.user) {
    return json(401, { error: "unauthorized" });
  }

  try {
    const result = await handleInviteCreate(
      { repo: makeRepo(adminClient), webBaseUrl: INVITE_WEB_BASE_URL },
      { userId: authData.user.id },
    );
    return json(result.status, result.body);
  } catch (e) {
    console.error("invite-create: 予期しないエラー:", e);
    return json(500, { error: "internal_error" });
  }
});
