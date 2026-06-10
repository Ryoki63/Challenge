// checkin-cancel/core.ts — POST /checkin-cancel の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/DESIGN.md §5.3「checkin-cancel: 当日のみ削除 → 相手へサイレント更新」
//        / §4(サイレントプッシュ = content-available: 1。配送保証なしのフォールバック扱い)
//        / docs/REQUIREMENTS.md §3.4「取り消しは当日中のみ可(誤タップ対応)」
//
// 日付ガード(checkin との違い):
//   - checkin は時計ずれ許容で ±1日を受けるが、取り消しは「当日中のみ」が仕様の本体。
//     本人TZの今日(date_local)と厳密一致のみ許可し、過去日・未来日は 400 で拒否する
//
// 冪等性(DESIGN §5.5 と同方針):
//   - 該当 checkin が既に無い場合も 200(alreadyCanceled: true)。リトライ・二重送信に安全
//   - 実際に削除が起きたときだけ相手へサイレント push(冪等リトライで push を二重発火させない)
//
// サイレントプッシュ(DESIGN §4):
//   - aps は { "content-available": 1 } のみ。alert / sound / mutable-content は付けない
//   - lien.snapshot に受信者視点の PairSnapshot を同梱(可視 push と同じ自己修復データ)
//   - 配送保証がない(OSスロットル)ため失敗しても本処理は成功扱い。
//     受信側はフォアグラウンド復帰時の GET /snapshot で自己修復する

import { assertDateLocal } from "../_shared/streak.ts";
import {
  dateLocalInTimeZone,
  loadSnapshotForUser,
  type PairSnapshot,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";
import type { LienPushType } from "../_shared/apns.ts";

export interface CheckinCancelRepo extends SnapshotRepo {
  /**
   * 本人の checkins から (user_id, date_local) の行を削除する。
   * 行が無ければ何もしない(deleted: false)。例外は投げない(行不在はエラーではない)。
   */
  deleteCheckin(params: {
    userId: string;
    dateLocal: string;
  }): Promise<{ deleted: boolean }>;
}

/** push 送信口(実装は ApnsClient。テストはモック)。結果の ok は記録用で処理は止めない */
export interface Pusher {
  send(
    deviceToken: string,
    payload: Record<string, unknown>,
    opts?: { pushType?: "alert" | "background"; priority?: number },
  ): Promise<{ ok: boolean }>;
}

export interface CheckinCancelDeps {
  repo: CheckinCancelRepo;
  pusher: Pusher;
  now?: () => Date;
}

export interface CheckinCancelRequest {
  userId: string;
  /** 本人のローカル日付 "YYYY-MM-DD"。本人TZの「今日」と一致する場合のみ削除可(§3.4) */
  dateLocal: string;
}

export type CheckinCancelResult =
  | {
    status: 200;
    body: { alreadyCanceled: boolean; snapshot: PairSnapshot };
  }
  | { status: 400 | 404; body: { error: string } };

/**
 * サイレント更新のペイロード(DESIGN §4)。
 * 通知 UI を出さず、受信側アプリがバックグラウンドで snapshot を App Group に反映する。
 * type は既存 LienPushType の "pair_update"(ペア状態の更新通知)を使う。
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

export async function handleCheckinCancel(
  deps: CheckinCancelDeps,
  req: CheckinCancelRequest,
): Promise<CheckinCancelResult> {
  const now = deps.now ?? (() => new Date());

  // 1. 入力検証
  try {
    assertDateLocal(req.dateLocal);
  } catch {
    return { status: 400, body: { error: "invalid_date_local" } };
  }

  const user = await deps.repo.getUser(req.userId);
  if (!user) {
    return { status: 404, body: { error: "user_not_found" } };
  }

  // 2. 日付ガード: 本人TZの「今日」と厳密一致のみ(取り消しは当日中のみ — §3.4。
  //    過去日も未来日も拒否。遡及取り消しを許すとストリーク確定(close-day)と矛盾する)
  const todayLocal = dateLocalInTimeZone(now(), user.timezone);
  if (req.dateLocal !== todayLocal) {
    return { status: 400, body: { error: "date_local_not_today" } };
  }

  // 3. 削除(行が無ければ冪等に 200 — 既に取消済み扱い)
  const { deleted } = await deps.repo.deleteCheckin({
    userId: req.userId,
    dateLocal: req.dateLocal,
  });

  // 4. 自分用 snapshot(削除後の状態で組み立てる)
  const snapshot = await loadSnapshotForUser(deps.repo, {
    userId: req.userId,
    now: now(),
    todayLocalOverride: req.dateLocal,
  });

  // 5. 相手へサイレント push(実際に削除が起きたときだけ。ソロ状態は送り先がない)
  const pair = await deps.repo.getActivePair(req.userId);
  if (pair && deleted && pair.partner.pushToken) {
    try {
      const partnerSnapshot = await loadSnapshotForUser(deps.repo, {
        userId: pair.partner.id,
        now: now(),
        todayLocalOverride: req.dateLocal,
      });
      const payload = buildSilentPushPayload({
        type: "pair_update",
        snapshot: partnerSnapshot,
      });
      // 送信失敗(ok: false)でも本処理は成功扱い(サイレントはフォールバック — DESIGN §4)
      await deps.pusher.send(pair.partner.pushToken, payload, SILENT_PUSH_OPTS);
    } catch (e) {
      // pusher が throw しても取り消し自体は成功させる(自己修復経路がある)
      console.error("checkin-cancel: push 送信に失敗:", e);
    }
  }

  return {
    status: 200,
    body: { alreadyCanceled: !deleted, snapshot },
  };
}
