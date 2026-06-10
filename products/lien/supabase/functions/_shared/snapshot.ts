// _shared/snapshot.ts — 受信者視点 PairSnapshot の組み立て(純粋ロジック+注入リポジトリ)
//
// 正本:
//   - スキーマ: docs/DESIGN.md §3.4(schemaVersion = 1。キー名は一字一句一致。変更時は要レビュー
//     +JOURNAL に互換性影響を明記 — DESIGN §9-7)
//   - 植物の成長/表情: docs/REQUIREMENTS.md §3.9
//       成長(ふたり達成の累計日数): 種(0)→芽(3)→双葉(7)→若葉(14)→つぼみ(30)→開花(60)
//       表情: normal / happy(両者完了)/ fidget(片方未完)/ sad(2日連続未達成)。枯れない・後退しない
//   - ストリーク導出: docs/DESIGN.md §5.4(確定は close-day。表示はプレビュー値)
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
  streakCurrent: number;
  streakBest: number;
  todayMeDone: boolean;
  todayPartnerDone: boolean;
  myPromiseTitle: string | null;
  myPromiseEmoji: string | null;
  partnerName: string | null;
  partnerPromiseTitle: string | null;
  partnerPromiseEmoji: string | null;
  /** 0 = 種(ソロは pairId=null で土を描画)〜 5 = 開花 */
  plantStage: number;
  plantMood: PlantMood;
  plantName: string | null;
  hasPartnerPhotoToday: boolean;
}

// ---- 植物の導出(REQUIREMENTS §3.9) ----

/** 成長段階のしきい値(累計ふたり達成日数 → stage)。降順に評価する */
export const PLANT_STAGE_THRESHOLDS: ReadonlyArray<
  { stage: number; minGrownDays: number }
> = [
  { stage: 5, minGrownDays: 60 }, // 開花
  { stage: 4, minGrownDays: 30 }, // つぼみ
  { stage: 3, minGrownDays: 14 }, // 若葉
  { stage: 2, minGrownDays: 7 }, // 双葉
  { stage: 1, minGrownDays: 3 }, // 芽
  { stage: 0, minGrownDays: 0 }, // 種(見た目は土と同一 — assets/plant/mapping.md)
];

/** 累計ふたり達成日数 → 成長段階 0..5 */
export function derivePlantStage(grownDays: number): number {
  if (!Number.isInteger(grownDays) || grownDays < 0) {
    throw new Error(`grown_days が不正です: ${grownDays}`);
  }
  for (const t of PLANT_STAGE_THRESHOLDS) {
    if (grownDays >= t.minGrownDays) return t.stage;
  }
  return 0;
}

/**
 * 植物の表情(REQUIREMENTS §3.9)。
 * - happy: 両者完了のキラキラ
 * - fidget: 片方未完のそわそわ
 * - sad: 2日連続未達成のしょんぼり(確定ベースで直近2日が未達成、かつ今日もまだ両者未完)
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

// ---- snapshot 組み立て(純粋関数) ----

export interface PromiseSummary {
  title: string;
  emoji: string;
}

export interface BuildPairSnapshotInput {
  pairId: string;
  /** サーバーが snapshot を組み立てた時刻(ISO8601) */
  updatedAtIso: string;
  /** 受信者視点の「今日」(date_local) */
  todayLocal: string;
  /** pairs.started_on */
  startedOn: string;
  /** streak_days の全行(順不同可) */
  streakDays: readonly StreakDayRecord[];
  todayMeDone: boolean;
  todayPartnerDone: boolean;
  myPromise: PromiseSummary | null;
  partnerName: string;
  partnerPromise: PromiseSummary | null;
  /** plants.grown_days(close-day 確定済みの累計ふたり達成日数) */
  plantGrownDays: number;
  plantName: string | null;
  hasPartnerPhotoToday: boolean;
}

