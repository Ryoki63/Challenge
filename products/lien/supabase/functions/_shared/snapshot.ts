// _shared/snapshot.ts — 受信者視点 PairSnapshot の組み立て(純粋ロジック+注入リポジトリ)
//
// 正本:
//   - スキーマ: docs/DESIGN.md §3.4(schemaVersion = 1。キー名は一字一句一致。変更時は要レビュー
//     +JOURNAL に互換性影響を明記 — DESIGN §9-7)
//   - 植物の成長/表情: docs/REQUIREMENTS.md §3.9 / docs/GROWTH.md(成長ルール v2。2026-10-12 承認)
//       成長 = ふたり達成日の累計回数。10段階 [0,1,3,7,14,21,30,45,66,100]
//         (たね→ふたば→めばえ→わかば→よりそい→つぼみ→いろづき→ほころび→ふたりざき→みのり)
//       回数は streak_days の kind='both' の行数から数える(plants.grown_days / stage は読まない — §7.2)
//         + 昨日の仮判定(§7.3。close-day が昨日を確定する前の 0:00〜1:00 だけ)+ 今日の先取り
//       表情: normal / happy(両者完了)/ fidget(片方未完)/ sad(=「すやすや」。ふたり達成もお休みチケットも
//         ない日が昨日まで2日以上続く)。枯れない・後退しない
//   - お休みチケットの残数(2026-10-13・issue #19 / REQUIREMENTS §3.6): ticketBalance = pairs.ticket_balance
//       (ペア共有の残数。ホームのバッジ用)。ソロは null(ペアが無いので持ち主がいない)。キーは省略せず null で出す
//   - ペアのプラン(2026-10-20・T33 / REQUIREMENTS §3.14): pairPlan = メンバーの users.premium_until から導出
//       (どちらかが未来なら premium。ソロは free。キーは省略せず必ず出す)
//   - ストリーク導出: docs/DESIGN.md §5.4(確定は close-day。表示はプレビュー値)
//   - 組み立てに使った「今日」(dateLocal。2026-10-20・issue #72): サーバーは checkin / checkin-cancel / nudge の
//     snapshot を、クライアントが送った日付を「今日」として組み立てる(翌日の 1:00 まで有効 — resolveTodayLocal)。
//     そのため「その snapshot の完了フラグがどの日のものか」は updatedAt からは決まらない。dateLocal に
//     **組み立てに使った「今日」**をそのまま載せ、クライアントが完了をその日付で解釈できるようにする
//
// 設計:
//   - snapshot は**受信者視点**でサーバーが組み立てる(me/partner をクライアントで反転しない — §3.4)
//   - buildPairSnapshot / buildSoloSnapshot は DB 行データ→snapshot の純粋関数
//   - loadSnapshotForUser は注入リポジトリ(SnapshotRepo)越しに行を集めて組み立てる
//     オーケストレータ。自身は I/O を持たず、fake repo で deno test 可能
//   - タイムゾーン既定は Asia/Tokyo。日付は date_local("YYYY-MM-DD")のみ扱う(DESIGN §9)

import {
  assertDateLocal,
  dayNumber,
  deriveStreak,
  previewStreak,
  type StreakDayRecord,
} from "./streak.ts";
import { derivePairPlan, type PairPlan } from "./premium.ts";

export const SNAPSHOT_SCHEMA_VERSION = 1;
export const DEFAULT_TIMEZONE = "Asia/Tokyo";

/** 植物の表情(REQUIREMENTS §3.9。枯れ・後退の状態は存在しない) */
export type PlantMood = "normal" | "happy" | "fidget" | "sad";

/**
 * App Group 共有契約 `pair_snapshot.json` の中身(DESIGN §3.4 と一字一句一致)。
 * iOS 側の正本は ios/Lien/Core/Models/PairSnapshot.swift。
 */
