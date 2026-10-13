// _shared/photo_paths.ts — 写真オブジェクト(Storage の `photos` バケット)のパス規約
//
// 正本: docs/DESIGN.md §5.2(写真のパスは **本人単位**: 'pairs/<pair_id>/<date_local>/<user_id>/photo.jpg'、
//        サムネは同じ区画の 'photo_thumb.jpg'。2026-10-12 決定・issue #52)/ migration 0004 の is_valid_own_photo_upload
//
// 使い手:
//   - checkin: 署名付きアップロード URL を発行するパス(photoUploadPaths)・photoPath の検査(isOwnPhotoPath)・
//     写真を差し替えたときに古い実体を消す(ownPhotoObjectsOf。issue #68)
//   - checkin-cancel: 取り消す日の写真の実体を消す(issue #68)
//   (delete-account は所属した全ペアの期間を数え上げて消す独自の組み立てを持つ — delete-account/core.ts)
//
// 消すパスは必ず**呼び出し本人の区画**(`.../<user_id>/photo.jpg` と `photo_thumb.jpg`)に限る。
// photo_path は本人の行にしか入らない(checkin が isOwnPhotoPath で検査してから書く)が、
// 削除の側でも本人の区画かを検査し直す(多重の守り: 他人の写真を消す経路を作らない)。
// supabase-js はここでは import しない(テストをネットワーク不要に保つ — DESIGN §8)。

/** 原寸のファイル名 */
export const PHOTO_FILE = "photo.jpg";
/** サムネ(NSE 用)のファイル名 */
export const THUMB_FILE = "photo_thumb.jpg";

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

/** 原寸とサムネの2オブジェクトのパス */
export interface PhotoObjectPaths {
  photo: string;
  thumb: string;
}

/** 本人の区画の写真(ownPhotoObjectsOf の結果): 2オブジェクトのパスと、パスの ペア ID・日付の区画 */
export interface OwnPhotoObjects extends PhotoObjectPaths {
  pairId: string;
  dateLocal: string;
}

/**
 * 写真オブジェクトのパス規約(DESIGN §5.2 / migration 0004 の storage ポリシーと一致):
 *   'pairs/<pair_id>/<date_local>/<user_id>/photo.jpg' / 'photo_thumb.jpg'
 * user_id 区画で本人単位にする(旧: 'pairs/<pair_id>/<date_local>/photo.jpg' はペア×日付単位で、
 * 同じ日に2人目が付けると上書きされた — issue #52)。user_id は呼び出し本人(認証済み)。
 */
export function photoUploadPaths(
  pairId: string,
  dateLocal: string,
  userId: string,
): PhotoObjectPaths {
  const dir = `pairs/${pairId}/${dateLocal}/${userId}`;
  return { photo: `${dir}/${PHOTO_FILE}`, thumb: `${dir}/${THUMB_FILE}` };
}

/**
 * checkin の photoPath が「本人の」原寸写真パスか。
 * 'pairs/<pair_id>/<YYYY-MM-DD>/<user_id>/photo.jpg' に厳密一致するときだけ true
 * (相手の区画・旧形式・サムネ・余計な階層はすべて false)。
 * 日付区画は形式のみ検査する(storage ポリシーと同じ。±1日の許容は dateLocal 側のガードが担う)
 */
export function isOwnPhotoPath(
  photoPath: string,
  pairId: string,
  userId: string,
): boolean {
  const parts = photoPath.split("/");
  return parts.length === 5 &&
    parts[0] === "pairs" &&
    parts[1] === pairId &&
    DATE_PATTERN.test(parts[2]) &&
    parts[3] === userId &&
    parts[4] === PHOTO_FILE;
}

/**
 * photoPath(checkins.photo_path)が**本人の区画**の原寸写真を指しているなら、その原寸とサムネのパスを返す。
 * ペアは問わない(同じ日のうちにペアを解消して組み直すと、行が前のペアの区画を指していることがある)。
 * 次のものは null(消さない): 他人の区画・旧形式(ペア×日付単位 'pairs/<pair_id>/<date>/photo.jpg'。
 * 2人の行が同じ実体を指しうるので、片方の取消で相手の分まで消さない)・サムネのパス・規約に合わないパス・
 * '.' / '..' / 空の区画を含むパス。
 * 日付の区画(dateLocal)も返す: 行(user, date_local)が消してよいのは、自分の日付の区画だけ。
 * checkin は photoPath の日付区画を形式しか検査しない(storage ポリシーと同じ)ので、日付が違うパスを指す行は
 * ありうる(改造クライアント)。呼び出し側は行の日付と一致するときだけ消す(別の日の行の写真を巻き込まない)
 */
export function ownPhotoObjectsOf(
  photoPath: string,
  userId: string,
): OwnPhotoObjects | null {
  if (userId === "") return null;
  const parts = photoPath.split("/");
  if (parts.length !== 5) return null;
  const [root, pairId, dateLocal, owner, file] = parts;
  if (root !== "pairs" || file !== PHOTO_FILE || owner !== userId) return null;
  if (!DATE_PATTERN.test(dateLocal)) return null;
  if (pairId === "" || pairId === "." || pairId === "..") return null;
  const dir = `${root}/${pairId}/${dateLocal}/${owner}`;
  return {
    photo: `${dir}/${PHOTO_FILE}`,
    thumb: `${dir}/${THUMB_FILE}`,
    pairId,
    dateLocal,
  };
}