/**
 * ペア状態の受信者視点 snapshot を組み立てる(DESIGN §3.4)。
 *
 * プレビュー方針(DESIGN §5.4「確定は close-day。表示はプレビュー」):
 * - streakCurrent = 確定 current +(今日両者完了なら 1)
 * - plantStage も同様に、今日両者完了なら grown_days+1 で導出(翌朝の確定を先取りした表示。
 *   close-day は今日の行をまだ書いていないため二重加算は起きない)
 * - streakBest は確定 best とプレビュー current の大きい方(現在値が最高値を下回って見えないように)
 */
export function buildPairSnapshot(input: BuildPairSnapshotInput): PairSnapshot {
  assertDateLocal(input.todayLocal);
  const yesterday = addDaysLocal(input.todayLocal, -1);
  const { current, best } = deriveStreak(input.streakDays, yesterday);
  const bothToday = input.todayMeDone && input.todayPartnerDone;
  const streakCurrent = previewStreak(current, bothToday);
  const previewGrownDays = input.plantGrownDays + (bothToday ? 1 : 0);
  const consecutiveMissedDays = countConsecutiveMissedDays({
    days: input.streakDays,
    asOfDateLocal: yesterday,
    startedOn: input.startedOn,
  });

  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    pairId: input.pairId,
    updatedAt: input.updatedAtIso,
    streakCurrent,
    streakBest: Math.max(best, streakCurrent),
    todayMeDone: input.todayMeDone,
    todayPartnerDone: input.todayPartnerDone,
    myPromiseTitle: input.myPromise?.title ?? null,
    myPromiseEmoji: input.myPromise?.emoji ?? null,
    partnerName: input.partnerName,
    partnerPromiseTitle: input.partnerPromise?.title ?? null,
    partnerPromiseEmoji: input.partnerPromise?.emoji ?? null,
    plantStage: derivePlantStage(previewGrownDays),
    plantMood: derivePlantMood({
      todayMeDone: input.todayMeDone,
      todayPartnerDone: input.todayPartnerDone,
      consecutiveMissedDays,
    }),
    plantName: input.plantName,
    hasPartnerPhotoToday: input.hasPartnerPhotoToday,
  };
}

/** ソロ状態(ペア未成立)の snapshot。鉢は土だけ=クライアントは pairId=null で土を描画 */
export function buildSoloSnapshot(input: {
  updatedAtIso: string;
  todayMeDone: boolean;
  myPromise: PromiseSummary | null;
}): PairSnapshot {
  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    pairId: null,
    updatedAt: input.updatedAtIso,
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
    plantMood: "normal",
    plantName: null,
    hasPartnerPhotoToday: false,
  };
}

// ---- 注入リポジトリ越しの組み立て(I/O は持たない。実装は各 function の index.ts) ----

export interface SnapshotUserRow {
  id: string;
  nickname: string;
  timezone: string;
  pushToken: string | null;
}

export interface SnapshotPromiseRow extends PromiseSummary {
  id: string;
}

export interface SnapshotPairRow {
  pairId: string;
  startedOn: string;
  partner: SnapshotUserRow;
}

export interface SnapshotCheckinRow {
  photoPath: string | null;
}

export interface SnapshotPlantRow {
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
  const todayLocal = params.todayLocalOverride ??
    dateLocalInTimeZone(params.now, user.timezone);
  assertDateLocal(todayLocal);
  const updatedAtIso = params.now.toISOString();

  const myPromise = await repo.getActivePromise(params.userId);
  const myCheckin = await repo.getCheckin(params.userId, todayLocal);
  const pair = await repo.getActivePair(params.userId);

  if (!pair) {
    return buildSoloSnapshot({
      updatedAtIso,
      todayMeDone: myCheckin !== null,
      myPromise,
    });
  }

  const partnerPromise = await repo.getActivePromise(pair.partner.id);
  const partnerCheckin = await repo.getCheckin(pair.partner.id, todayLocal);
  const streakDays = await repo.listStreakDays(pair.pairId);
  const plant = await repo.getPlant(pair.pairId);

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
    plantGrownDays: plant?.grownDays ?? 0,
    plantName: plant?.name ?? null,
    hasPartnerPhotoToday: partnerCheckin?.photoPath != null,
  });
}