export interface PairSnapshot {
  schemaVersion: number;
  /** uuid | null(ソロ状態) */
  pairId: string | null;
  /** ISO8601 */
  updatedAt: string;
  /**
   * この snapshot を組み立てるのに使った「今日」(date_local "YYYY-MM-DD")。`todayMeDone` / `todayPartnerDone` は
   * **この日の**完了(issue #72)。checkin / checkin-cancel / nudge はクライアントが送った日付を「今日」として
   * 組み立てる(翌日の 1:00 まで有効 — CLOSE_DAY_SETTLE_HOUR)ので、`updatedAt` の日付とは 1 日ずれることがある。
   * クライアントはこの日付で完了を解釈する(0:00〜1:00 の「不明」扱いをしない)。古いサーバーはこのキーを
   * 出さない(アプリは無いキーを nil として扱い、updatedAt から保守的に判定する — DESIGN §3.4 の互換性)
   */
  dateLocal: string;
  streakCurrent: number;
  streakBest: number;
  todayMeDone: boolean;
  todayPartnerDone: boolean;
  myPromiseTitle: string | null;
  myPromiseEmoji: string | null;
  partnerName: string | null;
  partnerPromiseTitle: string | null;
  partnerPromiseEmoji: string | null;
  /** 0 = たね(ソロは pairId=null で土を描画)〜 9 = みのり。PLANT_STAGE_THRESHOLDS の添字 */
  plantStage: number;
  /** 成長回数(ふたり達成日の累計 + 昨日の仮判定 + 今日の先取り)。ソロは 0 */
  plantGrownDays: number;
  /** 今の段階に入るのに必要だった回数(= PLANT_STAGE_THRESHOLDS[plantStage])。ソロは 0 */
  plantStageFloor: number;
  /** 次の段階に必要な回数。次の段階が無い(みのり)ときとソロは null */
  plantNextStageAt: number | null;
  plantMood: PlantMood;
  plantName: string | null;
  hasPartnerPhotoToday: boolean;
  /**
   * ペア共有のお休みチケットの残数(pairs.ticket_balance。0 以上の整数)。ホームの残数バッジ用
   * (REQUIREMENTS §3.6 [v1.0])。ソロは null(キーは省略せず null で出す)。ペアの2人に同じ値が見える。
   * 読めていない・不正な値も null(アプリはバッジを出さない)。古いサーバーはこのキー自体を出さない
   * (アプリは無いキーを nil として扱う — DESIGN §3.4 の互換性)
   */
  ticketBalance: number | null;
  /**
   * ペアのプラン(REQUIREMENTS §3.14 / §5)。メンバーの users.premium_until から導出する
   * (plan カラムは持たない)。ソロは "free"。キーは省略せず必ず出す。
   *
   * アプリは「自分の購読 ∪ pairPlan === "premium"」でプレミアムを判定し、
   * 自分の購読が無いのに pairPlan が premium なら「相手がすでにプレミアムなのでこのペアは適用済み」と
   * 表示して、誤課金を防ぐ(REQUIREMENTS §3.14)。古いサーバーはこのキーを出さない(アプリは free として扱う)
   */
  pairPlan: PairPlan;
}

// ---- 植物の導出(REQUIREMENTS §3.9 / GROWTH §3) ----

/**
 * 成長段階の閾値。添字 = 段階番号、値 = その段階に入るのに必要な成長回数(ふたり達成日の累計)。
 * 段階名(たね〜みのり)はアプリ側(Strings)の表示で、サーバーは番号と回数だけを返す。
 *
 * 調整のルール(GROWTH §3.6)。snapshot_test.ts のラチェットテスト(凍結基準)が機械的に守る:
 *   - 閾値は**下げる方向にだけ**動かす(上げると、到達済みのペアの植物が戻って見える)
 *   - 段階は**末尾にだけ**足す(みのり(100回)はあとから延ばせない。延ばしたいときは段階を後ろに足す)
 *   - 変更は2週間に1回まで。変えたら JOURNAL と REQUIREMENTS に記録する
 */
export const PLANT_STAGE_THRESHOLDS: readonly number[] = [
  0, // 段階 0 たね(ペア成立。頭に小さな芽が2つ)
  1, // 段階 1 ふたば(最初のふたり達成)
  3, // 段階 2 めばえ
  7, // 段階 3 わかば
  14, // 段階 4 よりそい
  21, // 段階 5 つぼみ
  30, // 段階 6 いろづき
  45, // 段階 7 ほころび
  66, // 段階 8 ふたりざき(習慣化の目安 66日)
  100, // 段階 9 みのり
];

function assertGrownDays(grownDays: number): void {
  if (!Number.isInteger(grownDays) || grownDays < 0) {
    throw new Error(`成長回数が不正です: ${grownDays}`);
  }
}

/** 成長回数 → 成長段階 0..(段階数-1)。最後の段階(みのり)を超えても後退しない */
export function derivePlantStage(grownDays: number): number {
  assertGrownDays(grownDays);
  for (let stage = PLANT_STAGE_THRESHOLDS.length - 1; stage > 0; stage--) {
    if (grownDays >= PLANT_STAGE_THRESHOLDS[stage]) return stage;
  }
  return 0;
}

