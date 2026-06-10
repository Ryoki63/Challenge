// checkin/core.ts — POST /checkin の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/DESIGN.md §5.3「checkin: upsert → 両者状態判定 → 相手へ可視push(snapshot同梱)
//        → 自分用snapshot返却」/ §5.5(冪等性)/ §4(ペイロード)/ docs/REQUIREMENTS.md §3.4
//
// 冪等性(DESIGN §5.5):
//   - checkins は UNIQUE(user_id, date_local)。重複リクエストは 200(alreadyCheckedIn: true)
//   - 純粋な重複(写真の追加もない)では push を再送しない(通知の二重発火防止)
//   - push 送信失敗はリトライ1回(apns.ts 側)。失敗しても本処理は成功扱い
//     (受信側はフォアグラウンド復帰時の GET /snapshot で自己修復する — DESIGN §4)
//
// 写真(REQUIREMENTS §3.4「完了後に写真を添える」):
//   - photoPath は任意。チェックイン済みの日に photoPath 付きで再送すると写真を添付/差し替え
//   - パスは 'pairs/<pair_id>/...' 規約(DESIGN §5.2)。ペアの無いソロ状態では受け付けない

import { assertDateLocal, dayNumber } from "../_shared/streak.ts";
import {
  dateLocalInTimeZone,
  loadSnapshotForUser,
  type PairSnapshot,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";
import { buildVisiblePushPayload } from "../_shared/apns.ts";
import {
  partnerCheckinBody,
  photoAttachedBody,
  pushDisplayName,
} from "../_shared/messages.ts";

/** 深夜0時前後のクライアント/サーバー時計ずれの許容幅(日)。遡及チェックインは不可(§3.4) */
const DATE_LOCAL_TOLERANCE_DAYS = 1;

const PHOTO_PATH_MAX_LENGTH = 512;

export interface CheckinRepo extends SnapshotRepo {
  /**
   * checkins へのupsert。
   * - 行が無ければ insert(created: true)
   * - 既存行があれば insert しない(created: false)。photoPath が指定され、既存の
   *   photo_path と異なる場合のみ写真を更新する(photoUpdated: true)
   */
  upsertCheckin(params: {
    userId: string;
    promiseId: string;
    dateLocal: string;
    photoPath: string | null;
  }): Promise<{ created: boolean; photoUpdated: boolean }>;
}

/** push 送信口(実装は ApnsClient。テストはモック)。結果の ok は記録用で処理は止めない */
export interface Pusher {
  send(
    deviceToken: string,
    payload: Record<string, unknown>,
  ): Promise<{ ok: boolean }>;
}

export interface CheckinDeps {
  repo: CheckinRepo;
  pusher: Pusher;
  now?: () => Date;
  /** 文言選択の乱数(テストで固定する) */
  random?: () => number;
}

export interface CheckinRequest {
  userId: string;
  /** 本人のローカル日付 "YYYY-MM-DD"(REQUIREMENTS §3.4) */
  dateLocal: string;
  photoPath?: string | null;
}

export type CheckinResult =
  | {
    status: 200;
    body: { alreadyCheckedIn: boolean; snapshot: PairSnapshot };
  }
  | { status: 400 | 404 | 409; body: { error: string } };

export async function handleCheckin(
  deps: CheckinDeps,
  req: CheckinRequest,
): Promise<CheckinResult> {
  const now = deps.now ?? (() => new Date());
  const random = deps.random ?? Math.random;

  // 1. 入力検証
  try {
    assertDateLocal(req.dateLocal);
  } catch {
    return { status: 400, body: { error: "invalid_date_local" } };
  }
  const photoPath = req.photoPath ?? null;
  if (photoPath !== null && photoPath.length > PHOTO_PATH_MAX_LENGTH) {
    return { status: 400, body: { error: "invalid_photo_path" } };
  }

  const user = await deps.repo.getUser(req.userId);
  if (!user) {
    return { status: 404, body: { error: "user_not_found" } };
  }

  // 2. 日付ガード: 本人TZの「今日」から±1日まで(遡及チェックイン不可 — §3.4。
  //    ±1日は深夜0時前後の時計ずれ・送信キュー再送の許容)
  const todayLocal = dateLocalInTimeZone(now(), user.timezone);
  if (
    Math.abs(dayNumber(req.dateLocal) - dayNumber(todayLocal)) >
      DATE_LOCAL_TOLERANCE_DAYS
  ) {
    return { status: 400, body: { error: "date_local_out_of_range" } };
  }

  // 3. 現役の約束が必要(checkins.promise_id NOT NULL。約束設定 → チェックインの順)
  const promise = await deps.repo.getActivePromise(req.userId);
  if (!promise) {
    return { status: 409, body: { error: "no_promise" } };
  }

  // 4. 写真パスの規約検査('pairs/<pair_id>/...'。DESIGN §5.2)
  const pair = await deps.repo.getActivePair(req.userId);
  if (photoPath !== null) {
    if (!pair || !photoPath.startsWith(`pairs/${pair.pairId}/`)) {
      return { status: 400, body: { error: "invalid_photo_path" } };
    }
  }

  // 5. upsert(UNIQUE(user_id, date_local)。重複は 200 冪等 — DESIGN §5.5)
  const { created, photoUpdated } = await deps.repo.upsertCheckin({
    userId: req.userId,
    promiseId: promise.id,
    dateLocal: req.dateLocal,
    photoPath,
  });

  // 6. 自分用 snapshot(upsert 後の状態で組み立てる)
  const snapshot = await loadSnapshotForUser(deps.repo, {
    userId: req.userId,
    now: now(),
    todayLocalOverride: req.dateLocal,
  });

  // 7. 相手へ可視 push(snapshot 同梱)。新規チェックイン or 写真追加のときだけ送る
  //    (純粋な重複リクエストで通知を二重発火させない)
  if (pair && (created || photoUpdated) && pair.partner.pushToken) {
    try {
      const partnerSnapshot = await loadSnapshotForUser(deps.repo, {
        userId: pair.partner.id,
        now: now(),
        todayLocalOverride: req.dateLocal,
      });
      const body = !created && photoUpdated
        ? photoAttachedBody()
        : partnerCheckinBody(
          { promiseTitle: promise.title, promiseEmoji: promise.emoji },
          random,
        );
      const payload = buildVisiblePushPayload({
        title: pushDisplayName(user.nickname),
        body,
        type: "partner_checkin",
        snapshot: partnerSnapshot,
      });
      // 送信失敗(ok: false)でも本処理は成功扱い(DESIGN §5.5)
      await deps.pusher.send(pair.partner.pushToken, payload);
    } catch (e) {
      // pusher が throw しても checkin 自体は成功させる(自己修復経路がある)
      console.error("checkin: push 送信に失敗:", e);
    }
  }

  return {
    status: 200,
    body: { alreadyCheckedIn: !created, snapshot },
  };
}
