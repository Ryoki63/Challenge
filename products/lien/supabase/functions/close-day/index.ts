// close-day/index.ts — 前日確定 cron(毎日 00:10 JST)の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   Supabase リポジトリ実装 → _shared/cron_http.ts(認証・本文の解釈・応答)に本体を渡す
// だけを行う。リモート import(supabase-js)はこのファイルに隔離する。
//
// 起動: pg_cron + pg_net(migration 0007)から毎日 00:10 JST に POST。
//   Authorization: Bearer <LIEN_CRON_SECRET> の完全一致のみ許可(Function secrets と Vault に同じ値。
//   service role key もユーザーJWTも受け付けない — issue #60)。
//   本文は空 or JSON オブジェクト。再実行・バックフィルは { "dateLocal": "YYYY-MM-DD" } を渡す。
//   手動の再実行は { "notify": false } も付ける(リセット・チケット消費の通知を再送しない)。

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type CloseDayPairRow,
  type CloseDayRepo,
  handleCloseDay,
  parseCloseDayRequest,
} from "./core.ts";
import {
  handleCronRequest,
  warnIfCronSecretUnusable,
} from "../_shared/cron_http.ts";
import type {
  SnapshotCheckinRow,
  SnapshotPairRow,
  SnapshotPlantRow,
  SnapshotPromiseRow,
  SnapshotUserRow,
} from "../_shared/snapshot.ts";
import type { StreakDayKind, StreakDayRecord } from "../_shared/streak.ts";
import { createPusher } from "../_shared/pusher.ts";
import type { Pusher } from "../checkin/core.ts";

function makeRepo(db: SupabaseClient): CloseDayRepo {
  return {
    // ---- SnapshotRepo(checkin/index.ts と同型) ----
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

    async getActivePromise(userId: string): Promise<SnapshotPromiseRow | null> {
      const { data, error } = await db
        .from("promises")
        .select("id, title, emoji")
        .eq("user_id", userId)
        .is("archived_at", null)
        .maybeSingle();
      if (error) throw error;
      return data
        ? { id: data.id, title: data.title, emoji: data.emoji }
        : null;
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

    async getCheckin(
      userId: string,
      dateLocal: string,
    ): Promise<SnapshotCheckinRow | null> {
      const { data, error } = await db
        .from("checkins")
        .select("photo_path")
        .eq("user_id", userId)
        .eq("date_local", dateLocal)
        .maybeSingle();
      if (error) throw error;
      return data ? { photoPath: data.photo_path ?? null } : null;
    },

    async listStreakDays(pairId: string): Promise<StreakDayRecord[]> {
      const { data, error } = await db
        .from("streak_days")
        .select("date_local, kind")
        .eq("pair_id", pairId);
      if (error) throw error;
      return (data ?? []).map((r) => ({
        dateLocal: r.date_local as string,
        kind: r.kind as StreakDayKind,
      }));
    },

    async getPlant(pairId: string): Promise<SnapshotPlantRow | null> {
      const { data, error } = await db
        .from("plants")
        .select("grown_days, name")
        .eq("pair_id", pairId)
        .maybeSingle();
      if (error) throw error;
      return data
        ? { grownDays: data.grown_days ?? 0, name: data.name ?? null }
        : null;
    },

    // ---- close-day 固有 ----
    async listPairsForClose(dateLocal: string): Promise<CloseDayPairRow[]> {
      const { data, error } = await db
        .from("pairs")
        .select("id, status, started_on, ticket_balance, pair_members(user_id)")
        .eq("status", "active")
        .lte("started_on", dateLocal);
      if (error) throw error;
      const rows: CloseDayPairRow[] = [];
      for (const p of data ?? []) {
        const members = (p.pair_members as Array<{ user_id: string }>) ?? [];
        if (members.length !== 2) {
          // メンバー2人未満のペアはデータ不整合。確定対象から外してログに残す
          console.error(
            `close-day: pair ${p.id} のメンバー数が不正(${members.length}人)`,
          );
          continue;
        }
        rows.push({
          pairId: p.id,
          status: p.status as "active" | "dissolved",
          startedOn: p.started_on,
          ticketBalance: p.ticket_balance ?? 0,
          memberIds: [members[0].user_id, members[1].user_id],
        });
      }
      return rows;
    },

    async getStreakDay(
      pairId: string,
      dateLocal: string,
    ): Promise<StreakDayKind | null> {
      const { data, error } = await db
        .from("streak_days")
        .select("kind")
        .eq("pair_id", pairId)
        .eq("date_local", dateLocal)
        .maybeSingle();
      if (error) throw error;
      return (data?.kind as StreakDayKind | undefined) ?? null;
    },

    async hasRestDeclared(
      pairId: string,
      dateLocal: string,
    ): Promise<boolean> {
      const { data, error } = await db
        .from("ticket_ledger")
        .select("id")
        .eq("pair_id", pairId)
        .eq("reason", "declare")
        .eq("date_local", dateLocal)
        .limit(1);
      if (error) throw error;
      return (data ?? []).length > 0;
    },

    async upsertStreakDay(pairId, dateLocal, kind): Promise<void> {
      // PK(pair_id, date_local) 衝突は無視(再実行の冪等性 — DESIGN §5.4)
      const { error } = await db
        .from("streak_days")
        .upsert(
          { pair_id: pairId, date_local: dateLocal, kind },
          { onConflict: "pair_id,date_local", ignoreDuplicates: true },
        );
      if (error) throw error;
    },

    async updateTicketBalance(pairId, balance): Promise<void> {
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

    async updatePlantGrowth(pairId, grownDays): Promise<void> {
      // stage は書かない(plants.stage の CHECK(0〜5)は10段階に合わない。
      // 表示用の段階は snapshot が streak_days から計算する — GROWTH §7.2)
      const { error } = await db
        .from("plants")
        .update({ grown_days: grownDays })
        .eq("pair_id", pairId);
      if (error) throw error;
    },

    recordStreakReset(pairId, dateLocal): Promise<void> {
      // 専用テーブルが未定義(DESIGN §5.4 の streak_reset イベント)。
      // 暫定で構造化ログに残す(followup: events テーブル等での永続化を検討)
      console.log(
        JSON.stringify({ event: "streak_reset", pairId, dateLocal }),
      );
      return Promise.resolve();
    },
  };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SERVICE_ROLE_KEY") ?? "";
// cron 専用の秘密(DB への接続用の SERVICE_ROLE_KEY とは別。Vault の lien_cron_secret と同じ値)
const CRON_SECRET = Deno.env.get("LIEN_CRON_SECRET") ?? "";
warnIfCronSecretUnusable("close-day", CRON_SECRET);

const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// APNs 設定が未投入(G0 前)の間は push なしで運転する(処理自体は止めない)。
// 設定済みなら、トークンごとに users.push_env で APNs の環境を選び、
// 無効なトークン(410 / BadDeviceToken)は push_token を null にする(DESIGN §4 / issue #53)
const pusher: Pusher = createPusher(adminClient, "close-day");

Deno.serve((req: Request) =>
  handleCronRequest(req, {
    label: "close-day",
    secret: CRON_SECRET,
    parse: parseCloseDayRequest,
    run: (input) =>
      handleCloseDay({ repo: makeRepo(adminClient), pusher }, input),
  })
);
