// delete-account/core.ts — POST /delete-account の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/REQUIREMENTS.md §3.15(設定画面のアカウント削除)・§8 / marketing/terms.md 第8条・
//        marketing/privacy-policy.md §6 / docs/DESIGN.md §5.3(delete-account 行)・§5.2(写真のパス規約)
//        / App Store Review Guideline 5.1.1(v)(アカウント作成を許すアプリは、アプリ内からの削除を許す)/ issue #23
//
// アカウントを**完全に**消す。呼び出し本人(JWT 由来の userId)のデータだけが対象で、順序は次のとおり。
// 各手順は冪等で、途中で失敗しても(HTTP 500)クライアントは同じ要求をやり直せる
// (auth ユーザーを最後に消すので、それまでは本人の JWT が有効なまま。やり直しは残りの手順をそのまま続ける):
//
//   1. 現役のペアを解消し、相手へサイレント push(解消後のソロの snapshot 同梱)。pair-dissolve と同じ
//      (_shared/pair_dissolve.ts)。相手のペアの記録(植物・ストリーク)はアーカイブとして残る
//   2. 本人の写真を Storage(photos バケット)から消す。パスは決定的に作る:
//        pairs/<pair_id>/<date_local>/<user_id>/photo.jpg と photo_thumb.jpg(DESIGN §5.2・本人単位の区画)
//      を、所属したことのある全ペアの期間(成立日の前日〜解消日の +2 日)の全日について。checkins.photo_path が指す
//      旧形式(#52 より前の pairs/<pair_id>/<date>/photo.jpg)も、本人の行が指すものに限って消す。
//      存在しないキーの削除は何も起きない(Storage の remove はエラーにしない)ので、取り消した日の写真・
//      行を作る前にアップロードだけ済んだ写真などの取りこぼし(DB から辿れない孤児)も回収できる
//   3. 関連データ(順序が大事 — 各手順を冪等にするため):
//        a. 本人しか所属していないペア(相手が先にアカウントを消していた)を、ペアの行ごと消す
//           (pair_members・plants・streak_days・ticket_ledger・nudges が連鎖して消える)。
//           **所属を消す前に行う**: 先に所属を消すと、このあと失敗してやり直したとき listMemberships が空になり、
//           そのペアの行を辿れずに(植物の名前・ストリーク・台帳が)残り続ける
//        b. 本人のペア所属(pair_members)を消す。相手が残るペアは、相手のアーカイブとして残す
//        c. 念のため、いま所属を消したペアのうち誰も居なくなったものを消す(本人と相手が同時に削除したときの
//           取りこぼし。a は「まだ相手が居る」と見て残し、b のあとには誰も居なくなる)
//   4. auth ユーザーを消す(auth.admin.deleteUser)。public.users と、そこから ON DELETE CASCADE で
//      つながる本人の行(promises・checkins・reactions・nudges・invites。migration 0001)がここで消える。
//      すでに無い(やり直しの 2 回目など)ときは成功として扱う
//
//   - users 行が無くても(データ不整合・やり直し)止まらない: 消すものが無い手順は何もせず、auth ユーザーを消す
//   - 失敗は例外のまま投げる(index.ts が 500 internal_error)。応答の中身は { deleted: true } だけ
//   - push が失敗(ok:false / throw)しても削除は続ける(相手は GET /snapshot の自己修復でも追いつく — DESIGN §4)

import {
  addDaysLocal,
  dateLocalInTimeZone,
  DEFAULT_TIMEZONE,
  loadSnapshotForUser,
  type PairSnapshot,
} from "../_shared/snapshot.ts";
import {
  type ApnsSendOptions,
  type LienPushType,
  sendOptionsFor,
} from "../_shared/apns.ts";
import {
  dissolveActivePair,
  type PairDissolveRepo,
} from "../_shared/pair_dissolve.ts";
import { dayNumber } from "../_shared/streak.ts";

/** 本人が所属した(している)ペア 1 件。解消済みのペア(アーカイブ)も含む */
export interface MembershipRow {
  pairId: string;
  /** pairs.started_on("YYYY-MM-DD") */
  startedOn: string;
  status: "active" | "dissolved";
  /** pairs.dissolved_at(ISO8601)。現役なら null */
  dissolvedAt: string | null;
}

