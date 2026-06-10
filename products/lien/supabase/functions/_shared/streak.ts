// _shared/streak.ts — ふたりストリークの純粋ロジック(I/O 禁止)
//
// 正本: docs/DESIGN.md §5.4「ストリーク確定アルゴリズム」/ docs/REQUIREMENTS.md §3.5
// - 「日 d のふたり達成」= ペア両メンバーに date_local = d の checkin が存在すること
// - streak_days(pair_id, d, kind) に行があれば「d は継続日」。kind は both | ticket
// - 確定は close-day(毎日 00:10 JST に前日 d を処理)。表示はプレビュー値
//
// このモジュールは date_local("YYYY-MM-DD" 文字列)のみを扱い、時計・TZ・DB に
// 一切依存しない(タイムゾーン解決は呼び出し側 = Edge Function の責務。DESIGN §9)。

export type StreakDayKind = "both" | "ticket";

/** streak_days テーブル1行ぶんの純粋表現 */
export interface StreakDayRecord {
  /** date_local("YYYY-MM-DD") */
  dateLocal: string;
  kind: StreakDayKind;
}

/** close-day が1ペア×1日(前日 d)を確定するための入力 */
export interface CloseDayInput {
  /** 確定対象日 d の date_local */
  dateLocal: string;
  /** pairs.status。active 以外は判定対象外 */
  pairStatus: "active" | "dissolved";
  /** pairs.started_on。これより前の日は判定対象外(ソロ期間はストリークに影響しない) */
  startedOn: string;
  /** メンバーAに date_local = d の checkin があるか */
  memberACheckedIn: boolean;
  /** メンバーBに date_local = d の checkin があるか */
  memberBCheckedIn: boolean;
  /** ペア共有のお休みチケット残数(pairs.ticket_balance) */
  ticketBalance: number;
  /**
   * d に対する事前の「お休み宣言」があるか(ticket_ledger reason='declare' の予約)。
   * 宣言時点でチケットは予約済み(残数減算済み)なので、ここでは追加消費しない。
   */
  restDeclared?: boolean;
  /**
   * d の streak_days 行が既に存在する場合その kind。
   * close-day 再実行の冪等性のため、存在すれば何もしない(skip)。
   */
  existingKind?: StreakDayKind | null;
}

/**
 * close-day の1日確定判定の結果。
 * - skip: 何も書かない(対象外 or 確定済み)
 * - record(both): streak_days(d, 'both') を upsert
 * - record(ticket): streak_days(d, 'ticket') を upsert。consumedNow が true なら
 *   ticket_balance を ticketBalance へ更新し ledger に consume(-1) を記録、
 *   両者へ ticket_used push(いずれも呼び出し側の責務)
 * - reset: 行を作らない(=途切れ)。streak_reset イベント記録と
 *   「責めない文言」での push は呼び出し側の責務(罰・恥の演出は入れない)
 */
export type CloseDayDecision =
  | {
    action: "skip";
    reason: "already_finalized" | "pair_not_active" | "before_started_on";
  }
  | { action: "record"; kind: "both"; ticketBalance: number }
  | {
    action: "record";
    kind: "ticket";
    ticketBalance: number;
    consumedNow: boolean;
  }
  | { action: "reset"; ticketBalance: number };

/**
 * close-day の1日確定判定(DESIGN §5.4 の手順 2〜4)。純粋関数。
 *
 * 判定順:
 * 1. 既に streak_days 行あり → skip(再実行の冪等性)
 * 2. ペアが active でない / started_on より前 → skip
 * 3. 両者 checkin あり → record both
 * 4. 欠けあり(1人でも・2人でも消費は1日1枚):
 *    - お休み宣言済み → record ticket(追加消費なし)
 *    - チケット残あり → record ticket(残数 -1)
 *    - チケットなし → reset
 */