/** 成長回数から導く、植物の進み具合(snapshot の plantStage / plantGrownDays / plantStageFloor / plantNextStageAt) */
export interface PlantProgress {
  /** 成長回数(ふたり達成日の累計 + 昨日の仮判定 + 今日の先取り) */
  grownDays: number;
  stage: number;
  /** 今の段階に入るのに必要な回数(PLANT_STAGE_THRESHOLDS[stage]) */
  stageFloor: number;
  /** 次の段階に必要な回数。最後の段階なら null */
  nextStageAt: number | null;
}

/**
 * 成長回数 → 進み具合。アプリは「あと (nextStageAt - grownDays) 回で つぎ」の文と、
 * 区間の進み具合 (grownDays - stageFloor) / (nextStageAt - stageFloor) を、この3つの値だけで作れる
 * (閾値の配列をアプリに持たせない=あとからサーバー側で閾値を下げても、古いアプリが追従する)。
 */
export function derivePlantProgress(grownDays: number): PlantProgress {
  const stage = derivePlantStage(grownDays);
  return {
    grownDays,
    stage,
    stageFloor: PLANT_STAGE_THRESHOLDS[stage],
    nextStageAt: PLANT_STAGE_THRESHOLDS[stage + 1] ?? null,
  };
}

/**
 * streak_days の行から「ふたり達成日(kind='both')」の数を数える(GROWTH §7.2)。
 * - kind='ticket'(お休みチケットで守った日)は数えない: ストリークは守られるが、植物は育たない
 * - 同じ日付の行は1日と数える(PK(pair_id, date_local) があるので通常は重複しないが、防御として)
 * - asOfDateLocal を渡すと、その日までの行だけを数える。表示用の snapshot は「昨日まで」を渡す:
 *   今日の分は「今日の先取り」で別に足すので、今日(以降)の行があっても二重に数えない
 *   (クライアントの時計が少し遅れていて、確定済みの行が「今日」に見えるときなど)
 */
export function countBothDays(
  days: readonly StreakDayRecord[],
  asOfDateLocal?: string,
): number {
  const limit = asOfDateLocal === undefined
    ? Number.POSITIVE_INFINITY
    : dayNumber(asOfDateLocal);
  const counted = new Set<number>();
  for (const d of days) {
    if (d.kind !== "both") continue;
    const n = dayNumber(d.dateLocal); // 形式の検証も兼ねる
    if (n <= limit) counted.add(n);
  }
  return counted.size;
}

/**
 * 植物の表情(REQUIREMENTS §3.9)。
 * - happy: 両者完了のキラキラ
 * - fidget: 片方未完のそわそわ
 * - sad: 2日連続未達成(確定ベースで直近2日が未達成、かつ今日もまだ両者未完)。
 *   アプリでは「すやすや」眠る絵で描く(GROWTH §13.1)。API の値は互換性のため sad のまま
 * - normal: それ以外(枯れ・後退の状態は存在しない)
 */
export function derivePlantMood(params: {
  todayMeDone: boolean;
  todayPartnerDone: boolean;
  /** 確定済み最新日(=昨日)から遡った連続未達成日数(countConsecutiveMissedDays) */
  consecutiveMissedDays: number;
}): PlantMood {
  if (params.todayMeDone && params.todayPartnerDone) return "happy";
  if (params.todayMeDone !== params.todayPartnerDone) return "fidget";
  return params.consecutiveMissedDays >= 2 ? "sad" : "normal";
}

/**
 * asOfDateLocal(通常は昨日=close-day 確定済みの最新日)から遡って、
 * streak_days 行が無い日が何日連続しているかを数える。
 * started_on より前はペアが存在しないので「未達成」と数えない。
 */
export function countConsecutiveMissedDays(params: {
  days: readonly StreakDayRecord[];
  asOfDateLocal: string;
  startedOn: string;
}): number {
  const recorded = new Set(params.days.map((d) => dayNumber(d.dateLocal)));
  const startNum = dayNumber(params.startedOn);
  let cursor = dayNumber(params.asOfDateLocal);
  let missed = 0;
  while (cursor >= startNum && !recorded.has(cursor)) {
    missed++;
    cursor--;
  }
  return missed;
}

// ---- date_local ヘルパ(DESIGN §9: 日付計算は date_local) ----

