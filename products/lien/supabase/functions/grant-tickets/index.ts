// grant-tickets/index.ts — 月次チケット付与 cron(毎月1日 00:05 JST)の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   cron 認証(service role key)→ Supabase リポジトリ実装 → handleGrantTickets → JSON 応答
// だけを行う。リモート import(supabase-js)はこのファイルに隔離する。
//
// 起動: Supabase の cron から毎月1日 00:05 JST に POST。
//   Authorization: Bearer <SERVICE_ROLE_KEY> のみ許可。
//   再実行は同月の ledger(reason='monthly')を冪等キーにスキップされる(core.ts 参照)。

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type GrantTicketsPairRow,
  type GrantTicketsRepo,
  handleGrantTickets,
} from "./core.ts";

function makeRepo(db: SupabaseClient): GrantTicketsRepo {
  return {
    async listActivePairs(): Promise<GrantTicketsPairRow[]> {
      const { data, error } = await db
        .from("pairs")
        .select("id, ticket_balance, pair_members(user_id)")
        .eq("status", "active");
      if (error) throw error;
      const rows: GrantTicketsPairRow[] = [];
      for (const p of data ?? []) {
        const members = (p.pair_members as Array<{ user_id: string }>) ?? [];
        if (members.length !== 2) {
          console.error(
            `grant-tickets: pair ${p.id} のメンバー数が不正(${members.length}人)`,
          );
          continue;
        }
        rows.push({
          pairId: p.id,
          ticketBalance: p.ticket_balance ?? 0,
          memberIds: [members[0].user_id, members[1].user_id],
        });
      }
      return rows;
    },

    async getPremiumUntil(userId: string): Promise<string | null> {
      const { data, error } = await db
        .from("users")
        .select("premium_until")
        .eq("id", userId)
        .maybeSingle();
      if (error) throw error;
      return data?.premium_until ?? null;
    },

    async hasMonthlyGrantInMonth(
      pairId: string,
      monthStart: string,
      nextMonthStart: string,
    ): Promise<boolean> {
      const { data, error } = await db
        .from("ticket_ledger")
        .select("id")
        .eq("pair_id", pairId)
        .eq("reason", "monthly")
        .gte("date_local", monthStart)
        .lt("date_local", nextMonthStart)
        .limit(1);
      if (error) throw error;
      return (data ?? []).length > 0;
    },

    async updateTicketBalance(pairId: string, balance: number): Promise<void> {
      const { error } = await db
        .from("pairs")
        .update({ ticket_balance: balance })
        .eq("id", pairId);
      if (error) throw error;
    },

    async insertTicketLedger(params): Promise<void> {
      const { error } = await db.from("ticket_ledger").insert({
        pair_id: params.pairId,
        delta: params.delta,
        reason: params.reason,
        date_local: params.dateLocal,
      });
      if (error) throw error;
    },
  };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SERVICE_ROLE_KEY") ?? "";

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

  // cron 専用: service role key のみ許可(ユーザーJWT不可)
  const token = (req.headers.get("Authorization") ?? "").replace(
    /^Bearer\s+/i,
    "",
  );
  if (!SERVICE_ROLE_KEY || token !== SERVICE_ROLE_KEY) {
    return json(401, { error: "unauthorized" });
  }

  let dateLocal: string | undefined;
  try {
    const body = await req.json();
    if (typeof body?.dateLocal === "string") dateLocal = body.dateLocal;
  } catch {
    // body なし(cron の素朴な POST)は既定の「今日(JST)」で処理
  }

  try {
    const result = await handleGrantTickets(
      { repo: makeRepo(adminClient) },
      { dateLocal },
    );
    return json(result.status, result.body);
  } catch (e) {
    console.error("grant-tickets: 予期しないエラー:", e);
    return json(500, { error: "internal_error" });
  }
});
