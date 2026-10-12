// grant-tickets/index.ts — 月次チケット付与 cron(毎月1日 00:05 JST)の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   Supabase リポジトリ実装 → _shared/cron_http.ts(認証・本文の解釈・応答)に本体を渡す
// だけを行う。リモート import(supabase-js)はこのファイルに隔離する。
//
// 起動: pg_cron + pg_net(migration 0007)から、JST の日付が1日の日だけ 00:05 JST に POST。
//   Authorization: Bearer <LIEN_CRON_SECRET> の完全一致のみ許可(Function secrets と Vault に同じ値。
//   service role key もユーザーJWTも受け付けない — issue #60)。
//   再実行は同月の実行記録(ticket_grant_runs。migration 0006)を冪等キーにスキップされる(core.ts 参照)。

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type ApplyGrantOutcome,
  type GrantTicketsPairRow,
  type GrantTicketsRepo,
  handleGrantTickets,
  parseGrantTicketsRequest,
} from "./core.ts";
import {
  handleCronRequest,
  warnIfCronSecretUnusable,
} from "../_shared/cron_http.ts";

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
      // 1. 実行記録(ペア×月)。上限到達で付与額が 0 だったペアもここに残る
      const { data: runs, error: runsError } = await db
        .from("ticket_grant_runs")
        .select("pair_id")
        .eq("pair_id", pairId)
        .eq("month_start", monthStart)
        .limit(1);
      if (runsError) throw runsError;
      if ((runs ?? []).length > 0) return true;

      // 2. 旧来の印(実行記録を入れる前の付与。同月の ledger monthly 行)
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

    async applyMonthlyGrant(params): Promise<ApplyGrantOutcome> {
      // 実行記録・残高・ledger を1トランザクションで書く RPC(migration 0006。service_role 専用)
      const { data, error } = await db.rpc("apply_monthly_ticket_grant", {
        p_pair_id: params.pairId,
        p_month_start: params.monthStart,
        p_date_local: params.dateLocal,
        p_delta: params.delta,
      });
      if (error) throw error;
      if (data !== "granted" && data !== "unchanged" && data !== "already") {
        throw new Error(
          `apply_monthly_ticket_grant の戻り値が不正です: ${
            JSON.stringify(data)
          }`,
        );
      }
      return data;
    },
  };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SERVICE_ROLE_KEY") ?? "";
// cron 専用の秘密(DB への接続用の SERVICE_ROLE_KEY とは別。Vault の lien_cron_secret と同じ値)
const CRON_SECRET = Deno.env.get("LIEN_CRON_SECRET") ?? "";
warnIfCronSecretUnusable("grant-tickets", CRON_SECRET);

const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

Deno.serve((req: Request) =>
  handleCronRequest(req, {
    label: "grant-tickets",
    secret: CRON_SECRET,
    parse: parseGrantTicketsRequest,
    run: (input) => handleGrantTickets({ repo: makeRepo(adminClient) }, input),
  })
);
