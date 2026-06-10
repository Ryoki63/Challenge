// checkin/index.ts — POST /functions/v1/checkin の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   認証 → Supabase リポジトリ実装 → handleCheckin → JSON 応答
// だけを行う。リモート import(supabase-js)はこのファイルに隔離し、
// テストから到達しない(deno test はネットワーク不要 — DESIGN §8)。
//
// シークレットはすべて環境変数から(DESIGN §7。ハードコード禁止):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY(Edge Runtime が自動注入)
//   APNS_AUTH_KEY / APNS_KEY_ID / APPLE_TEAM_ID / APNS_ENV / APNS_TOPIC(人間が G0 で設定)

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { type CheckinRepo, handleCheckin, type Pusher } from "./core.ts";
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

function makeRepo(db: SupabaseClient): CheckinRepo {
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

    async upsertCheckin(params): Promise<{
      created: boolean;
      photoUpdated: boolean;
    }> {
      // UNIQUE(user_id, date_local)。重複は無視して created を判定(DESIGN §5.5 冪等)
      const { data: inserted, error: e1 } = await db
        .from("checkins")
        .upsert(
          {
            user_id: params.userId,
            promise_id: params.promiseId,
            date_local: params.dateLocal,
            photo_path: params.photoPath,
          },
          { onConflict: "user_id,date_local", ignoreDuplicates: true },
        )
        .select("id");
      if (e1) throw e1;
      if ((inserted ?? []).length > 0) {
        return { created: true, photoUpdated: false };
      }
      // 既存行あり。photoPath 指定時のみ写真を追加/差し替え(完了後に写真を添える — §3.4)
      if (params.photoPath === null) {
        return { created: false, photoUpdated: false };
      }
      const { data: existing, error: e2 } = await db
        .from("checkins")
        .select("id, photo_path")
        .eq("user_id", params.userId)
        .eq("date_local", params.dateLocal)
        .maybeSingle();
      if (e2) throw e2;
      if (!existing || existing.photo_path === params.photoPath) {
        return { created: false, photoUpdated: false };
      }
      const { error: e3 } = await db
        .from("checkins")
        .update({ photo_path: params.photoPath })
        .eq("id", existing.id);
      if (e3) throw e3;
      return { created: false, photoUpdated: true };
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
    console.warn("checkin: APNs 未設定のため push をスキップ(DESIGN §7 G0)");
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

  let payload: { dateLocal?: unknown; photoPath?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (typeof payload.dateLocal !== "string") {
    return json(400, { error: "invalid_date_local" });
  }
  if (
    payload.photoPath !== undefined && payload.photoPath !== null &&
    typeof payload.photoPath !== "string"
  ) {
    return json(400, { error: "invalid_photo_path" });
  }

  try {
    const result = await handleCheckin(
      { repo: makeRepo(adminClient), pusher },
      {
        userId: authData.user.id,
        dateLocal: payload.dateLocal,
        photoPath: (payload.photoPath as string | null | undefined) ?? null,
      },
    );
    return json(result.status, result.body);
  } catch (e) {
    console.error("checkin: 予期しないエラー:", e);
    return json(500, { error: "internal_error" });
  }
});
