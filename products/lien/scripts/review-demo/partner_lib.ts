// partner_lib.ts — 審査用デモの相手役(partner)の純粋な部分(引数・日付・状態・検証)
//
// ネットワークを触るのは partner.ts。ここは deno test で単体テストする(partner_lib_test.ts)。
// 秘密(トークン)は状態ファイルにだけ置き、標準出力・エラー・テストには出さない。
//
// 正本: docs/REQUIREMENTS.md §3.2(招待は8文字英数・72時間・1回きり)/ §8(審査用のテストペア)
//       docs/DESIGN.md §5.1(token の文字集合)

/** partner.ts のサブコマンド */
export const COMMANDS = [
  "create",
  "new-invite",
  "checkin",
  "nudge",
  "status",
  "delete",
  "help",
] as const;

export type CommandName = typeof COMMANDS[number];

const COMMAND_SET: ReadonlySet<string> = new Set(COMMANDS);

/** 使い方の誤り(ネットワークの前に止める)。partner.ts は終了コード 2 にする */
export class UsageError extends Error {}

/** 引数の解釈結果。コマンドごとに使う項目だけを見る */
export interface ParsedArgs {
  command: CommandName;
  /** 1 か 2。2組のデモを別の状態ファイルで持つ(§1.3) */
  slot: 1 | 2;
  nickname?: string;
  promise?: string;
  emoji?: string;
  /** checkin の写真(JPEG)。省略可 */
  photo?: string;
  /** nudge のスタンプ。省略時は先頭 */
  stamp?: string;
  json: boolean;
}

/** 相手役の既定ニックネーム(アプリの上限は8文字。§1.3 の「レビュー相手1/2」) */
export function defaultNickname(slot: number): string {
  return `レビュー相手${slot}`;
}

export const DEFAULT_PROMISE = "まいにち散歩";
export const DEFAULT_EMOJI = "🚶";

/** nudge の語彙(サーバーの _shared/messages.ts と同じ。自由文は無い) */
export const NUDGE_STAMPS = ["👋", "⏰", "🙏", "📣", "😤", "✨"] as const;

/** 招待コードの形(0/O/1/l を除く8文字。invite-create/core.ts の INVITE_TOKEN_ALPHABET) */
export const INVITE_TOKEN_RE = /^[A-NP-Za-km-z2-9]{8}$/;

/** アプリの入力上限(REQUIREMENTS §3.1・§3.3) */
export const NICKNAME_MAX = 8;
export const PROMISE_TITLE_MAX = 20;

/**
 * 書記素クラスタで数える。Swift の String.count(アプリの検証)とそろえるため、
 * 絵文字をコードポイントで数えない(Intl.Segmenter が無い環境だけコードポイントに落とす)
 */
export function graphemeLength(value: string): number {
  const Segmenter = (Intl as unknown as {
    Segmenter?: new (
      locale: string,
      options: { granularity: "grapheme" },
    ) => { segment(input: string): Iterable<unknown> };
  }).Segmenter;
  if (typeof Segmenter === "function") {
    const segmenter = new Segmenter("ja", { granularity: "grapheme" });
    let count = 0;
    for (const _ of segmenter.segment(value)) count++;
    return count;
  }
  return [...value].length;
}

function nextValue(
  argv: readonly string[],
  index: number,
  option: string,
): string {
  const value = argv[index];
  if (value === undefined || value.startsWith("--")) {
    throw new UsageError(`${option} の値がありません`);
  }
  return value;
}

/** コマンドラインを解釈する。誤りは UsageError(ネットワークには行かない) */
export function parseArgs(argv: readonly string[]): ParsedArgs {
  if (argv.length === 0) {
    throw new UsageError("コマンドを指定してください(help で使い方)");
  }
  const command = argv[0];
  if (!COMMAND_SET.has(command)) {
    throw new UsageError(`知らないコマンド: ${command}(help で使い方)`);
  }

  const parsed: ParsedArgs = {
    command: command as CommandName,
    slot: 1,
    json: false,
  };

  for (let i = 1; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case "--slot": {
        const value = nextValue(argv, ++i, arg);
        if (value !== "1" && value !== "2") {
          throw new UsageError(
            "--slot は 1 か 2 です(2組のデモを別々に持ちます)",
          );
        }
        parsed.slot = Number(value) as 1 | 2;
        break;
      }
      case "--nickname":
        parsed.nickname = nextValue(argv, ++i, arg);
        break;
      case "--promise":
        parsed.promise = nextValue(argv, ++i, arg);
        break;
      case "--emoji":
        parsed.emoji = nextValue(argv, ++i, arg);
        break;
      case "--photo":
        parsed.photo = nextValue(argv, ++i, arg);
        break;
      case "--stamp":
        parsed.stamp = nextValue(argv, ++i, arg);
        break;
      case "--json":
        parsed.json = true;
        break;
      default:
        throw new UsageError(`知らないオプション: ${arg}`);
    }
  }

  // コマンドごとの組み合わせ。関係ないオプションを黙って無視しない(操作の取り違えを防ぐ)
  const onlyCreate = ["nickname", "promise", "emoji"] as const;
  if (parsed.command !== "create") {
    for (const key of onlyCreate) {
      if (parsed[key] !== undefined) {
        throw new UsageError(`--${key} は create でのみ使えます`);
      }
    }
  }
  if (parsed.command !== "checkin" && parsed.photo !== undefined) {
    throw new UsageError("--photo は checkin でのみ使えます");
  }
  if (parsed.command !== "nudge" && parsed.stamp !== undefined) {
    throw new UsageError("--stamp は nudge でのみ使えます");
  }

  if (parsed.command === "create") {
    parsed.nickname ??= defaultNickname(parsed.slot);
    parsed.promise ??= DEFAULT_PROMISE;
    parsed.emoji ??= DEFAULT_EMOJI;
    assertLength(parsed.nickname, NICKNAME_MAX, "ニックネーム");
    assertLength(parsed.promise, PROMISE_TITLE_MAX, "約束のタイトル");
    assertLength(parsed.emoji, NICKNAME_MAX, "絵文字");
  }

  if (parsed.command === "nudge") {
    parsed.stamp ??= NUDGE_STAMPS[0];
    if (!(NUDGE_STAMPS as readonly string[]).includes(parsed.stamp)) {
      throw new UsageError(
        `--stamp は ${
          NUDGE_STAMPS.join(" ")
        } のいずれかです(自由文は送れません)`,
      );
    }
  }

  return parsed;
}

