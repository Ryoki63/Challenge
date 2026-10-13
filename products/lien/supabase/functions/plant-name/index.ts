// plant-name/index.ts — POST /functions/v1/plant-name の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   認証 → Supabase リポジトリ実装 → handlePlantName → JSON 応答
// だけを行う。リモート import(supabase-js)はこのファイルに隔離し、
// テストから到達しない(deno test はネットワーク不要 — DESIGN §8)。
//
// plants への書き込みは service_role のみ(RLS/GRANT — migration 0001)。
// クライアントはこの Function 経由でのみ植物の名前を付けられる(DESIGN §5.2)。
//
// シークレットはすべて環境変数から(DESIGN §7。ハードコード禁止):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY(Edge Runtime が自動注入)
//   APNS_AUTH_KEY / APNS_KEY_ID / APPLE_TEAM_ID / APNS_ENV / APNS_TOPIC(人間が G0 で設定)

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { handlePlantName, type PlantNameRepo, type Pusher } from "./core.ts";
import type {
  SnapshotCheckinRow,
  SnapshotPairRow,
  SnapshotPlantRow,
  SnapshotPromiseRow,
  SnapshotUserRow,
} from "../_shared/snapshot.ts";
import type { StreakDayKind, StreakDayRecord } from "../_shared/streak.ts";
import { createPusher } from "../_shared/pusher.ts";
import {
  ACTIVE_PAIR_SELECT,
  type PairDbRow,
  toSnapshotPair,
} from "../_shared/pair_rows.ts";
import {
  PARTNER_SELECT,
  toSnapshotUser,
  USER_COLUMNS,
  type UserDbRow,
} from "../_shared/user_rows.ts";

// ---- Supabase リポジトリ実装(書き込みは service_role 経由のみ — DESIGN §5.2) ----

function makeRepo(db: SupabaseClient): PlantNameRepo {
  return {
    async getUser(userId: string): Promise<SnapshotUserRow | null> {
      const { data, error } = await db
        .from("users")
        .select(USER_COLUMNS)
        .eq("id", userId)
        .maybeSingle();
      if (error) throw error;
      if (!data) return null;
      return toSnapshotUser(data);
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
        .select(ACTIVE_PAIR_SELECT)
        .eq("user_id", userId)
        .eq("pairs.status", "active")
        .maybeSingle();
      if (e1) throw e1;
      if (!membership) return null;
      const pair = membership.pairs as unknown as PairDbRow;
      const { data: partnerRow, error: e2 } = await db
        .from("pair_members")
        .select(PARTNER_SELECT)
        .eq("pair_id", membership.pair_id)
        .neq("user_id", userId)
        .maybeSingle();
      if (e2) throw e2;
      if (!partnerRow) return null;
      return toSnapshotPair(
        pair,
        toSnapshotUser(partnerRow.users as unknown as UserDbRow),
      );
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

    async setPlantNameIfUnset(pairId: string, name: string): Promise<boolean> {
      // name IS NULL の行だけを更新する。同時に2人が first を送っても、書けるのは先に着いた1人だけ
      // (後の人は 0 行更新=false を受け取り、core が決まった名前を読み直して 409 を返す)
      const { data, error } = await db
        .from("plants")
        .update({ name })
        .eq("pair_id", pairId)
        .is("name", null)
        .select("pair_id");
      if (error) throw error;
      return (data ?? []).length > 0;
    },

    async setPlantName(pairId: string, name: string): Promise<void> {
      const { error } = await db
        .from("plants")
        .update({ name })
        .eq("pair_id", pairId);
      if (error) throw error;
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

// APNs 設定が未投入(G0 前)の間は push なしで運転する(処理自体は止めない)。
// 設定済みなら、送り先の users.push_env で APNs の環境を選び(getUser / getActivePair が push_token と
// 一緒に読んだものを、各 core が送信オプションの environment に渡す。逆引きはしない — issue #60)、
// 無効なトークン(410 / BadDeviceToken)は push_token を null にする(DESIGN §4 / issue #53)
const pusher: Pusher = createPusher(adminClient, "plant-name");

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

  let payload: { name?: unknown; mode?: unknown } | null;
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  // JSON の `null` など、オブジェクトでない本文は 400。null のまま payload.x を読むと
  // TypeError になり、JSON でない 500 が返ってしまう
  if (typeof payload !== "object" || payload === null) {
    return json(400, { error: "invalid_json" });
  }
  if (typeof payload.name !== "string") {
    return json(400, { error: "invalid_name" });
  }
  if (typeof payload.mode !== "string") {
    return json(400, { error: "invalid_mode" });
  }

  try {
    const result = await handlePlantName(
      { repo: makeRepo(adminClient), pusher },
      { userId: authData.user.id, name: payload.name, mode: payload.mode },
    );
    return json(result.status, result.body);
  } catch (e) {
    console.error("plant-name: 予期しないエラー:", e);
    return json(500, { error: "internal_error" });
  }
});