/** date_local に日数を加算する(TZ 非依存の純粋計算) */
export function addDaysLocal(dateLocal: string, days: number): string {
  if (!Number.isInteger(days)) {
    throw new Error(`days が不正です: ${days}`);
  }
  const n = dayNumber(dateLocal) + days; // dayNumber が形式検証も行う
  return new Date(n * 86_400_000).toISOString().slice(0, 10);
}

/**
 * 時刻 now をユーザーのタイムゾーンで date_local("YYYY-MM-DD")に変換する。
 * 不正な timeZone は既定 Asia/Tokyo にフォールバック(users.timezone の既定値と同じ)。
 */
export function dateLocalInTimeZone(now: Date, timeZone: string): string {
  let formatted: string;
  try {
    formatted = formatDateLocal(now, timeZone);
  } catch {
    formatted = formatDateLocal(now, DEFAULT_TIMEZONE);
  }
  assertDateLocal(formatted);
  return formatted;
}

function formatDateLocal(now: Date, timeZone: string): string {
  // en-CA ロケールは "YYYY-MM-DD" を返す
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

// ---- close-day の確定が済むまでの窓(昨日の仮判定・クライアントの「今日」の上書きに使う) ----

/**
 * close-day が昨日を確定し終えたとみなす時刻(ユーザーのタイムゾーンの「今日」の何時か)。
 * cron は 00:10 JST。実行の遅れや再試行を見込んで 1:00 とする(GROWTH §7.3・T19 の完全版と同じ窓)。
 * 昨日の行が「無い」ことは、確定前と、確定して**リセットされた**後(リセットの日は行を作らない)の
 * どちらでも起きる。この時刻より前だけ「確定前」とみなし、後は行だけを信じる。
 */
export const CLOSE_DAY_SETTLE_HOUR = 1;

/** now のユーザーTZでの現地の日付("YYYY-MM-DD")と時(0〜23)。不正な timeZone は既定 Asia/Tokyo */
export function localDateAndHour(
  now: Date,
  timeZone: string,
): { dateLocal: string; hour: number } {
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = formatLocalParts(now, timeZone);
  } catch {
    parts = formatLocalParts(now, DEFAULT_TIMEZONE);
  }
  const value = (type: Intl.DateTimeFormatPartTypes): string =>
    parts.find((part) => part.type === type)?.value ?? "";
  const dateLocal = `${value("year")}-${value("month")}-${value("day")}`;
  assertDateLocal(dateLocal);
  return { dateLocal, hour: Number(value("hour")) % 24 };
}

function formatLocalParts(
  now: Date,
  timeZone: string,
): Intl.DateTimeFormatPart[] {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    hourCycle: "h23", // 0 時を "24" と出す環境がある。0〜23 に固定する
  }).formatToParts(now);
}

/** now が、ユーザーTZの「dateLocal の hour 時ちょうど」以降か(日付をまたいだ比較に対応) */
export function isAtOrAfterLocalHour(params: {
  now: Date;
  timeZone: string;
  dateLocal: string;
  hour: number;
}): boolean {
  const current = localDateAndHour(params.now, params.timeZone);
  const currentDay = dayNumber(current.dateLocal);
  const targetDay = dayNumber(params.dateLocal);
  if (currentDay !== targetDay) return currentDay > targetDay;
  return current.hour >= params.hour;
}

/**
 * 実効の「今日」(date_local)を決める。
 *  - override 未指定 → now をユーザーTZで date_local 化した日付
 *  - override あり、その日がまだ確定前(翌日の 1:00 より前) → override をそのまま使う。
 *    深夜0時前後のクライアント/サーバー時計ずれや、送信キューの再送を吸収する
 *  - override あり、その日の確定を過ぎている → override は捨てて本当の今日を使う。
 *    close-day が確定した後にキューから届いた「昨日付け」の checkin が、確定済みの昨日を「今日」として
 *    扱い、先取りの +1(段階アップを含む)を一瞬見せて、次の GET /snapshot で戻る、を防ぐ
 */
export function resolveTodayLocal(params: {
  now: Date;
  timeZone: string;
  override?: string;
}): string {
  const actual = dateLocalInTimeZone(params.now, params.timeZone);
  if (params.override === undefined) return actual;
  assertDateLocal(params.override);
  const settled = isAtOrAfterLocalHour({
    now: params.now,
    timeZone: params.timeZone,
    dateLocal: addDaysLocal(params.override, 1),
    hour: CLOSE_DAY_SETTLE_HOUR,
  });
  return settled ? actual : params.override;
}

