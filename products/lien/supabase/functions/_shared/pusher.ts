// _shared/pusher.ts — 各 Function が使う Pusher の組み立て(APNs 設定 + Supabase の PushTokenStore)
//
// 正本: docs/DESIGN.md §4(APNs の環境はトークン単位・無効トークンの掃除)/ §5.5 / §7(シークレット)
//
// 各 Function の index.ts は `createPusher(adminClient, "<関数名>")` を呼ぶだけでよい:
//   - APNs の secrets が未投入(G0 前)なら push をスキップする no-op を返す(処理は止めない)
//   - 投入済みなら TokenAwarePusher(apns.ts)を返す。送信先の環境(sandbox / production)は
//     呼び出し側が send のオプション(environment)で渡す — 送り先の users 行を読むときに
//     push_token と一緒に push_env も読み、sendOptionsFor(user) で作る(issue #60: 送信のたびに
//     push_token から users を逆引きしない)。渡されなければ APNS_ENV。
//     APNs が 410 / BadDeviceToken を返したトークンは users.push_token を null にする(issue #53)
//
// supabase-js はここでは import しない(テストをネットワーク不要に保つ — DESIGN §8)。
// db は from() だけを持つ構造的型 PushStoreDb で受け、index.ts では SupabaseClient をそのまま渡せる
// (`deno check <function>/index.ts` で確認済み)。クエリの形は pusher_test.ts で固定している。

import {
  ApnsClient,
  type ApnsHttpPost,
  type ApnsSendOptions,
  loadApnsConfigFromEnv,
  type PushTokenStore,
  TokenAwarePusher,
} from "./apns.ts";

// ---- Supabase 版の PushTokenStore(無効トークンの掃除) ----

/**
 * supabase-js のクライアントのうち使う部分(from)だけの構造的型。
 * SupabaseClient の型と直接突き合わせると型のインスタンス化が深くなりすぎる(TS2589)ため、
 * クエリビルダは any で受け、結果は下で形を明示して読む。
 * クエリの形(列名・条件)は pusher_test.ts と本番スモークで固定している
 */
export interface PushStoreDb {
  // deno-lint-ignore no-explicit-any
  from(table: string): any;
}

/**
 * users.push_token を消す実装(service_role の client を渡す)。
 * - 掃除は push_token = そのトークン の行すべて。同じトークンを持つ行が複数あっても
 *   (同じ端末で匿名ユーザーが作り直された等)すべて消す。送信と同時に再登録された新しいトークンは消えない
 * - push_env は消さない(診断用に残す。次回の登録で push_token と同時に上書きされる)
 */
export function makePushTokenStore(db: PushStoreDb): PushTokenStore {
  return {
    async clearPushToken(deviceToken: string): Promise<void> {
      const { error }: { error: unknown } = await db
        .from("users")
        .update({ push_token: null })
        .eq("push_token", deviceToken);
      if (error) throw error;
    },
  };
}

// ---- Pusher の組み立て ----

/** 各 core.ts の Pusher と互換(結果の ok は記録用で、処理は止めない) */
export interface PushSender {
  send(
    deviceToken: string,
    payload: Record<string, unknown>,
    opts?: ApnsSendOptions,
  ): Promise<{ ok: boolean }>;
}

export interface PusherDeps {
  /** 環境変数の読み出し(既定は Deno.env.get。テストで差し替える) */
  getEnv?: (key: string) => string | undefined;
  /** APNs への HTTP 送信(テストでモックする) */
  post?: ApnsHttpPost;
  now?: () => Date;
}

/**
 * Function 用の Pusher を作る。label はログ用の関数名。
 * APNs の環境変数(APNS_AUTH_KEY / APNS_KEY_ID / APPLE_TEAM_ID / APNS_ENV / APNS_TOPIC)が
 * 1つでも欠けていれば、push をスキップする no-op を返す(dev・テスト環境用)。
 * APNS_ENV の値が不正なときは、設定ミスとして throw する(loadApnsConfigFromEnv の仕様)。
 */
export function createPusher(
  db: PushStoreDb,
  label: string,
  deps: PusherDeps = {},
): PushSender {
  const getEnv = deps.getEnv ?? ((key: string) => Deno.env.get(key));
  const config = loadApnsConfigFromEnv(getEnv);
  if (!config) {
    return {
      send: () => {
        console.warn(
          `${label}: APNs 未設定のため push をスキップ(DESIGN §7 G0)`,
        );
        return Promise.resolve({ ok: false });
      },
    };
  }
  return new TokenAwarePusher(
    new ApnsClient(config, { post: deps.post, now: deps.now }),
    makePushTokenStore(db),
  );
}
