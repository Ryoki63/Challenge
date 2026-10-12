// delete-account/index.ts — POST /functions/v1/delete-account の薄い I/O 層
//
// 本体ロジックは core.ts(deno test 対象)。このファイルは
//   認証 → Supabase リポジトリ実装 → handleDeleteAccount → JSON 応答
// だけを行う。リモート import(supabase-js)はこのファイルに隔離し、
// テストから到達しない(deno test はネットワーク不要 — DESIGN §8)。
//
// 削除は service_role だけができる(auth.admin.deleteUser・Storage の remove・pair_members/pairs の delete。
// クライアントには DELETE の権限が無い — migration 0001)。本文は読まない。対象は JWT 由来の userId 本人だけ。
//
// シークレットはすべて環境変数から(DESIGN §7。ハードコード禁止):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY(Edge Runtime が自動注入)
//   APNS_AUTH_KEY / APNS_KEY_ID / APPLE_TEAM_ID / APNS_ENV / APNS_TOPIC(人間が G0 で設定)

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type DeleteAccountRepo,
  handleDeleteAccount,
  type MembershipRow,
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
import { createPusher } from "../_shared/pusher.ts";
import {
  PARTNER_SELECT,
  toSnapshotUser,
  USER_COLUMNS,
  type UserDbRow,
} from "../_shared/user_rows.ts";

/** PostgREST の既定の上限(1000 行)を超える一覧を、範囲指定で読み切るときのページの大きさ */
const PAGE_SIZE = 1000;

/** auth.admin.deleteUser の「そのユーザーはもう居ない」(やり直しの 2 回目など)。成功として扱う */
function isUserNotFound(error: { status?: number; code?: string }): boolean {
  return error.status === 404 || error.code === "user_not_found";
}

// ---- Supabase リポジトリ実装(書き込み・削除は service_role 経由のみ — DESIGN §5.2) ----

function makeRepo(db: SupabaseClient): DeleteAccountRepo {
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
        .select(PARTNER_SELECT)
        .eq("pair_id", membership.pair_id)
        .neq("user_id", userId)
        .maybeSingle();
      if (e2) throw e2;
      if (!partnerRow) return null;
      return {
        pairId: pair.id,
        startedOn: pair.started_on,
        partner: toSnapshotUser(partnerRow.users as unknown as UserDbRow),
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

    async dissolvePair(
      pairId: string,
      dissolvedAtIso: string,
    ): Promise<boolean> {
      // 条件つき UPDATE(status = 'active' のときだけ)。status と dissolved_at は同時に書く
      // (pairs_dissolved_at_consistency — migration 0001)
      const { data, error } = await db
        .from("pairs")
        .update({ status: "dissolved", dissolved_at: dissolvedAtIso })
        .eq("id", pairId)
        .eq("status", "active")
        .select("id");
      if (error) throw error;
      return (data ?? []).length > 0;
    },

    async listMemberships(userId: string): Promise<MembershipRow[]> {
      const { data, error } = await db
        .from("pair_members")
        .select("pair_id, pairs!inner(id, status, started_on, dissolved_at)")
        .eq("user_id", userId);
      if (error) throw error;
      return (data ?? []).map((row) => {
        const pair = row.pairs as unknown as {
          status: string;
          started_on: string;
          dissolved_at: string | null;
        };
        return {
          pairId: row.pair_id as string,
          startedOn: pair.started_on,
          status: pair.status === "active" ? "active" : "dissolved",
          dissolvedAt: pair.dissolved_at ?? null,
        };
      });
    },

    async listPhotoPaths(userId: string): Promise<string[]> {
      // PostgREST の既定の上限(1000 行)で切れないよう、範囲指定で読み切る
      const paths: string[] = [];
      for (let from = 0;; from += PAGE_SIZE) {
        const { data, error } = await db
          .from("checkins")
          .select("photo_path")
          .eq("user_id", userId)
          .not("photo_path", "is", null)
          .order("date_local", { ascending: true })
          .range(from, from + PAGE_SIZE - 1);
        if (error) throw error;
        const rows = data ?? [];
        for (const row of rows) {
          if (typeof row.photo_path === "string") paths.push(row.photo_path);
        }
        if (rows.length < PAGE_SIZE) break;
      }
      return paths;
    },

    async removePhotos(paths: string[]): Promise<void> {
      // 存在しないキーは無視される(エラーにならない)。バケットは非公開の photos(migration 0001 §6)
      const { error } = await db.storage.from("photos").remove(paths);
      if (error) throw error;
    },

    async deleteMemberships(userId: string): Promise<void> {
      const { error } = await db
        .from("pair_members")
        .delete()
        .eq("user_id", userId);
      if (error) throw error;
    },

    async deleteOrphanPairs(pairIds: string[]): Promise<void> {
      if (pairIds.length === 0) return;
      // メンバーが 1 行でも残っているペアは相手のアーカイブとして残す
      const { data, error } = await db
        .from("pair_members")
        .select("pair_id")
        .in("pair_id", pairIds);
      if (error) throw error;
      const alive = new Set((data ?? []).map((r) => r.pair_id as string));
      const orphans = pairIds.filter((id) => !alive.has(id));
      if (orphans.length === 0) return;
      // plants・streak_days・ticket_ledger・nudges は pairs への ON DELETE CASCADE で連鎖して消える
      const { error: e2 } = await db.from("pairs").delete().in("id", orphans);
      if (e2) throw e2;
    },

    async deleteAuthUser(userId: string): Promise<void> {
      // public.users とそこから CASCADE でつながる本人の行(promises・checkins・reactions・nudges・invites)も消える。
      // 論理削除ではなく物理削除(第 2 引数を渡さない)
      const { error } = await db.auth.admin.deleteUser(userId);
      if (error && !isUserNotFound(error)) throw error;
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
// 設定済みなら、送り先の users.push_env で APNs の環境を選び(getActivePair が push_token と
// 一緒に読んだものを、core が送信オプションの environment に渡す)、無効なトークン
// (410 / BadDeviceToken)は push_token を null にする(DESIGN §4 / issue #53)
const pusher: Pusher = createPusher(adminClient, "delete-account");

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

  try {
    const result = await handleDeleteAccount(
      { repo: makeRepo(adminClient), pusher },
      { userId: authData.user.id },
    );
    return json(result.status, result.body);
  } catch (e) {
    // 途中までの削除は冪等なので、クライアントは同じ要求をやり直せる(auth ユーザーは最後に消す)
    console.error("delete-account: 予期しないエラー:", e);
    return json(500, { error: "internal_error" });
  }
});
