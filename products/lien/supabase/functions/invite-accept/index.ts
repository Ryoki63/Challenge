// invite-accept/index.ts — POST /functions/v1/invite-accept の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   認証 → Supabase リポジトリ実装 → handleInviteAccept → JSON 応答
// だけを行う。リモート import(supabase-js)はこのファイルに隔離し、
// テストから到達しない(deno test はネットワーク不要 — DESIGN §8)。
//
// SnapshotRepo 部分は checkin/index.ts と同型の読み取り実装
// (_shared に置けるのは現行構成のままという制約のため重複を許容 — T04 と同じ判断)。

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  handleInviteAccept,
  type InviteAcceptRepo,
  type InviteRow,
} from "./core.ts";
import type {
  SnapshotCheckinRow,
  SnapshotPairRow,
  SnapshotPlantRow,
  SnapshotPromiseRow,
  SnapshotUserRow,
} from "../_shared/snapshot.ts";
import type { StreakDayKind, StreakDayRecord } from "../_shared/streak.ts";
import { ApnsClient, loadApnsConfigFromEnv } from "../_shared/apns.ts";
import type { Pusher } from "../checkin/core.ts";

function makeRepo(db: SupabaseClient): InviteAcceptRepo {
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

    // ---- 招待・ペア作成 ----
    async getInvite(token: string): Promise<InviteRow | null> {
      const { data, error } = await db
        .from("invites")
        .select("token, from_user, expires_at, used_at")
        .eq("token", token)
        .maybeSingle();
      if (error) throw error;
      if (!data) return null;
      return {
        token: data.token,
        fromUser: data.from_user,
        expiresAtIso: data.expires_at,
        usedAtIso: data.used_at ?? null,
      };
    },

    async claimInvite(token: string, usedAtIso: string): Promise<boolean> {
      // UPDATE ... WHERE used_at IS NULL(同時受諾の競合をここで決着 — core.ts 参照)
      const { data, error } = await db
        .from("invites")
        .update({ used_at: usedAtIso })
        .eq("token", token)
        .is("used_at", null)
        .select("token");
      if (error) throw error;
      return (data ?? []).length > 0;
    },

    async createPair(params): Promise<{ pairId: string }> {
      const { data, error } = await db
        .from("pairs")
        .insert({
          status: "active",
          started_on: params.startedOn,
          ticket_balance: params.ticketBalance,
        })
        .select("id")
        .single();
      if (error) throw error;
      return { pairId: data.id };
    },

    async addPairMembers(pairId, userIds): Promise<void> {
      const { error } = await db.from("pair_members").insert(
        userIds.map((userId) => ({ pair_id: pairId, user_id: userId })),
      );
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

    async createPlant(params): Promise<void> {
      const { error } = await db.from("plants").insert({
        pair_id: params.pairId,
        species: params.species,
        grown_days: 0,
        stage: 0,
      });
      if (error) throw error;
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
  };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SERVICE_ROLE_KEY") ?? "";

const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// APNs 設定が未投入(G0 前)の間は push なしで運転する(処理自体は止めない)
const apnsConfig = loadApnsConfigFromEnv((k) => Deno.env.get(k));
const pusher: Pusher = apnsConfig ? new ApnsClient(apnsConfig) : {
  send: () => {
    console.warn(
      "invite-accept: APNs 未設定のため push をスキップ(DESIGN §7 G0)",
    );
    return Promise.resolve({ ok: false });
  },
};

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

  let payload: { token?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (typeof payload.token !== "string") {
    return json(400, { error: "invalid_token" });
  }

  try {
    const result = await handleInviteAccept(
      { repo: makeRepo(adminClient), pusher },
      { userId: authData.user.id, token: payload.token },
    );
    return json(result.status, result.body);
  } catch (e) {
    console.error("invite-accept: 予期しないエラー:", e);
    return json(500, { error: "internal_error" });
  }
});