export function decideCloseDay(input: CloseDayInput): CloseDayDecision {
  assertDateLocal(input.dateLocal);
  assertDateLocal(input.startedOn);
  assertTicketBalance(input.ticketBalance);

  if (input.existingKind === "both" || input.existingKind === "ticket") {
    return { action: "skip", reason: "already_finalized" };
  }
  if (input.pairStatus !== "active") {
    return { action: "skip", reason: "pair_not_active" };
  }
  if (dayNumber(input.dateLocal) < dayNumber(input.startedOn)) {
    return { action: "skip", reason: "before_started_on" };
  }

  if (input.memberACheckedIn && input.memberBCheckedIn) {
    return {
      action: "record",
      kind: "both",
      ticketBalance: input.ticketBalance,
    };
  }

  // 欠けあり。「2人とも未達」の日もチケットは1日1枚で守る(人数では数えない)
  if (input.restDeclared) {
    return {
      action: "record",
      kind: "ticket",
      ticketBalance: input.ticketBalance,
      consumedNow: false,
    };
  }
  if (input.ticketBalance > 0) {
    return {
      action: "record",
      kind: "ticket",
      ticketBalance: input.ticketBalance - 1,
      consumedNow: true,
    };
  }
  return { action: "reset", ticketBalance: input.ticketBalance };
}

export interface StreakSummary {
  /** 確定済み最新日(=昨日)から連続する行数 */
  current: number;
  /** 全履歴中の最長連続行数(streak_days から再計算可能な値) */
  best: number;
}

/**
 * streak_days 行の集合から current / best を導出する(DESIGN §5.4「現在値の導出」)。
 *
 * @param days streak_days の行(順不同・重複日許容。kind は both / ticket どちらも継続日)
 * @param asOfDateLocal close-day 確定済みの最新日(通常は「昨日」)の date_local。
 *   この日に行がなければ current = 0(best は履歴から計算される)
 */
export function deriveStreak(
  days: readonly StreakDayRecord[],
  asOfDateLocal: string,
): StreakSummary {
  assertDateLocal(asOfDateLocal);
  const uniqueDayNumbers = [
    ...new Set(days.map((d) => {
      assertDateLocal(d.dateLocal);
      return dayNumber(d.dateLocal);
    })),
  ].sort((a, b) => a - b);

  // best: 最長連続区間
  let best = 0;
  let run = 0;
  for (let i = 0; i < uniqueDayNumbers.length; i++) {
    run = i > 0 && uniqueDayNumbers[i] === uniqueDayNumbers[i - 1] + 1
      ? run + 1
      : 1;
    if (run > best) best = run;
  }

  // current: asOf から降順に連続する行数
  const daySet = new Set(uniqueDayNumbers);
  let current = 0;
  let cursor = dayNumber(asOfDateLocal);
  while (daySet.has(cursor)) {
    current++;
    cursor--;
  }

  return { current, best };
}

/**
 * アプリ/ウィジェット表示用のプレビュー値: current +(今日両者完了なら 1)。
 * 確定はあくまで close-day(DESIGN §5.4)。
 */
export function previewStreak(
  current: number,
  todayBothDone: boolean,
): number {
  if (!Number.isInteger(current) || current < 0) {
    throw new Error(`previewStreak: current が不正です: ${current}`);
  }
  return current + (todayBothDone ? 1 : 0);
}

// ---- date_local ヘルパ(TZ 非依存の純粋な日付計算) ----

const DATE_LOCAL_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

/** "YYYY-MM-DD" でなければ throw。実在しない日付(2026-02-30 等)も拒否する */
export function assertDateLocal(dateLocal: string): void {
  const m = DATE_LOCAL_RE.exec(dateLocal);
  if (!m) throw new Error(`date_local の形式が不正です: ${dateLocal}`);
  const [, y, mo, d] = m;
  const ms = Date.UTC(Number(y), Number(mo) - 1, Number(d));
  const roundTrip = new Date(ms);
  if (
    roundTrip.getUTCFullYear() !== Number(y) ||
    roundTrip.getUTCMonth() !== Number(mo) - 1 ||
    roundTrip.getUTCDate() !== Number(d)
  ) {
    throw new Error(`date_local が実在しない日付です: ${dateLocal}`);
  }
}

/** date_local をエポックからの通算日に変換(TZ 非依存。連続判定・前後比較に使う) */
export function dayNumber(dateLocal: string): number {
  assertDateLocal(dateLocal);
  const [, y, mo, d] = DATE_LOCAL_RE.exec(dateLocal)!;
  return Date.UTC(Number(y), Number(mo) - 1, Number(d)) / 86_400_000;
}

function assertTicketBalance(balance: number): void {
  if (!Number.isInteger(balance) || balance < 0) {
    throw new Error(`ticket_balance が不正です: ${balance}`);
  }
}
