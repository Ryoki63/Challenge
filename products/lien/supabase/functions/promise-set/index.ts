// promise-set/index.ts — POST /functions/v1/promise-set の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   認証 → Supabase リポジトリ実装 → handlePromiseSet → JSON 応答
// だけを行う。リモート import(supabase-js)はこのファイルに隔離し、
// テストから到達しない(deno test はネットワーク不要 — DESIGN §8)。
//
// promises への書き込みは service_role のみ(RLS/GRANT — migration 0001)。
// クライアントはこの Function 経由でのみ約束を作成・編集できる(DESIGN §5.2)。
//
// シークレットはすべて環境変数から(DESIGN §7。ハードコード禁止):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY(Edge Runtime が自動注入)
//   APNS_AUTH_KEY / APNS_KEY_ID / APPLE_TEAM_ID / APNS_ENV / APNS_TOPIC(人間が G0 で設定)

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  handlePromiseSet,
  type PromiseRow,
  type PromiseSetRepo,
  type Pusher,
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

// ---- Supabase リポジトリ実装(書き込みは service_role 経由のみ — DESIGN §5.2) ----

/** DB の time 型("HH:MM:SS")→ API 表現 "HH:MM"。null はそのまま */
function toRemindAt(raw: string | null | undefined): string | null {
  return raw ? raw.slice(0, 5) : null;
}

function makeRepo(db: SupabaseClient): PromiseSetRepo {
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

    async upsertActivePromise(
      params,
    ): Promise<{ promise: PromiseRow; created: boolean }> {
      // 現役(archived_at が null)の行があれば同一 id へ UPDATE(FK 継続 — §3.3)
      const { data: existing, error: e1 } = await db
        .from("promises")
        .select("id")
        .eq("user_id", params.userId)
        .is("archived_at", null)
        .maybeSingle();
      if (e1) throw e1;

      if (existing) {
        const { data, error } = await db
          .from("promises")
          .update({
            title: params.title,
            emoji: params.emoji,
            remind_at: params.remindAt,
          })
          .eq("id", existing.id)
          .select("id, title, emoji, remind_at")
          .single();
        if (error) throw error;
        return {
          promise: {
            id: data.id,
            title: data.title,
            emoji: data.emoji,
            remindAt: toRemindAt(data.remind_at),
          },
          created: false,
        };
      }

      // 新規 insert。同時リクエストの競合は unique index
      // promises_one_active_per_user(migration 0001)が防波堤になり、
      // 負けた側は 23505 → 500。クライアントのリトライで次回は UPDATE 経路に乗る
      const { data, error } = await db
        .from("promises")
        .insert({
          user_id: params.userId,
          title: params.title,
          emoji: params.emoji,
          remind_at: params.remindAt,
        })
        .select("id, title, emoji, remind_at")
        .single();
      if (error) throw error;
      return {
        promise: {
          id: data.id,
          title: data.title,
          emoji: data.emoji,
          remindAt: toRemindAt(data.remind_at),
        },
        created: true,
      };
    },
  };
}

// ---- エントリポイント ----

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
      "promise-set: APNs 未設定のため push をスキップ(DESIGN §7 G0)",
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

  // 認証: Authorization: Bearer <ユーザーJWT>(匿名サインイン含む)
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

  let payload: { title?: unknown; emoji?: unknown; remindAt?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (typeof payload.title !== "string") {
    return json(400, { error: "invalid_title" });
  }
  if (typeof payload.emoji !== "string") {
    return json(400, { error: "invalid_emoji" });
  }
  if (
    payload.remindAt !== undefined && payload.remindAt !== null &&
    typeof payload.remindAt !== "string"
  ) {
    return json(400, { error: "invalid_remind_at" });
  }

  try {
    const result = await handlePromiseSet(
      { repo: makeRepo(adminClient), pusher },
      {
        userId: authData.user.id,
        title: payload.title,
        emoji: payload.emoji,
        remindAt: (payload.remindAt as string | null | undefined) ?? null,
      },
    );
    return json(result.status, result.body);
  } catch (e) {
    console.error("promise-set: 予期しないエラー:", e);
    return json(500, { error: "internal_error" });
  }
});
