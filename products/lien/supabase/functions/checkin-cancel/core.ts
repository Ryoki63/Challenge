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
// 写真の実体の削除(2026-10-13・issue #68):
//   - 取り消す行の写真(原寸 photo.jpg とサムネ photo_thumb.jpg)を Storage の photos バケットから消す。
//     #59 の方式ではクライアントが RLS の範囲で署名付き URL を作るので、パスは決定的(pair_id・日付・取り消した人の
//     user_id はすべて相手にも分かる)。行を消すだけだと、相手は取消のあとも同じパスから写真を取れてしまう
//   - 消すパスは**本人の区画だけ**: ① 消した行の photo_path が指す本人の区画(この日のもの)② 現役のペアの、この日の
//     本人の区画(決定的に作る。行に記録される前にアップロードだけ済んだ写真や、前回の取消で掃除に失敗した実体も拾う)。
//     旧形式(ペア×日付単位。2人の行が同じ実体を指しうる)・他人の区画・別の日の区画は消さない
//   - 行が無かった(alreadyCanceled)ときも②は試す: 取消の再送で、前回掃除に失敗した実体を片付ける。
//     存在しないキーの削除は何も起きない(Storage の remove はエラーにしない)
//   - 削除に失敗しても取消は成功(ログだけ残す)。応答の形は変えない
//   - 行の削除が先、実体の削除が後: 行の削除が取消の確定(失敗すれば 500 で、クライアントは同じ要求をやり直せる)で、
//     実体の掃除はその後の付随の処理。逆順だと、行の削除に失敗した(取消できていない)のに写真だけ消えた状態を作りうる
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
import {
  type ApnsSendOptions,
  type LienPushType,
  sendOptionsFor,
} from "../_shared/apns.ts";
import { ownPhotoObjectsOf, photoUploadPaths } from "../_shared/photo_paths.ts";

export interface CheckinCancelRepo extends SnapshotRepo {
  /**
   * 本人の checkins から (user_id, date_local) の行を削除する。
   * 行が無ければ何もしない(deleted: false, photoPath: null)。例外は投げない(行不在はエラーではない)。
   * photoPath は削除した行の photo_path(写真が無ければ null)。写真の実体の掃除に使う(issue #68)
   */
  deleteCheckin(params: {
    userId: string;
    dateLocal: string;
  }): Promise<{ deleted: boolean; photoPath: string | null }>;

  /**
   * photos バケットのオブジェクトを消す(issue #68)。存在しないキーは無視する(エラーにしない)。失敗は例外。
   * 実装は service role(クライアントには delete を許さない — migration 0002・DESIGN §5.2)
   */
  removePhotos(paths: string[]): Promise<void>;
}

/** push 送信口(実装は ApnsClient。テストはモック)。結果の ok は記録用で処理は止めない */
export interface Pusher {
  send(
    deviceToken: string,
    payload: Record<string, unknown>,
    /** pushType / priority(サイレント)と、受信者の users.push_env(sendOptionsFor)。未設定は APNS_ENV */
    opts?: ApnsSendOptions,
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

/**
 * 取り消した日の写真の実体として消すパス(原寸+サムネ。重複なし・順序は安定)。**必ず呼び出し本人の区画**:
 *   ① 消した行の photo_path が指す、本人の区画で、この日(dateLocal)の区画のもの。ペアは問わない
 *      (同じ日のうちにペアを解消して組み直すと、行が前のペアの区画を指していることがある)
 *   ② 現役のペアがあれば、そのペアの、この日の本人の区画(決定的なパス)。行に photo_path が記録される前に
 *      アップロードだけ済んだ写真(DB から辿れない孤児)や、前回の取消で掃除に失敗した実体も拾う
 * 旧形式・他人の区画・別の日の区画・規約外のパスを指す行は、①では何も消さない(rowPhotoPathIgnored で呼び出し側が知る)
 */
export function cancelledPhotoPaths(params: {
  userId: string;
  /** 取り消した日(本人TZの今日) */
  dateLocal: string;
  /** 現役のペア(無ければ null) */
  pairId: string | null;
  /** 消した行の photo_path(行が無い・写真が無ければ null) */
  rowPhotoPath: string | null;
}): { paths: string[]; rowPhotoPathIgnored: boolean } {
  const out = new Set<string>();
  let rowPhotoPathIgnored = false;
  if (params.rowPhotoPath !== null) {
    const own = ownPhotoObjectsOf(params.rowPhotoPath, params.userId);
    if (own && own.dateLocal === params.dateLocal) {
      out.add(own.photo);
      out.add(own.thumb);
    } else {
      rowPhotoPathIgnored = true;
    }
  }
  if (params.pairId !== null) {
    const keys = photoUploadPaths(
      params.pairId,
      params.dateLocal,
      params.userId,
    );
    out.add(keys.photo);
    out.add(keys.thumb);
  }
  return { paths: [...out], rowPhotoPathIgnored };
}

/**
 * 取り消した日の写真の実体を Storage から消す。失敗しても取消は成功(ログだけ残す — issue #68)。
 * ログには値(パス・ID)を出さない(Function のログに個人の識別子を残さない)
 */
async function removeCancelledPhotos(
  repo: Pick<CheckinCancelRepo, "removePhotos">,
  params: Parameters<typeof cancelledPhotoPaths>[0],
): Promise<void> {
  const { paths, rowPhotoPathIgnored } = cancelledPhotoPaths(params);
  if (rowPhotoPathIgnored) {
    console.error(
      "checkin-cancel: 行の photo_path が本人のこの日の区画を指していないため、そのパスの実体は消さない",
    );
  }
  if (paths.length === 0) return;
  try {
    await repo.removePhotos(paths);
  } catch (e) {
    console.error("checkin-cancel: 写真の実体の削除に失敗:", e);
  }
}

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
  const { deleted, photoPath } = await deps.repo.deleteCheckin({
    userId: req.userId,
    dateLocal: req.dateLocal,
  });

  // 3b. 写真の実体(原寸+サムネ)を Storage から消す(issue #68)。相手へ知らせる前に済ませる:
  //     知らせを受けた相手が、まだ残っている実体を取りに行く隙を作らない。失敗しても取消は成功
  const pair = await deps.repo.getActivePair(req.userId);
  await removeCancelledPhotos(deps.repo, {
    userId: req.userId,
    dateLocal: req.dateLocal,
    pairId: pair?.pairId ?? null,
    rowPhotoPath: photoPath,
  });

  // 4. 自分用 snapshot(削除後の状態で組み立てる)
  const snapshot = await loadSnapshotForUser(deps.repo, {
    userId: req.userId,
    now: now(),
    todayLocalOverride: req.dateLocal,
  });

  // 5. 相手へサイレント push(実際に削除が起きたときだけ。ソロ状態は送り先がない)
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
      await deps.pusher.send(
        pair.partner.pushToken,
        payload,
        sendOptionsFor(pair.partner, SILENT_PUSH_OPTS),
      );
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