export interface DeleteAccountRepo extends PairDissolveRepo {
  /** 本人が所属した全ペア(pair_members → pairs。解消済みを含む) */
  listMemberships(userId: string): Promise<MembershipRow[]>;
  /** 本人のチェックインが指す photo_path(null を除く。旧形式のパスを拾うため) */
  listPhotoPaths(userId: string): Promise<string[]>;
  /** photos バケットのオブジェクトを消す。存在しないキーは無視する。失敗は例外 */
  removePhotos(paths: string[]): Promise<void>;
  /** 本人の pair_members 行を全部消す */
  deleteMemberships(userId: string): Promise<void>;
  /**
   * 与えたペアのうち、pair_members が 1 行も残っていないペアを消す(連鎖で pair_members・plants など)。
   * exceptUserId を渡すと、その人の所属は「居ないもの」として数える
   * (本人が所属を消す前に、本人しか居ないペアを消すのに使う)
   */
  deleteOrphanPairs(pairIds: string[], exceptUserId?: string): Promise<void>;
  /** auth ユーザーを消す(public.users 以下は ON DELETE CASCADE)。すでに無ければ成功 */
  deleteAuthUser(userId: string): Promise<void>;
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

export interface DeleteAccountDeps {
  repo: DeleteAccountRepo;
  pusher: Pusher;
  now?: () => Date;
}

export interface DeleteAccountRequest {
  userId: string;
}

export type DeleteAccountResult = {
  status: 200;
  body: { deleted: true };
};

/**
 * サイレント更新のペイロード(DESIGN §4。pair-dissolve/core.ts と同型 —
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

// ---- 写真のパス ----

/** Storage の remove に 1 回で渡すパスの数(API の上限に余裕を持たせる) */
export const REMOVE_CHUNK_SIZE = 100;

/** 1 ペアについて探す最大の日数(約 10 年)。データ不整合で巨大な範囲を作らないための安全弁 */
export const MAX_DAYS_PER_PAIR = 3700;

const PHOTO_FILE = "photo.jpg";
const THUMB_FILE = "photo_thumb.jpg";
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

/** 'pairs/<pair_id>/<date>/[<user_id>/]photo.jpg' の区画に分けた photo_path。規約に合わなければ null */
function parseReferencedPath(path: string): {
  pairId: string;
  dir: string;
  ownerId: string | null;
} | null {
  const parts = path.split("/");
  if (parts.length !== 4 && parts.length !== 5) return null;
  if (parts[0] !== "pairs" || !DATE_PATTERN.test(parts[2])) return null;
  if (parts[parts.length - 1] !== PHOTO_FILE) return null;
  if (parts.some((p) => p === "" || p === "." || p === "..")) return null;
  return {
    pairId: parts[1],
    dir: parts.slice(0, -1).join("/"),
    ownerId: parts.length === 5 ? parts[3] : null,
  };
}

/** 日付の早い方 */
function minDate(a: string, b: string): string {
  return dayNumber(a) <= dayNumber(b) ? a : b;
}

/**
 * 消す写真のパスを作る(決定的。重複なし・順序は安定)。
 *   - 所属した各ペアの期間(成立日の前日 〜 解消日の翌々日。現役なら今日の翌日)の全日の
 *     pairs/<pair_id>/<date>/<user_id>/photo.jpg と photo_thumb.jpg。
 *     解消日の +2 日は、UTC 表記の解消時刻とユーザーのタイムゾーンのずれ、解消の直前に発行された署名付き
 *     アップロード URL(2 時間有効)で日付をまたいだアップロードを見込む余裕
 *   - checkins.photo_path が指すパス(旧形式 pairs/<pair_id>/<date>/photo.jpg を含む)とそのサムネ。
 *     ただし**本人の区画のもの、または旧形式で、所属したペアのもの**だけ(他人の区画や規約に合わないパスは無視する)
 */
export function photoPathsToRemove(params: {
  userId: string;
  memberships: readonly MembershipRow[];
  referencedPaths: readonly string[];
  /** 本人のタイムゾーンでの今日(date_local) */
  todayLocal: string;
}): string[] {
  const out = new Set<string>();
  const tomorrow = addDaysLocal(params.todayLocal, 1);

  for (const m of params.memberships) {
    const upper = m.status === "dissolved" && m.dissolvedAt
      ? minDate(addDaysLocal(m.dissolvedAt.slice(0, 10), 2), tomorrow)
      : tomorrow;
    // 成立日の前日から: タイムゾーンが違うと、本人の date_local が started_on より 1 日前になりうる
    // (checkin は本人の「今日」の ±1 日を許す)。DB から辿れない孤児(行を作る前にアップロードだけ済んだ写真)も拾う
    let from = addDaysLocal(m.startedOn, -1);
    if (dayNumber(from) > dayNumber(upper)) continue;
    if (dayNumber(upper) - dayNumber(from) + 1 > MAX_DAYS_PER_PAIR) {
      from = addDaysLocal(upper, -(MAX_DAYS_PER_PAIR - 1));
    }
    for (
      let d = from;
      dayNumber(d) <= dayNumber(upper);
      d = addDaysLocal(d, 1)
    ) {
      const dir = `pairs/${m.pairId}/${d}/${params.userId}`;
      out.add(`${dir}/${PHOTO_FILE}`);
      out.add(`${dir}/${THUMB_FILE}`);
    }
  }

  const pairIds = new Set(params.memberships.map((m) => m.pairId));
  for (const raw of params.referencedPaths) {
    const parsed = parseReferencedPath(raw);
    if (!parsed || !pairIds.has(parsed.pairId)) continue;
    if (parsed.ownerId !== null && parsed.ownerId !== params.userId) continue;
    out.add(`${parsed.dir}/${PHOTO_FILE}`);
    out.add(`${parsed.dir}/${THUMB_FILE}`);
  }
  return [...out];
}

function chunk<T>(items: readonly T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}

// ---- 本体 ----

export async function handleDeleteAccount(
  deps: DeleteAccountDeps,
  req: DeleteAccountRequest,
): Promise<DeleteAccountResult> {
  const now = deps.now ?? (() => new Date());
  const { repo } = deps;

  const user = await repo.getUser(req.userId);

  // 1. 現役のペアを解消して、相手へサイレント push(相手のペアの記録はアーカイブとして残る)
  const outcome = await dissolveActivePair(repo, {
    userId: req.userId,
    now: now(),
  });
  const partner = outcome.partner;
  const partnerToken = partner?.pushToken ?? null;
  if (outcome.dissolved && partner && partnerToken) {
    try {
      const partnerSnapshot = await loadSnapshotForUser(repo, {
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
      // 削除は続ける(相手は GET /snapshot の自己修復でも追いつく — DESIGN §4)
      console.error("delete-account: push 送信に失敗:", e);
    }
  }

  // 2. 写真(Storage)。DB の行より先に消す: 先に行(auth ユーザー)を消すと、あとから写真の持ち主を辿れない
  const memberships = await repo.listMemberships(req.userId);
  const referencedPaths = await repo.listPhotoPaths(req.userId);
  const paths = photoPathsToRemove({
    userId: req.userId,
    memberships,
    referencedPaths,
    todayLocal: dateLocalInTimeZone(
      now(),
      user?.timezone ?? DEFAULT_TIMEZONE,
    ),
  });
  for (const part of chunk(paths, REMOVE_CHUNK_SIZE)) {
    await repo.removePhotos(part);
  }

  // 3. 関連データ(ペアの所属)。順序の理由は冒頭のコメント: 本人しか居ないペアを先にペアごと消し、そのあとで本人の所属を消す
  const pairIds = memberships.map((m) => m.pairId);
  await repo.deleteOrphanPairs(pairIds, req.userId); // a
  await repo.deleteMemberships(req.userId); // b
  await repo.deleteOrphanPairs(pairIds); // c

  // 4. auth ユーザー(public.users 以下は連鎖して消える)。最後に消す = ここまでの失敗はやり直せる
  await repo.deleteAuthUser(req.userId);

  return { status: 200, body: { deleted: true } };
}