/** 空でないこと・上限以内(書記素)を確かめる */
export function assertLength(
  value: string,
  max: number,
  label: string,
): void {
  if (value.trim() === "") throw new UsageError(`${label}が空です`);
  const length = graphemeLength(value);
  if (length > max) {
    throw new UsageError(`${label}は${max}文字までです(いまは${length}文字)`);
  }
}

/** 日本時間の日付(YYYY-MM-DD)。チェックインの dateLocal に使う */
export function jstDate(now: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const value = (type: string) =>
    parts.find((part) => part.type === type)?.value ?? "";
  return `${value("year")}-${value("month")}-${value("day")}`;
}

/** ISO8601 を「YYYY-MM-DD HH:mm JST」で表す(招待の期限の表示用) */
export function formatJst(iso: string): string {
  const date = new Date(iso);
  if (!Number.isFinite(date.getTime())) {
    throw new UsageError(`日時が読めません: ${iso}`);
  }
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const value = (type: string) =>
    parts.find((part) => part.type === type)?.value ?? "";
  return `${value("year")}-${value("month")}-${value("day")} ${value("hour")}:${
    value("minute")
  } JST`;
}

/** 期限が来ているか(不明な日時は UsageError) */
export function isExpired(iso: string, now: Date): boolean {
  const time = Date.parse(iso);
  if (!Number.isFinite(time)) throw new UsageError(`日時が読めません: ${iso}`);
  return time <= now.getTime();
}

/** 状態ファイルの名前(スロットごとに分ける) */
export function stateFileName(slot: number): string {
  return `partner-${slot}.json`;
}

/**
 * 状態ファイルの置き場所。既定はリポジトリの外(ホームの下)。
 * REVIEW_DEMO_STATE_DIR で変えられる(テスト・別ユーザーでの実行用)
 */
export function stateDir(home: string, override?: string): string {
  const base = override !== undefined && override !== ""
    ? override
    : `${home}/.lien-review-demo`;
  return base.replace(/\/+$/, "");
}

/** 状態ファイルの中身。refresh_token は秘密なので、表示・ログに出さない */
export interface SessionState {
  version: 1;
  userId: string;
  refreshToken: string;
  nickname: string;
  promise: { title: string; emoji: string };
  invite: { token: string; expiresAt: string } | null;
  createdAt: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

/** 状態ファイルを読む。壊れていれば UsageError(秘密は含めない) */
export function parseState(text: string): SessionState {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new UsageError("状態ファイルが壊れています(JSON として読めません)");
  }
  if (!isRecord(value)) throw new UsageError("状態ファイルの形が違います");
  if (value.version !== 1) {
    throw new UsageError("状態ファイルの版が違います(version: 1 が必要です)");
  }
  const stringField = (key: string): string => {
    const v = value[key];
    if (typeof v !== "string" || v === "") {
      throw new UsageError(`状態ファイルの ${key} がありません`);
    }
    return v;
  };
  const promise = value.promise;
  if (
    !isRecord(promise) || typeof promise.title !== "string" ||
    typeof promise.emoji !== "string"
  ) {
    throw new UsageError("状態ファイルの promise がありません");
  }
  let invite: SessionState["invite"] = null;
  if (value.invite !== null && value.invite !== undefined) {
    const i = value.invite;
    if (
      !isRecord(i) || typeof i.token !== "string" ||
      typeof i.expiresAt !== "string"
    ) {
      throw new UsageError("状態ファイルの invite が壊れています");
    }
    invite = { token: i.token, expiresAt: i.expiresAt };
  }
  return {
    version: 1,
    userId: stringField("userId"),
    refreshToken: stringField("refreshToken"),
    nickname: stringField("nickname"),
    promise: { title: promise.title, emoji: promise.emoji },
    invite,
    createdAt: stringField("createdAt"),
  };
}

/** 状態ファイルに書く形(末尾に改行) */
export function serializeState(state: SessionState): string {
  return `${JSON.stringify(state, null, 2)}\n`;
}

/** 招待コードを表示用に検証する(サーバーの文字集合と一致するか) */
export function assertInviteToken(token: string): void {
  if (!INVITE_TOKEN_RE.test(token)) {
    throw new UsageError(
      "招待コードの形が想定と違います(8文字英数。0/O/1/l は使いません)",
    );
  }
}
