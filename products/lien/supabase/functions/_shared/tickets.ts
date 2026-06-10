// _shared/tickets.ts — お休みチケットの純粋ロジック(I/O 禁止)
//
// 正本: docs/DESIGN.md §5.3(grant-tickets)/ docs/REQUIREMENTS.md §3.6
// - ペア共有在庫。無料: 毎月1日に2枚付与(繰越なし、上限2)
// - プレミアム: 毎月5枚(繰越あり、上限10)
// - 自動消費(優先)+ 事前の「お休み宣言」(明日休む、を相手に通知してチケット予約)
//
// 自動消費の判定そのもの(close-day の文脈)は streak.ts の decideCloseDay が担い、
// 本モジュールは残数の算術と宣言(declare)の検証を提供する。

import { assertDateLocal, dayNumber } from "./streak.ts";

export type PairPlan = "free" | "premium";

/** プランごとの月次付与ルール(DESIGN §5.3 grant-tickets) */
export const TICKET_RULES: Record<PairPlan, { grant: number; cap: number }> = {
  free: { grant: 2, cap: 2 }, // 繰越なし(上限 = 付与数)
  premium: { grant: 5, cap: 10 }, // 繰越あり
};

export interface GrantResult {
  newBalance: number;
  /**
   * 実際に付与された枚数(ledger reason='monthly' の delta)。
   * 0 のときは残数変化なし(上限到達)なので ledger 記録は不要。
   */
  granted: number;
}

/**
 * 毎月1日 00:05 JST の月次付与(grant-tickets cron の純粋部分)。
 * free: min(2, balance+2) / premium: min(10, balance+5)
 */
export function grantMonthlyTickets(
  balance: number,
  plan: PairPlan,
): GrantResult {
  assertBalance(balance);
  const { grant, cap } = TICKET_RULES[plan];
  const newBalance = Math.min(cap, balance + grant);
  return { newBalance, granted: newBalance - balance };
}

export type ConsumeResult =
  | { consumed: true; newBalance: number }
  | { consumed: false; newBalance: number };

/**
 * チケット1枚の消費(close-day の自動消費で使う)。
 * 残数 0 のときは消費せず残数そのまま(リセット側の分岐へ)。
 */
export function consumeTicket(balance: number): ConsumeResult {
  assertBalance(balance);
  if (balance <= 0) return { consumed: false, newBalance: balance };
  return { consumed: true, newBalance: balance - 1 };
}

export type DeclareRestResult =
  | {
    ok: true;
    newBalance: number;
    /** ticket_ledger へ記録する内容(reason='declare') */
    ledger: { delta: -1; reason: "declare"; dateLocal: string };
  }
  | {
    ok: false;
    reason: "no_ticket" | "already_declared" | "date_not_in_future";
  };

/**
 * 事前の「お休み宣言」(REQUIREMENTS §3.6)。
 * 翌日以降の日付を指定してチケットを1枚予約する(宣言時点で残数を減らす)。
 * 当該日の close-day は restDeclared=true として扱い、追加消費しない
 * (streak.ts decideCloseDay 参照)。相手への通知は呼び出し側の責務。
 */
export function declareRest(params: {
  /** 現在のペア共有チケット残数 */
  balance: number;
  /** 宣言者のローカル今日(date_local) */
  todayLocal: string;
  /** 休む日(date_local)。今日より後であること */
  targetDateLocal: string;
  /** 既に宣言済みの日付一覧(ticket_ledger reason='declare' の date_local) */
  declaredDates?: readonly string[];
}): DeclareRestResult {
  assertBalance(params.balance);
  assertDateLocal(params.todayLocal);
  assertDateLocal(params.targetDateLocal);
  const declared = params.declaredDates ?? [];
  declared.forEach(assertDateLocal);

  if (dayNumber(params.targetDateLocal) <= dayNumber(params.todayLocal)) {
    return { ok: false, reason: "date_not_in_future" };
  }
  if (declared.includes(params.targetDateLocal)) {
    return { ok: false, reason: "already_declared" };
  }
  if (params.balance <= 0) {
    return { ok: false, reason: "no_ticket" };
  }
  return {
    ok: true,
    newBalance: params.balance - 1,
    ledger: { delta: -1, reason: "declare", dateLocal: params.targetDateLocal },
  };
}

function assertBalance(balance: number): void {
  if (!Number.isInteger(balance) || balance < 0) {
    throw new Error(`ticket_balance が不正です: ${balance}`);
  }
}
