// grant-tickets/core.ts — 月次チケット付与 cron(毎月1日 00:05 JST)の本体ロジック
//
// 正本: docs/DESIGN.md §5.3「grant-tickets: free: balance=min(2, balance+2) /
//        premium: balance=min(10, balance+5)」/ docs/REQUIREMENTS.md §3.6 / §5
//   - 付与の算術は _shared/tickets.ts の grantMonthlyTickets(純粋ロジック)を使う
//   - ペアのプレミアム判定は plan カラムではなく**メンバーの premium_until から導出**
//     (REQUIREMENTS §5)。どちらか一方でも premium_until > now なら premium
//   - ledger に reason='monthly' で記録(pairs.ticket_balance は ledger の集計キャッシュ)
//
// 冪等性(再実行の安全 — issue #60):
//   - 「このペアの今月分は処理済み」の印は、ペア×月の実行記録(ticket_grant_runs。migration 0006)。
//     付与額が 0 のとき(上限到達)も1行残すので、月の途中に再実行しても、その間にチケットを使った
//     ペアへ再び付与しない。以前は ticket_ledger の monthly 行だけが印で、上限到達のペアには
//     行を残せず(delta<>0 の制約)、再実行で二重付与しえた
//   - 実行記録・残高・ledger は RPC apply_monthly_ticket_grant の1トランザクションで書く
//     (記録だけ残って付与されない、付与されたのに記録が無い、を作らない)
//   - 旧来の印(同月の ledger monthly 行)も「処理済み」と見る。これは 0006 より前の付与との互換だけのものではない:
//     invite-accept の初期付与(reason='monthly'・date_local = started_on。実行記録は作らない)が、今も同じ印を残す。
//     ペアを作った月は、その初期付与がその月の付与にあたる(たとえば月初の 00:05 の直前にできた premium ペアに
//     +5 を上乗せしない。月の途中に付与を再実行しても同じ)。**「旧来の印だから」と消さない**
//   - 未来の月は付与できない(400)。月の付与は実行記録に残って取り消せないので、
//     打ち間違いの dateLocal で先食いして、その月の本当の cron を空振りさせない

import {
  grantMonthlyTickets,
  type PairPlan,
  TICKET_RULES,
} from "../_shared/tickets.ts";
import { assertDateLocal } from "../_shared/streak.ts";
import { dateLocalInTimeZone, DEFAULT_TIMEZONE } from "../_shared/snapshot.ts";
import { type ParseResult, rejectUnknownKeys } from "../_shared/cron_http.ts";

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

/** applyMonthlyGrant の結果 */
export type ApplyGrantOutcome =
  /** 残数が変わり、実行記録と ledger を書いた */
  | "granted"
  /** 付与額が 0(上限到達)。実行記録だけ書いた */
  | "unchanged"
  /** 今月分は既に処理済み(何も書いていない) */
  | "already";

export interface GrantTicketsRepo {
  /** status='active' の全ペア(解消済みには付与しない) */
  listActivePairs(): Promise<GrantTicketsPairRow[]>;
  /** users.premium_until(ISO8601 | null) */
  getPremiumUntil(userId: string): Promise<string | null>;
  /**
   * このペアの今月分は処理済みか(再実行の冪等キー)。
   * 実行記録(ticket_grant_runs の pair_id × month_start)がある、または
   * 同月(monthStart <= date_local < nextMonthStart)に reason='monthly' の ledger 行がある
   * (後者は 0006 より前の付与と、invite-accept の初期付与。どちらも実行記録を作らない)
   */
  hasMonthlyGrantInMonth(
    pairId: string,
    monthStart: string,
    nextMonthStart: string,
  ): Promise<boolean>;
  /**
   * 月次付与の適用(実行記録・残高・ledger を1トランザクションで)。
   * delta は残数の増減(0 = 上限到達。実行記録だけ残す。負 = free へのダウングレードでの切り詰め)。
   * 実行記録が既にあれば何も書かず "already"(競合した2つの実行のうち遅いほうもここで止まる)
   */
  applyMonthlyGrant(params: {
    pairId: string;
    /** 付与する月の月初("YYYY-MM-01") */
    monthStart: string;
    /** ledger に書く日付(通常は月の1日) */
    dateLocal: string;
    delta: number;
  }): Promise<ApplyGrantOutcome>;
}

export interface GrantTicketsDeps {
  repo: GrantTicketsRepo;
  now?: () => Date;
}

/** grant-tickets の要求。cron は本文 `{}`(= JST の今日の月)で呼ぶ */
export interface GrantTicketsRequest {
  /** 付与する月を決める日付(JST の date_local)。省略 = JST の今日。未来の月は 400 */
  dateLocal?: string;
}

/** HTTP 本文(JSON オブジェクト)→ GrantTicketsRequest。許すキーは dateLocal だけ */
export function parseGrantTicketsRequest(
  body: Record<string, unknown>,
): ParseResult<GrantTicketsRequest> {
  const unknown = rejectUnknownKeys(body, ["dateLocal"]);
  if (!unknown.ok) return unknown;
  if (body.dateLocal === undefined) return { ok: true, value: {} };
  if (typeof body.dateLocal !== "string") {
    return { ok: false, error: "invalid_date_local" };
  }
  return { ok: true, value: { dateLocal: body.dateLocal } };
}

export type GrantTicketsResult =
  | {
    status: 200;
    body: {
      dateLocal: string;
      pairs: number;
      /** 残数が変化し ledger に記録したペア数 */
      granted: number;
      /** 今月分は処理済み(冪等スキップ)のペア数。上限到達で 0 付与だったペアの実行記録も含む */
      alreadyGranted: number;
      /** 今回 granted=0(上限到達)で変化なし(実行記録だけ書いた)のペア数 */
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
  req: GrantTicketsRequest = {},
): Promise<GrantTicketsResult> {
  const now = deps.now ?? (() => new Date());
  const at = now();

  const todayJst = dateLocalInTimeZone(at, DEFAULT_TIMEZONE);
  let dateLocal: string;
  try {
    dateLocal = req.dateLocal ?? todayJst;
    assertDateLocal(dateLocal);
  } catch {
    return { status: 400, body: { error: "invalid_date_local" } };
  }
  const monthStart = monthStartOf(dateLocal);
  const nextMonthStart = nextMonthStartOf(dateLocal);
  // 未来の月は付与しない。実行記録が残って、その月の本当の cron が空振りになる
  if (monthStart > monthStartOf(todayJst)) {
    return { status: 400, body: { error: "future_month" } };
  }

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

      // free へのダウングレード時は granted が負になり得る(min(2, balance+2) への
      // 切り詰め。繰越なし — REQUIREMENTS §3.6)。その場合も ledger に記録する。
      // 上限到達(granted = 0)は ledger に行を残せない(delta<>0 制約)が、実行記録は残す
      const outcome = await deps.repo.applyMonthlyGrant({
        pairId: pair.pairId,
        monthStart,
        dateLocal,
        delta: result.granted,
      });
      if (outcome === "granted") granted++;
      else if (outcome === "unchanged") unchanged++;
      else alreadyGranted++;
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