// ---- snapshot 組み立て(純粋関数) ----

export interface PromiseSummary {
  title: string;
  emoji: string;
}

/**
 * pairs.ticket_balance → snapshot の ticketBalance。0 以上の整数だけ通す。
 * 読めていない(undefined = getActivePair が ticket_balance を読んでいない)・null・不正な値は null:
 * 誤った「0枚」を見せるより、バッジを出さない側に倒す(DB の CHECK(ticket_balance >= 0)があるので、本番で不正な値は来ない)
 */
export function normalizeTicketBalance(
  balance: number | null | undefined,
): number | null {
  return typeof balance === "number" && Number.isInteger(balance) &&
      balance >= 0
    ? balance
    : null;
}

export interface BuildPairSnapshotInput {
  pairId: string;
  /** サーバーが snapshot を組み立てた時刻(ISO8601) */
  updatedAtIso: string;
  /** 受信者視点の「今日」(date_local) */
  todayLocal: string;
  /** pairs.started_on */
  startedOn: string;
  /**
   * streak_days の全行(順不同可)。昨日の仮判定で足した行(provisionalYesterdayRow)を含めて渡す。
   * ストリーク・すやすや(sad)の判定・成長回数のすべてが、この行だけから導かれる
   */
  streakDays: readonly StreakDayRecord[];
  todayMeDone: boolean;
  todayPartnerDone: boolean;
  myPromise: PromiseSummary | null;
  partnerName: string;
  partnerPromise: PromiseSummary | null;
  plantName: string | null;
  hasPartnerPhotoToday: boolean;
  /** pairs.ticket_balance(省略 = 読んでいない → snapshot では null) */
  ticketBalance?: number | null;
  /**
   * ペアのプラン。省略 = メンバーの premium_until を読んでいない → "free"。
   * loadSnapshotForUser は user / partner の premiumUntil から導出して渡す(T33)
   */
  pairPlan?: PairPlan;
}

/**
 * ペア状態の受信者視点 snapshot を組み立てる(DESIGN §3.4)。
 *
 * プレビュー方針(DESIGN §5.4「確定は close-day。表示はプレビュー」):
 * - streakCurrent = 確定 current +(今日両者完了なら 1)
 * - 成長回数 = 昨日までの both の行数 +(今日両者完了なら 1)。翌朝の確定を先取りした表示
 *   (close-day は今日の行をまだ書いていないため二重加算は起きない。今日以降の行は数えない)。
 *   plants.grown_days / stage は読まない: 行から数え直すので、close-day の書き込みが欠けても
 *   成長が欠けない(GROWTH §7.2)
 * - streakBest は確定 best とプレビュー current の大きい方(現在値が最高値を下回って見えないように)
 */
export function buildPairSnapshot(input: BuildPairSnapshotInput): PairSnapshot {
  assertDateLocal(input.todayLocal);
  const yesterday = addDaysLocal(input.todayLocal, -1);
  const { current, best } = deriveStreak(input.streakDays, yesterday);
  const bothToday = input.todayMeDone && input.todayPartnerDone;
  const streakCurrent = previewStreak(current, bothToday);
  const plant = derivePlantProgress(
    countBothDays(input.streakDays, yesterday) + (bothToday ? 1 : 0),
  );
  const consecutiveMissedDays = countConsecutiveMissedDays({
    days: input.streakDays,
    asOfDateLocal: yesterday,
    startedOn: input.startedOn,
  });

  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    pairId: input.pairId,
    updatedAt: input.updatedAtIso,
    dateLocal: input.todayLocal,
    streakCurrent,
    streakBest: Math.max(best, streakCurrent),
    todayMeDone: input.todayMeDone,
    todayPartnerDone: input.todayPartnerDone,
    myPromiseTitle: input.myPromise?.title ?? null,
    myPromiseEmoji: input.myPromise?.emoji ?? null,
    partnerName: input.partnerName,
    partnerPromiseTitle: input.partnerPromise?.title ?? null,
    partnerPromiseEmoji: input.partnerPromise?.emoji ?? null,
    plantStage: plant.stage,
    plantGrownDays: plant.grownDays,
    plantStageFloor: plant.stageFloor,
    plantNextStageAt: plant.nextStageAt,
    plantMood: derivePlantMood({
      todayMeDone: input.todayMeDone,
      todayPartnerDone: input.todayPartnerDone,
      consecutiveMissedDays,
    }),
    plantName: input.plantName,
    hasPartnerPhotoToday: input.hasPartnerPhotoToday,
    ticketBalance: normalizeTicketBalance(input.ticketBalance),
    pairPlan: input.pairPlan ?? "free",
  };
}

