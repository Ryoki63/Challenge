// pair-dissolve/core.ts — POST /pair-dissolve の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/REQUIREMENTS.md §3.2「ペア解消」・§4(UGC 対応: ブロック = ペア解消)・§8
//        / docs/DESIGN.md §5.3(pair-dissolve 行)・§4(サイレントプッシュ)/ issue #23(T23 審査対応一式)
//
// 仕様の要点:
//   - 呼び出し本人が属する現役のペアを解消する(どちらからでも可能)。ペアは JWT 由来の userId から引く
//     (pairId を入力に取らない: 他人のペアを解消できない)。本文は読まない
//   - 解消の中身は _shared/pair_dissolve.ts(status = 'dissolved' + dissolved_at。自分の履歴は残り、
//     共有写真は相互に非表示、植物・ストリークはアーカイブ)
//   - **冪等**: 現役のペアが無い(解消済み・ずっとソロ・同時に相手が先に解消した)ときは 200 で
//     dissolved: false と今のソロの snapshot を返す。通信の失敗で再送されても安全で、クライアントは
//     どちらの応答でも「ソロに戻った」として扱える。相手への push はこのとき送らない(二重通知なし)
//   - 相手へはサイレント push(pair_update・content-available)で、解消後(ソロ)の snapshot を同梱する。
//     通知 UI は出さない(罰・恥の演出を作らない — REQUIREMENTS §3.5。相手のアプリは次に開く・前面に戻る
//     ときの GET /snapshot でも同じ状態に追いつく)。サイレントは配送保証がない(DESIGN §4)ので、
//     送信失敗(ok:false / throw)でも本処理は 200
//   - 応答の snapshot は呼び出し本人視点(ペアが無いソロの形。約束・今日のチェックイン状態は残る)

import { loadSnapshotForUser, type PairSnapshot } from "../_shared/snapshot.ts";
import {
  type ApnsSendOptions,
  type LienPushType,
  sendOptionsFor,
} from "../_shared/apns.ts";
import {
  dissolveActivePair,
  type PairDissolveRepo,
} from "../_shared/pair_dissolve.ts";

export type { PairDissolveRepo };

/** push 送信口(実装は ApnsClient。テストはモック)。結果の ok は記録用で処理は止めない */
export interface Pusher {
  send(
    deviceToken: string,
    payload: Record<string, unknown>,
    /** pushType / priority(サイレント)と、受信者の users.push_env(sendOptionsFor)。未設定は APNS_ENV */
    opts?: ApnsSendOptions,
  ): Promise<{ ok: boolean }>;
}

export interface PairDissolveDeps {
  repo: PairDissolveRepo;
  pusher: Pusher;
  now?: () => Date;
}

export interface PairDissolveRequest {
  userId: string;
}

export type PairDissolveResult =
  | {
    status: 200;
    /**
     * dissolved: このリクエストでペアを解消したか(false = すでにソロだった。どちらもクライアントは同じに扱える)
     * snapshot: 呼び出し本人視点・解消後(ソロの形)
     */
    body: { dissolved: boolean; snapshot: PairSnapshot };
  }
  | { status: 404; body: { error: string } };

/**
 * サイレント更新のペイロード(DESIGN §4。promise-set/core.ts と同型 —
 * _shared 集約は見送り、各 function 内の重複を許容する既存方針に従う)
 */
export function buildSilentPushPayload(params: {
  type: LienPushType;
  /** 受信者視点の PairSnapshot */
  snapshot: PairSnapshot;
}): Record<string, unknown> {
  return {
    aps: { "content-available": 1 },
    lien: { type: params.type, snapshot: params.snapshot },
  };
}

/** APNs のサイレント push は apns-push-type: background / apns-priority: 5 が必須 */
export const SILENT_PUSH_OPTS = {
  pushType: "background",
  priority: 5,
} as const;

export async function handlePairDissolve(
  deps: PairDissolveDeps,
  req: PairDissolveRequest,
): Promise<PairDissolveResult> {
  const now = deps.now ?? (() => new Date());

  const user = await deps.repo.getUser(req.userId);
  if (!user) {
    return { status: 404, body: { error: "user_not_found" } };
  }

  // 1. 解消(現役のペアが無ければ何もしない = 冪等)
  const outcome = await dissolveActivePair(deps.repo, {
    userId: req.userId,
    now: now(),
  });

  // 2. 自分用 snapshot(解消後 = ソロの形)。書き込みのあとに組み立てる
  const snapshot = await loadSnapshotForUser(deps.repo, {
    userId: req.userId,
    now: now(),
  });

  // 3. 解消したときだけ、相手へサイレント push(解消後のソロの snapshot を同梱)
  const partner = outcome.partner;
  const partnerToken = partner?.pushToken ?? null;
  if (outcome.dissolved && partner && partnerToken) {
    try {
      const partnerSnapshot = await loadSnapshotForUser(deps.repo, {
        userId: partner.id,
        now: now(),
      });
      const payload = buildSilentPushPayload({
        type: "pair_update",
        snapshot: partnerSnapshot,
      });
      await deps.pusher.send(
        partnerToken,
        payload,
        sendOptionsFor(partner, SILENT_PUSH_OPTS),
      );
    } catch (e) {
      // 解消の記録自体は成功させる(相手は GET /snapshot の自己修復でも追いつく — DESIGN §4)
      console.error("pair-dissolve: push 送信に失敗:", e);
    }
  }

  return { status: 200, body: { dissolved: outcome.dissolved, snapshot } };
}
