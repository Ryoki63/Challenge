// nudge/core.ts — POST /nudge の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/REQUIREMENTS.md §3.7「つつく(ナッジ)」/ docs/DESIGN.md §5.3(nudge 行)
//        / §5.5(レート制限は Function 内で当日カウント)/ §4(可視push)
//
// 仕様の要点(REQUIREMENTS §3.7):
//   - 相手が未完のときだけ押せる(相手の当日 checkin が既にあれば 409)
//   - 1日3回まで(送り手TZの date_local 基準。4回目以降は 429)
//   - 自由テキスト入力は入れない(スタンプ6種のみ。語彙外は 400)
//   - 通知は相手のニックネーム名義ではなく「送り手」名義(つついた人の名前で届く —
//     DESIGN §4 の相手起点通知の原則どおり。alert.title = pushDisplayName(送り手))
//
// レート制限の数え方(DESIGN §5.5「当日カウント」/ nudges テーブルに date_local 列は無い —
//   created_at(timestamptz)のみ):
//   - repo.listNudgesToday は「直近(当日を含みうる)nudge の created_at 一覧」を返す注入口。
//     実装(index.ts)側は直近 24h+α を service_role で取得すれば十分(厳密な範囲フィルタは
//     core 側が送り手TZで date_local 化して判定するので、取りすぎても過少にはならない)。
//   - core 側で dateLocalInTimeZone(createdAt, user.timezone) === todayLocal の行だけを数える。
//     これにより「送り手TZの当日」の境界を日付跨ぎでも正しく判定できる(TZ変換はサーバーの正本
//     dateLocalInTimeZone に一本化し、ここで独自の UTC 範囲計算を行わない)

import {
  dateLocalInTimeZone,
  loadSnapshotForUser,
  type PairSnapshot,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";
import {
  type ApnsSendOptions,
  buildVisiblePushPayload,
  sendOptionsFor,
} from "../_shared/apns.ts";
import {
  NUDGE_STAMPS,
  nudgeBody,
  pushDisplayName,
} from "../_shared/messages.ts";

/** 1日あたりのつつき上限(REQUIREMENTS §3.7「1日3回まで」) */
export const NUDGE_DAILY_LIMIT = 3;

export interface NudgeRepo extends SnapshotRepo {
  /**
   * 直近の nudge 送信記録(created_at の一覧)。レート制限判定のため、
   * 送り手の当日分を含むのに十分な範囲(実装は直近24h超を取得すれば安全)を返す。
   * 判定自体は core 側で送り手TZの date_local に変換して行う。
   */
  listRecentNudgesBySender(params: {
    pairId: string;
    fromUserId: string;
  }): Promise<ReadonlyArray<{ createdAtIso: string }>>;

  /** nudges へ1行追加する */
  insertNudge(params: {
    pairId: string;
    fromUserId: string;
    stamp: string;
  }): Promise<void>;
}

/** push 送信口(実装は ApnsClient。テストはモック)。結果の ok は記録用で処理は止めない */
export interface Pusher {
  send(
    deviceToken: string,
    payload: Record<string, unknown>,
    /** environment は受信者の users.push_env(sendOptionsFor)。未設定は APNS_ENV */
    opts?: ApnsSendOptions,
  ): Promise<{ ok: boolean }>;
}

export interface NudgeDeps {
  repo: NudgeRepo;
  pusher: Pusher;
  now?: () => Date;
  /** 文言選択の乱数(テストで固定する) */
  random?: () => number;
}

export interface NudgeRequest {
  userId: string;
  /** NUDGE_STAMPS のいずれか(語彙外は 400) */
  stamp: string;
}

export type NudgeResult =
  | {
    status: 200;
    body: { remainingToday: number; snapshot: PairSnapshot };
  }
  | { status: 400 | 404 | 409 | 429; body: { error: string } };

/**
 * 送り手TZの「当日」に送られた nudge の件数を数える(DESIGN §5.5)。
 * created_at(timestamptz)しか無いため、各行を送り手TZで date_local 化して todayLocal と比較する。
 */
function countNudgesToday(
  records: ReadonlyArray<{ createdAtIso: string }>,
  timezone: string,
  todayLocal: string,
): number {
  let count = 0;
  for (const r of records) {
    const dateLocal = dateLocalInTimeZone(new Date(r.createdAtIso), timezone);
    if (dateLocal === todayLocal) count++;
  }
  return count;
}

export async function handleNudge(
  deps: NudgeDeps,
  req: NudgeRequest,
): Promise<NudgeResult> {
  const now = deps.now ?? (() => new Date());
  const random = deps.random ?? Math.random;

  // 1. 語彙検証(自由テキストは入れない方針 — §3.7)
  if (!NUDGE_STAMPS.includes(req.stamp)) {
    return { status: 400, body: { error: "invalid_stamp" } };
  }

  const user = await deps.repo.getUser(req.userId);
  if (!user) {
    return { status: 404, body: { error: "user_not_found" } };
  }

  // 2. ペア必須(ソロはつつく相手がいない)
  const pair = await deps.repo.getActivePair(req.userId);
  if (!pair) {
    return { status: 409, body: { error: "no_pair" } };
  }

  const todayLocal = dateLocalInTimeZone(now(), user.timezone);

  // 3. 相手が未完のときだけ押せる(§3.7)。相手が既にチェックイン済みなら拒否
  const partnerCheckin = await deps.repo.getCheckin(
    pair.partner.id,
    todayLocal,
  );
  if (partnerCheckin) {
    return { status: 409, body: { error: "partner_already_done" } };
  }

  // 4. レート制限(送り手TZの当日。1日3回まで — §3.7 / DESIGN §5.5)
  const recent = await deps.repo.listRecentNudgesBySender({
    pairId: pair.pairId,
    fromUserId: req.userId,
  });
  const sentToday = countNudgesToday(recent, user.timezone, todayLocal);
  if (sentToday >= NUDGE_DAILY_LIMIT) {
    return { status: 429, body: { error: "nudge_limit_exceeded" } };
  }

  // 5. 記録
  await deps.repo.insertNudge({
    pairId: pair.pairId,
    fromUserId: req.userId,
    stamp: req.stamp,
  });

  // 6. 自分用 snapshot(送信後の状態。nudge は snapshot フィールドを変えないが、
  //    レスポンス形を他 function と揺らさないため同梱する)
  const snapshot = await loadSnapshotForUser(deps.repo, {
    userId: req.userId,
    now: now(),
    todayLocalOverride: todayLocal,
  });

  // 7. 相手へ可視 push(DESIGN §4。相手起点の通知と異なり、ここでは「送り手」名義で届く —
  //    つつかれた側が「誰につつかれたか」を把握できることが §3.7 の目的)
  if (pair.partner.pushToken) {
    try {
      const partnerSnapshot = await loadSnapshotForUser(deps.repo, {
        userId: pair.partner.id,
        now: now(),
        todayLocalOverride: todayLocal,
      });
      const payload = buildVisiblePushPayload({
        title: pushDisplayName(user.nickname),
        body: nudgeBody(req.stamp, random),
        type: "nudge",
        snapshot: partnerSnapshot,
      });
      // 送信失敗(ok: false)でも本処理は成功扱い(DESIGN §5.5 と同方針 — 自己修復経路がある)
      await deps.pusher.send(
        pair.partner.pushToken,
        payload,
        sendOptionsFor(pair.partner),
      );
    } catch (e) {
      console.error("nudge: push 送信に失敗:", e);
    }
  }

  return {
    status: 200,
    body: { remainingToday: NUDGE_DAILY_LIMIT - (sentToday + 1), snapshot },
  };
}
