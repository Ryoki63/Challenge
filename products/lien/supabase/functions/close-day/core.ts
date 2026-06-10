// close-day/core.ts — 前日確定 cron(毎日 00:10 JST)の本体ロジック
//
// 正本: docs/DESIGN.md §5.4「ストリーク確定アルゴリズム(これが正本)」/ §5.3 / §5.5
//        / docs/REQUIREMENTS.md §3.5 / §3.6
//
// 確定処理(前日 d を処理):
//   1. pairs.status='active' かつ started_on <= d のペアを列挙
//   2. 両者 checkin あり → streak_days(d,'both') upsert(+植物の成長 grown_days+1)
//   3. 欠けあり → ticket_balance > 0 なら balance-1・streak_days(d,'ticket') upsert・
//      ledger に consume 記録・両者へ ticket_used push(事前お休み宣言済みなら追加消費なし)
//   4. チケットなし → 行を作らない(=途切れ)。streak_reset イベント記録。
//      push は**責めない文言**(messages.ts の reset 系。REQUIREMENTS §3.5)
//
// 1日確定の判定そのものは _shared/streak.ts の decideCloseDay(純粋関数)。
// 本モジュールはペア列挙・DB 反映・push のオーケストレーションを担う。
//
// 冪等性(DESIGN §5.4「close-day の再実行は安全」):
//   - streak_days に d の行が既にあるペアは decideCloseDay が skip を返す
//     → balance・ledger・植物・push のいずれも二重実行されない
//   - reset(行なし)の再実行は再び reset 分岐に入るが、書き込みが無いので
//     実害は push の再送のみ。index 側の cron は1日1回なので許容
//
// 植物の成長(REQUIREMENTS §3.9): grown_days は「ふたり達成日の累計」なので
// kind='both' の確定時のみ +1(ticket の日はストリーク継続だが達成日ではない)。