/**
 * ソロ状態(ペア未成立)の snapshot。鉢は土だけ=クライアントは pairId=null で土を描画。
 * 植物の進み具合は 0 / 0 / null(ゲージを出さない — GROWTH §5.1)。お休みチケットの残数も null
 * (ペア共有の在庫なので、ペアが無ければ持ち主がいない。バッジを出さない)。
 * todayLocal は組み立てに使った「今日」(dateLocal。ソロでも載せる — クライアントが完了をその日付で解釈する)
 */
export function buildSoloSnapshot(input: {
  updatedAtIso: string;
  /** 組み立てに使った「今日」(date_local) */
  todayLocal: string;
  todayMeDone: boolean;
  myPromise: PromiseSummary | null;
}): PairSnapshot {
  assertDateLocal(input.todayLocal);
  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    pairId: null,
    updatedAt: input.updatedAtIso,
    dateLocal: input.todayLocal,
    streakCurrent: 0,
    streakBest: 0,
    todayMeDone: input.todayMeDone,
    todayPartnerDone: false,
    myPromiseTitle: input.myPromise?.title ?? null,
    myPromiseEmoji: input.myPromise?.emoji ?? null,
    partnerName: null,
    partnerPromiseTitle: null,
    partnerPromiseEmoji: null,
    plantStage: 0,
    plantGrownDays: 0,
    plantStageFloor: 0,
    plantNextStageAt: null,
    plantMood: "normal",
    plantName: null,
    hasPartnerPhotoToday: false,
    ticketBalance: null,
    pairPlan: "free",
  };
}

// ---- 昨日の仮判定(GROWTH §7.3 の最小版) ----

/**
 * 昨日の仮判定を試す価値があるか(= DB に昨日の checkin を問い合わせるか)。
 * 次の3つがそろったときだけ true:
 *   1. いまが close-day の確定前の時間帯(実効の今日 = yesterdayLocal の翌日 の 1:00・ユーザーTZ より前)
 *   2. 昨日の streak_days 行が無い(行があれば確定済み。二重に足さない)
 *   3. 昨日がペア成立日(started_on)以降(成立前は判定対象外)
 * 1 が肝心。昨日の行が無いのは「まだ確定していない」だけでなく「確定してリセットされた」ときも同じで、
 * しかも昨日付けの checkin は close-day の後からでも足せる(checkin は ±1日を許し、iOS の送信キューは
 * 日付をまたいで前日分を再送する)。窓の外で仮判定すると、リセット済みの昨日を「ふたり達成」と見せて
 * 翌日に取り消すことになる(REQUIREMENTS §3.9 / GROWTH §3.2「回数は減らない」に反する)。
 */
export function needsProvisionalYesterday(params: {
  days: readonly StreakDayRecord[];
  yesterdayLocal: string;
  startedOn: string;
  /** いま(窓の判定に使う) */
  now: Date;
  /** ユーザーのタイムゾーン(窓の判定に使う) */
  timeZone: string;
}): boolean {
  const yesterday = dayNumber(params.yesterdayLocal);
  if (yesterday < dayNumber(params.startedOn)) return false;
  if (params.days.some((d) => dayNumber(d.dateLocal) === yesterday)) {
    return false;
  }
  return !isAtOrAfterLocalHour({
    now: params.now,
    timeZone: params.timeZone,
    dateLocal: addDaysLocal(params.yesterdayLocal, 1),
    hour: CLOSE_DAY_SETTLE_HOUR,
  });
}

