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
// 写真(REQUIREMENTS §3.4「完了後に写真を添える」/ DESIGN §5.6 = issue #48 決定):
//   - photoPath は任意。チェックイン済みの日に photoPath 付きで再送すると写真を添付/差し替え
//   - パスは 'pairs/<pair_id>/...' 規約(DESIGN §5.2)。ペアの無いソロ状態では受け付けない
//   - requestPhotoUpload: true で署名付きアップロードURL(原寸+サムネの2本)を応答に同梱する。
//     クライアントは 縮小 → 2本アップロード → photoPath 付き checkin 再送 の順で添付する(T14)。
//     ソロ状態は写真の置き場所(ペア)が無いため 400 no_pair

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

  /**
   * Storage の署名付きアップロードURLトークンを発行する(DESIGN §5.6 — issue #48)。
   * 実装は storage.from("photos").createSignedUploadUrl(path, { upsert: true })。
   * upsert: true は同日の写真差し替え(REQUIREMENTS §3.4「その日1枚」の貼り直し)用。
   * パスの組み立ては core 側(photoUploadPaths)が行い、ここは署名だけを担う
   */
  createSignedUploadUrl(path: string): Promise<{ token: string }>;
}

// ---- 写真アップロード(DESIGN §5.6) ----

/** 署名付きアップロードURLの1本分(クライアントは path をそのまま photoPath として再送する) */
export interface PhotoUploadTarget {
  path: string;
  token: string;
}

/** 原寸+サムネの2本セット(サムネは NSE 用 200KB 上限 — DESIGN §3.4。縮小はクライアント側) */
export interface PhotoUploadUrls {
  photo: PhotoUploadTarget;
  thumb: PhotoUploadTarget;
}

/**
 * 写真オブジェクトのパス規約(DESIGN §5.6 / migration 0002 の storage ポリシーと一致):
 *   'pairs/<pair_id>/<date_local>/photo.jpg' / 'photo_thumb.jpg'
 */
export function photoUploadPaths(
  pairId: string,
  dateLocal: string,
): { photo: string; thumb: string } {
  const dir = `pairs/${pairId}/${dateLocal}`;
  return { photo: `${dir}/photo.jpg`, thumb: `${dir}/photo_thumb.jpg` };
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
  /** true で署名付きアップロードURL(原寸+サムネ)を応答に同梱(DESIGN §5.6)。ソロは 400 no_pair */
  requestPhotoUpload?: boolean;
}

export type CheckinResult =
  | {
    status: 200;
    body: {
      alreadyCheckedIn: boolean;
      snapshot: PairSnapshot;
      /** requestPhotoUpload: true のときのみ存在 */
      photoUpload?: PhotoUploadUrls;
    };
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

  // 4b. 署名付きアップロードURLの要求はペアが必要(ソロは写真の置き場所が無い — DESIGN §5.6)。
  //     副作用(upsert)の前に検査する
  if (req.requestPhotoUpload && !pair) {
    return { status: 400, body: { error: "no_pair" } };
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

  // 6b. 署名付きアップロードURL発行(DESIGN §5.6)。発行が失敗(throw)した場合は 500 になるが、
  //     checkin 自体は記録済みなのでクライアントの再送(冪等 200)で新しいURLを取り直せる
  let photoUpload: PhotoUploadUrls | undefined;
  if (req.requestPhotoUpload && pair) {
    const paths = photoUploadPaths(pair.pairId, req.dateLocal);
    const photo = await deps.repo.createSignedUploadUrl(paths.photo);
    const thumb = await deps.repo.createSignedUploadUrl(paths.thumb);
    photoUpload = {
      photo: { path: paths.photo, token: photo.token },
      thumb: { path: paths.thumb, token: thumb.token },
    };
  }

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
    body: photoUpload
      ? { alreadyCheckedIn: !created, snapshot, photoUpload }
      : { alreadyCheckedIn: !created, snapshot },
  };
}