import {
  assertDateLocal,
  decideCloseDay,
  deriveStreak,
  type StreakDayKind,
} from "../_shared/streak.ts";
import {
  addDaysLocal,
  dateLocalInTimeZone,
  DEFAULT_TIMEZONE,
  derivePlantStage,
  loadSnapshotForUser,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";
import { buildVisiblePushPayload, type LienPushType } from "../_shared/apns.ts";
import {
  streakResetBody,
  systemPushTitle,
  ticketUsedBody,
} from "../_shared/messages.ts";
import type { Pusher } from "../checkin/core.ts";

// DESIGN §5.4 はリセット時の push を要求するが、§4 の type 列挙には reset 用の値が
// まだ無い(followup: DESIGN §4 と _shared/apns.ts の LienPushType へ追記)。
// NSE は未知 type でも snapshot を App Group へ書く想定のため暫定でこの値を使う。
const STREAK_RESET_PUSH_TYPE = "streak_reset" as LienPushType;

export interface CloseDayPairRow {
  pairId: string;
  status: "active" | "dissolved";
  startedOn: string;
  ticketBalance: number;
  memberIds: [string, string];
}

export interface CloseDayRepo extends SnapshotRepo {
  /**
   * 確定対象候補のペア列挙(DESIGN §5.4 手順1)。
   * 実装は status='active' AND started_on <= d で絞ってよい
   * (core 側でも decideCloseDay が同条件を再検査するので過剰に返しても安全)
   */
  listPairsForClose(dateLocal: string): Promise<CloseDayPairRow[]>;
  /** streak_days の d の行の kind(無ければ null)。再実行の冪等キー */
  getStreakDay(
    pairId: string,
    dateLocal: string,
  ): Promise<StreakDayKind | null>;
  /** d に対する事前お休み宣言(ticket_ledger reason='declare')があるか */
  hasRestDeclared(pairId: string, dateLocal: string): Promise<boolean>;
  /** PK(pair_id, date_local) 衝突は無視(冪等 upsert) */
  upsertStreakDay(
    pairId: string,
    dateLocal: string,
    kind: StreakDayKind,
  ): Promise<void>;
  updateTicketBalance(pairId: string, balance: number): Promise<void>;
  insertTicketLedger(params: {
    pairId: string;
    delta: number;
    reason: "consume";
    dateLocal: string;
  }): Promise<void>;
  /** plants.grown_days / stage の更新(kind='both' 確定時のみ呼ばれる) */
  updatePlantGrowth(
    pairId: string,
    grownDays: number,
    stage: number,
  ): Promise<void>;
  /**
   * streak_reset イベントの記録(DESIGN §5.4 手順4)。
   * 専用テーブルが未定義のため実装は構造化ログでよい(followup 参照)
   */
  recordStreakReset(pairId: string, dateLocal: string): Promise<void>;
}

export interface CloseDayDeps {
  repo: CloseDayRepo;
  pusher: Pusher;
  now?: () => Date;
}

export type CloseDayRunResult =
  | {
    status: 200;
    body: {
      /** 確定処理した対象日 d */
      dateLocal: string;
      pairs: number;
      recordedBoth: number;
      recordedTicket: number;
      reset: number;
      skipped: number;
      errors: Array<{ pairId: string; message: string }>;
    };
  }
  | { status: 400; body: { error: string } };

/**
 * close-day の本体(cron 00:10 JST 想定)。
 * dateLocal 未指定なら「Asia/Tokyo の今日の前日」を d とする。
 * ペア単位でエラーを隔離する(1ペアの失敗で全体を止めない)。
 */
export async function handleCloseDay(
  deps: CloseDayDeps,
  req: { dateLocal?: string } = {},
): Promise<CloseDayRunResult> {
  const now = deps.now ?? (() => new Date());
  const at = now();

  let dateLocal: string;
  try {
    dateLocal = req.dateLocal ??
      addDaysLocal(dateLocalInTimeZone(at, DEFAULT_TIMEZONE), -1);
    assertDateLocal(dateLocal);
  } catch {
    return { status: 400, body: { error: "invalid_date_local" } };
  }

  const pairs = await deps.repo.listPairsForClose(dateLocal);
  let recordedBoth = 0;
  let recordedTicket = 0;
  let reset = 0;
  let skipped = 0;
  const errors: Array<{ pairId: string; message: string }> = [];

  for (const pair of pairs) {
    try {
      const outcome = await closeOnePair(deps, pair, dateLocal, at);
      if (outcome === "both") recordedBoth++;
      else if (outcome === "ticket") recordedTicket++;
      else if (outcome === "reset") reset++;
      else skipped++;
    } catch (e) {
      errors.push({
        pairId: pair.pairId,
        message: e instanceof Error ? e.message : String(e),
      });
    }
  }

  return {
    status: 200,
    body: {
      dateLocal,
      pairs: pairs.length,
      recordedBoth,
      recordedTicket,
      reset,
      skipped,
      errors,
    },
  };
}

async function closeOnePair(
  deps: CloseDayDeps,
  pair: CloseDayPairRow,
  dateLocal: string,
  at: Date,
): Promise<"both" | "ticket" | "reset" | "skip"> {
  const [memberA, memberB] = pair.memberIds;
  const [existingKind, aCheckin, bCheckin, restDeclared] = await Promise.all([
    deps.repo.getStreakDay(pair.pairId, dateLocal),
    deps.repo.getCheckin(memberA, dateLocal),
    deps.repo.getCheckin(memberB, dateLocal),
    deps.repo.hasRestDeclared(pair.pairId, dateLocal),
  ]);

  const decision = decideCloseDay({
    dateLocal,
    pairStatus: pair.status,
    startedOn: pair.startedOn,
    memberACheckedIn: aCheckin !== null,
    memberBCheckedIn: bCheckin !== null,
    ticketBalance: pair.ticketBalance,
    restDeclared,
    existingKind,
  });

  // 1. skip(確定済み or 対象外)— 何も書かない・送らない(再実行の冪等性)
  if (decision.action === "skip") return "skip";

  // 2. 両者達成 → streak_days(d,'both') + 植物の成長(ふたり達成の累計 +1)。
  //    push は不要(両者とも checkin 時に partner_checkin を受け取っている)
  if (decision.action === "record" && decision.kind === "both") {
    await deps.repo.upsertStreakDay(pair.pairId, dateLocal, "both");
    const plant = await deps.repo.getPlant(pair.pairId);
    const grownDays = (plant?.grownDays ?? 0) + 1;
    await deps.repo.updatePlantGrowth(
      pair.pairId,
      grownDays,
      derivePlantStage(grownDays),
    );
    return "both";
  }

  // 3. 欠けあり+チケット(自動消費 or 事前お休み宣言)→ 継続
  if (decision.action === "record" && decision.kind === "ticket") {
    await deps.repo.upsertStreakDay(pair.pairId, dateLocal, "ticket");
    if (decision.consumedNow) {
      // 自動消費(宣言済みの日は宣言時に減算・記録済みなので何もしない)
      await deps.repo.updateTicketBalance(pair.pairId, decision.ticketBalance);
      await deps.repo.insertTicketLedger({
        pairId: pair.pairId,
        delta: -1,
        reason: "consume",
        dateLocal,
      });
    }
    // 消費は両者に通知(REQUIREMENTS §3.5「自動消費して継続(消費は両者に通知)」)
    await pushToMembers(deps, pair.memberIds, at, {
      type: "ticket_used",
      body: ticketUsedBody(),
    });
    return "ticket";
  }

  // 4. チケットなし → 行を作らない(=途切れ)。記録と「責めない文言」push のみ
  await deps.repo.recordStreakReset(pair.pairId, dateLocal);
  const { best } = deriveStreak(
    await deps.repo.listStreakDays(pair.pairId),
    dateLocal,
  );
  await pushToMembers(deps, pair.memberIds, at, {
    type: STREAK_RESET_PUSH_TYPE,
    body: streakResetBody(best),
  });
  return "reset";
}

/**
 * ペア両メンバーへ snapshot 同梱の可視 push(システム名義 — close-day はサーバー起点)。
 * DB 反映後に送る(DESIGN §5.5)。失敗しても処理は成功扱い(自己修復経路がある)。
 */
async function pushToMembers(
  deps: CloseDayDeps,
  memberIds: [string, string],
  at: Date,
  message: { type: LienPushType; body: string },
): Promise<void> {
  for (const userId of memberIds) {
    try {
      const user = await deps.repo.getUser(userId);
      if (!user?.pushToken) continue;
      const snapshot = await loadSnapshotForUser(deps.repo, {
        userId,
        now: at,
      });
      const payload = buildVisiblePushPayload({
        title: systemPushTitle(),
        body: message.body,
        type: message.type,
        snapshot,
      });
      await deps.pusher.send(user.pushToken, payload);
    } catch (e) {
      console.error("close-day: push 送信に失敗:", e);
    }
  }
}