/**
 * 昨日の仮判定。0:00 から close-day(00:10 JST)が昨日の行を書くまでの間は昨日の行がまだ無く、
 * そのまま数えるとストリークが 0 に見え、昨日の分で上がった段階が 1 つ戻り、
 * すやすや(sad)が誤って出る。次の4つがそろえば、昨日を「ふたり達成(both)」とみなした行を返す
 * (そろわなければ null):
 *   1. いまが close-day の確定前の時間帯(実効の今日の 1:00 より前。CLOSE_DAY_SETTLE_HOUR)
 *   2. 昨日の行がない
 *   3. 昨日がペア成立日(started_on)以降
 *   4. 2人とも昨日チェックインしている
 * 窓の中(確定前)なら、確定結果と一致する: 両者がチェックインしていれば close-day は必ず both を記録し、
 * チェックインの取消は当日しかできないので、昨日のチェックインはもう動かない。
 * 窓の外では一致を保証できないので仮判定しない: 行が無い昨日は「リセット済み」かもしれず、
 * close-day の後に届いた遅れた checkin を数えると、翌日に取り消すことになる(上の needsProvisionalYesterday)。
 * 窓の外は行だけを信じる。close-day が一晩動かなかったときも、行が書かれる(OPS §4 の再実行)まで
 * 確定前の分は数えない=書かれていない日を勝手に増やさない側に倒す。
 * 残る誤差(窓の中の端): close-day が動いた 0:10 以降〜 1:00 の間に、キュー経由で昨日付けの checkin が
 * 届くと、1:00 までは「ふたり達成」と見え、1:00 に消える。極めてまれ。完全に消すには checkins.created_at
 * (その日の 24:00 より前に作られたものだけを数える)が要り、全関数の getCheckin が返す変更になるので、
 * T19 の完全版で扱う。
 * 返した行は、ストリーク・すやすや・成長回数のすべてに使う(buildPairSnapshot の streakDays に足す)。
 * 「片方だけチェックインしてチケットで守られる日」は仮判定できない(0:00〜0:10 の間だけ
 * ストリークが 0 に見える)。close-day が送る ticket_used 通知の snapshot で直る(§7.3)
 */
export function provisionalYesterdayRow(params: {
  days: readonly StreakDayRecord[];
  yesterdayLocal: string;
  startedOn: string;
  now: Date;
  timeZone: string;
  meCheckedInYesterday: boolean;
  partnerCheckedInYesterday: boolean;
}): StreakDayRecord | null {
  if (!needsProvisionalYesterday(params)) return null;
  if (!params.meCheckedInYesterday || !params.partnerCheckedInYesterday) {
    return null;
  }
  return { dateLocal: params.yesterdayLocal, kind: "both" };
}

// ---- 注入リポジトリ越しの組み立て(I/O は持たない。実装は各 function の index.ts) ----

export interface SnapshotUserRow {
  id: string;
  nickname: string;
  timezone: string;
  pushToken: string | null;
  /**
   * pushToken が属する APNs 環境(users.push_env。null / 省略 = 未設定 → 送信時は APNS_ENV)。
   * push_token と一緒に読み、pusher.send の environment に渡す(sendOptionsFor — issue #60)。
   * snapshot の組み立て自体は使わない
   */
  pushEnv?: "sandbox" | "production" | null;
  /**
   * users.premium_until(ISO8601 | null)。snapshot の pairPlan の導出に使う(T33)。
   * 省略 = 読んでいない(古い実装・テスト) → free 扱い。push の送信先としては使わない
   */
  premiumUntil?: string | null;
}

export interface SnapshotPromiseRow extends PromiseSummary {
  id: string;
}

export interface SnapshotPairRow {
  pairId: string;
  startedOn: string;
  /**
   * pairs.ticket_balance(ペア共有のお休みチケットの残数)。snapshot の ticketBalance になる(issue #19)。
   * 実装は _shared/pair_rows.ts の ACTIVE_PAIR_SELECT / toSnapshotPair で読む。省略 = 読んでいない(null として出す)
   */
  ticketBalance?: number;
  partner: SnapshotUserRow;
}

export interface SnapshotCheckinRow {
  photoPath: string | null;
}

export interface SnapshotPlantRow {
  /**
   * plants.grown_days(close-day が数え直して書く控え)。snapshot の組み立てでは**読まない**:
   * 成長回数は streak_days の行から数える(GROWTH §7.2)。型を残しているのは、
   * 各 function の index.ts(getPlant の実装)を変えずに済ませるため
   */
  grownDays: number;
  name: string | null;
}

/** snapshot 組み立てに必要な読み取り口。実装(Supabase)は index.ts 側、テストは fake */
export interface SnapshotRepo {
  getUser(userId: string): Promise<SnapshotUserRow | null>;
  /** 現役(archived_at が null)の約束。1人1つ(REQUIREMENTS §3.3) */
  getActivePromise(userId: string): Promise<SnapshotPromiseRow | null>;
  /** 自分が属する active なペアと相手。v1 は1ユーザー1ペア(REQUIREMENTS §1) */
  getActivePair(userId: string): Promise<SnapshotPairRow | null>;
  getCheckin(
    userId: string,
    dateLocal: string,
  ): Promise<SnapshotCheckinRow | null>;
  listStreakDays(pairId: string): Promise<StreakDayRecord[]>;
  getPlant(pairId: string): Promise<SnapshotPlantRow | null>;
}

