// _shared/user_rows.ts — users 行の読み出し(push 送信先の取り出し)を各 Function で揃える
//
// 正本: docs/DESIGN.md §4.1(APNs の環境はトークン単位)/ issue #60 項目7
//
// push を送る Function は、送り先の users 行を getUser / getActivePair で読む。そのとき
// **push_token と push_env を必ず一緒に読む**(送信のたびに push_token から users を逆引きしない。
// push_token には索引が無く、逆引きは全件走査になる)。select の列と行の変換をここに集めて、
// 「push_env を読み忘れて APNS_ENV に落ちる」を各 index.ts で起こさない。
//
// supabase-js はここでは import しない(テストをネットワーク不要に保つ — DESIGN §8)。

import { normalizePushEnv } from "./apns.ts";
import { DEFAULT_TIMEZONE, type SnapshotUserRow } from "./snapshot.ts";

/** users から読む列(push_token と push_env は必ず一緒) */
export const USER_COLUMNS = "id, nickname, timezone, push_token, push_env";

/** pair_members から相手の users を結合して読む select(`users` の列は USER_COLUMNS と同じ) */
export const PARTNER_SELECT =
  "user_id, users!inner(id, nickname, timezone, push_token, push_env)";

/** USER_COLUMNS で読んだ users 行(DB の列名のまま) */
export interface UserDbRow {
  id: string;
  nickname: string | null;
  timezone: string | null;
  push_token: string | null;
  push_env: string | null;
}

/** DB の行 → SnapshotUserRow。nickname / timezone の null は既定値に、push_env は想定外の値を null に直す */
export function toSnapshotUser(row: UserDbRow): SnapshotUserRow {
  return {
    id: row.id,
    nickname: row.nickname ?? "",
    timezone: row.timezone ?? DEFAULT_TIMEZONE,
    pushToken: row.push_token ?? null,
    pushEnv: normalizePushEnv(row.push_env),
  };
}
