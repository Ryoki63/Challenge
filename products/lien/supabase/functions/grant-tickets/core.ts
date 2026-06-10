// grant-tickets/core.ts — 月次チケット付与 cron(毎月1日 00:05 JST)の本体ロジック
//
// 正本: docs/DESIGN.md §5.3「grant-tickets: free: balance=min(2, balance+2) /
//        premium: balance=min(10, balance+5)」/ docs/REQUIREMENTS.md §3.6 / §5
//   - 付与の算術は _shared/tickets.ts の grantMonthlyTickets(純粋ロジック)を使う
//   - ペアのプレミアム判定は plan カラムではなく**メンバーの premium_until から導出**
//     (REQUIREMENTS §5)。どちらか一方でも premium_until > now なら premium
//   - ledger に reason='monthly' で記録(pairs.ticket_balance は ledger の集計キャッシュ)
//
// 冪等性(再実行の安全):
//   - 同月内に reason='monthly' の ledger 行が既にあるペアはスキップする
//     (00:05 の付与 → 00:10 の close-day 消費 → 再実行、で二重付与しないため、
//      残高ではなく ledger を冪等キーにする)
//   - granted=0(上限到達)のペアは ledger 行を残せない(delta<>0 制約)ため
//     冪等マークが付かないが、付与額も 0 なので再実行しても結果は変わらない

import {
  grantMonthlyTickets,
  type PairPlan,
  TICKET_RULES,
} from "../_shared/tickets.ts";
import { assertDateLocal } from "../_shared/streak.ts";
import { dateLocalInTimeZone, DEFAULT_TIMEZONE } from "../_shared/snapshot.ts";

export { TICKET_RULES };

/**
 * ペアのプラン導出(REQUIREMENTS §5: メンバーの premium_until から。plan カラムは持たない)。
 * いずれかのメンバーの premium_until が now より未来なら premium。
 * null・過去・不正な日時文字列は free 扱い。
 */
export function derivePairPlan(
  premiumUntils: ReadonlyArray<string | null>,
  now: Date,
): PairPlan {
  const nowMs = now.getTime();
  const isPremium = premiumUntils.some((p) => {
    if (p === null) return false;
    const t = new Date(p).getTime();
    return Number.isFinite(t) && t > nowMs;
  });
  return isPremium ? "premium" : "free";
}

/** date_local が属する月の初日("YYYY-MM-01") */
export function monthStartOf(dateLocal: string): string {
  assertDateLocal(dateLocal);
  return `${dateLocal.slice(0, 7)}-01`;
}

/** date_local が属する月の翌月初日(ledger の同月判定の上限・排他) */
export function nextMonthStartOf(dateLocal: string): string {
  assertDateLocal(dateLocal);
  const y = Number(dateLocal.slice(0, 4));
  const m = Number(dateLocal.slice(5, 7));
  const ny = m === 12 ? y + 1 : y;
  const nm = m === 12 ? 1 : m + 1;
  return `${ny}-${String(nm).padStart(2, "0")}-01`;
}

export interface GrantTicketsPairRow {
  pairId: string;
  ticketBalance: number;
  memberIds: [string, string];
}

export interface GrantTicketsRepo {
  /** status='active' の全ペア(解消済みには付与しない) */
  listActivePairs(): Promise<GrantTicketsPairRow[]>;
  /** users.premium_until(ISO8601 | null) */
  getPremiumUntil(userId: string): Promise<string | null>;
  /**
   * 同月(monthStart <= date_local < nextMonthStart)に reason='monthly' の
   * ledger 行が既にあるか(再実行の冪等キー)
   */
  hasMonthlyGrantInMonth(
    pairId: string,
    monthStart: string,
    nextMonthStart: string,
  ): Promise<boolean>;
  updateTicketBalance(pairId: string, balance: number): Promise<void>;
  insertTicketLedger(params: {
    pairId: string;
    delta: number;
    reason: "monthly";
    dateLocal: string;
  }): Promise<void>;
}

export interface GrantTicketsDeps {
  repo: GrantTicketsRepo;
  now?: () => Date;
}

export type GrantTicketsResult =
  | {
    status: 200;
    body: {
      dateLocal: string;
      pairs: number;
      /** 残数が変化し ledger に記録したペア数 */
      granted: number;
      /** 同月付与済み(冪等スキップ)のペア数 */
      alreadyGranted: number;
      /** granted=0(上限到達)で変化なしのペア数 */
      unchanged: number;
      errors: Array<{ pairId: string; message: string }>;
    };
  }
  | { status: 400; body: { error: string } };

/**
 * 月次付与の本体(cron 毎月1日 00:05 JST 想定)。
 * dateLocal 未指定なら now の Asia/Tokyo 日付(= 実行日)を付与日とする。
 * ペア単位でエラーを隔離する(1ペアの失敗で全体を止めない)。
 */
export async function handleGrantTickets(
  deps: GrantTicketsDeps,
  req: { dateLocal?: string } = {},
): Promise<GrantTicketsResult> {
  const now = deps.now ?? (() => new Date());
  const at = now();

  let dateLocal: string;
  try {
    dateLocal = req.dateLocal ?? dateLocalInTimeZone(at, DEFAULT_TIMEZONE);
    assertDateLocal(dateLocal);
  } catch {
    return { status: 400, body: { error: "invalid_date_local" } };
  }
  const monthStart = monthStartOf(dateLocal);
  const nextMonthStart = nextMonthStartOf(dateLocal);

  const pairs = await deps.repo.listActivePairs();
  let granted = 0;
  let alreadyGranted = 0;
  let unchanged = 0;
  const errors: Array<{ pairId: string; message: string }> = [];

  for (const pair of pairs) {
    try {
      if (
        await deps.repo.hasMonthlyGrantInMonth(
          pair.pairId,
          monthStart,
          nextMonthStart,
        )
      ) {
        alreadyGranted++;
        continue;
      }

      const premiumUntils = await Promise.all(
        pair.memberIds.map((id) => deps.repo.getPremiumUntil(id)),
      );
      const plan = derivePairPlan(premiumUntils, at);
      const result = grantMonthlyTickets(pair.ticketBalance, plan);

      // 上限到達(free=2 / premium=10)。delta<>0 制約により ledger 行は残せない
      if (result.granted === 0) {
        unchanged++;
        continue;
      }

      // free へのダウングレード時は granted が負になり得る(min(2, balance+2) への
      // 切り詰め。繰越なし — REQUIREMENTS §3.6)。その場合も ledger に記録する
      await deps.repo.updateTicketBalance(pair.pairId, result.newBalance);
      await deps.repo.insertTicketLedger({
        pairId: pair.pairId,
        delta: result.granted,
        reason: "monthly",
        dateLocal,
      });
      granted++;
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
      granted,
      alreadyGranted,
      unchanged,
      errors,
    },
  };
}