/**
 * userId 視点の PairSnapshot を組み立てる(checkin の自分用/相手用と GET /snapshot で共用)。
 *
 * todayLocalOverride: checkin 直後の組み立てでは、リクエストの dateLocal を「今日」として
 * 使う(深夜0時前後のクライアント/サーバー時計ずれで todayMeDone が false に見えるのを防ぐ)。
 * 未指定なら now をユーザーの timezone で date_local 化する。
 * ただし override の日がすでに確定済み(翌日の 1:00 を過ぎている)なら捨てて、本当の今日を使う
 * (resolveTodayLocal。close-day の後にキューから届いた昨日付けの checkin に、先取りの +1 を見せない)。
 * 解決した「今日」は snapshot の **dateLocal** に載せる(クライアントはそれで完了を解釈する。issue #72)。
 * ※ ペアは国内(同一TZ)前提(REQUIREMENTS §3.4。時差ペアの厳密対応は v2+)
 */
export async function loadSnapshotForUser(
  repo: SnapshotRepo,
  params: { userId: string; now: Date; todayLocalOverride?: string },
): Promise<PairSnapshot> {
  const user = await repo.getUser(params.userId);
  if (!user) {
    throw new Error(
      `loadSnapshotForUser: user が見つからない: ${params.userId}`,
    );
  }
  const todayLocal = resolveTodayLocal({
    now: params.now,
    timeZone: user.timezone,
    override: params.todayLocalOverride,
  });
  assertDateLocal(todayLocal);
  const updatedAtIso = params.now.toISOString();

  const myPromise = await repo.getActivePromise(params.userId);
  const myCheckin = await repo.getCheckin(params.userId, todayLocal);
  const pair = await repo.getActivePair(params.userId);

  if (!pair) {
    return buildSoloSnapshot({
      updatedAtIso,
      todayLocal,
      todayMeDone: myCheckin !== null,
      myPromise,
    });
  }

  const partnerPromise = await repo.getActivePromise(pair.partner.id);
  const partnerCheckin = await repo.getCheckin(pair.partner.id, todayLocal);
  const confirmedDays = await repo.listStreakDays(pair.pairId);
  const plant = await repo.getPlant(pair.pairId);

  // 昨日の仮判定(GROWTH §7.3)。close-day が昨日を確定する前の時間帯(実効の今日の 1:00 より前)で、
  // 昨日の行がまだ無いときだけ、昨日の checkin を2回(自分・相手)引く
  const yesterdayLocal = addDaysLocal(todayLocal, -1);
  let streakDays = confirmedDays;
  if (
    needsProvisionalYesterday({
      days: confirmedDays,
      yesterdayLocal,
      startedOn: pair.startedOn,
      now: params.now,
      timeZone: user.timezone,
    })
  ) {
    const [meYesterday, partnerYesterday] = await Promise.all([
      repo.getCheckin(params.userId, yesterdayLocal),
      repo.getCheckin(pair.partner.id, yesterdayLocal),
    ]);
    const provisional = provisionalYesterdayRow({
      days: confirmedDays,
      yesterdayLocal,
      startedOn: pair.startedOn,
      now: params.now,
      timeZone: user.timezone,
      meCheckedInYesterday: meYesterday !== null,
      partnerCheckedInYesterday: partnerYesterday !== null,
    });
    if (provisional) streakDays = [...confirmedDays, provisional];
  }

  return buildPairSnapshot({
    pairId: pair.pairId,
    updatedAtIso,
    todayLocal,
    startedOn: pair.startedOn,
    streakDays,
    todayMeDone: myCheckin !== null,
    todayPartnerDone: partnerCheckin !== null,
    myPromise,
    partnerName: pair.partner.nickname,
    partnerPromise,
    plantName: plant?.name ?? null,
    hasPartnerPhotoToday: partnerCheckin?.photoPath != null,
    ticketBalance: pair.ticketBalance,
    // プレミアム判定はメンバーの premium_until から導出(REQUIREMENTS §5)。
    // どちらかが読めていなければ free 側に倒れる(derivePairPlan)
    pairPlan: derivePairPlan(
      [user.premiumUntil, pair.partner.premiumUntil],
      params.now,
    ),
  });
}
