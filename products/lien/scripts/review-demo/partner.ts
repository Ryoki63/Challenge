// partner.ts — 審査用デモの「相手役」を操作する手動実行専用のスクリプト(issue #30 / T30)
//
// 目的: 審査員が1台で「ペアの相手がいる状態」を試せるように、開発者が操作する相手役の匿名アカウントを作り、
//   招待コードの発行・チェックイン・つつき・状態確認・削除を行う。アプリの TestFlight ビルドは不要。
//
// 正本: docs/REQUIREMENTS.md §3.2(招待は8文字英数・72時間・1回きり)/ §8(審査用のテストペア)
//        products/lien/marketing/review-notes.md §1.3(運用)
//        products/lien/scripts/review-demo/README.md(使い方・権限・秘密の扱い)
//
// 守ること:
//   - 公開の anon キーだけを使う(service-role キーは使わない)。APNs キー等の秘密も使わない
//   - 匿名セッション(refresh_token)はリポジトリの外の状態ファイル(0600)にだけ書く。標準出力・ログには出さない
//   - 招待コードは標準出力に出す(審査用に App Store Connect へ貼るため)。リポジトリには書かない
//   - 本番にユーザーを作るので、手動実行専用(CI では動かさない)。レビュー後に delete で消す
//
// 実行(リポジトリルートから。権限は partner.sh が付ける):
//   SUPABASE_ANON_KEY=... bash products/lien/scripts/review-demo/partner.sh create --slot 1
//   bash products/lien/scripts/review-demo/partner.sh status   --slot 1
//   bash products/lien/scripts/review-demo/partner.sh checkin  --slot 1
//   bash products/lien/scripts/review-demo/partner.sh delete   --slot 1

import { Api, request, type Resp } from "../e2e/client.ts";
import {
  formatJst,
  jstDate,
  parseArgs,
  type ParsedArgs,
  parseState,
  serializeState,
  type SessionState,
  stateDir,
  stateFileName,
  UsageError,
} from "./partner_lib.ts";

/** 既定の Supabase プロジェクト(アプリと同じ本番) */
const DEFAULT_SUPABASE_URL = "https://lniheehfbtpfhglinfjm.supabase.co";

/** 匿名ユーザーの metadata に付ける印(後片付け・一覧で実ユーザーと区別する) */
const REVIEW_DEMO_MARKER = "lien_review_demo";

/** 使い方の誤り(終了コード 2) */
class ConfigError extends Error {}

/** 実行時の失敗(終了コード 1) */
class CommandError extends Error {}

function env(name: string): string | undefined {
  const value = Deno.env.get(name);
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  return trimmed === "" ? undefined : trimmed;
}

function config(): { base: string; anonKey: string } {
  const base = (env("SUPABASE_URL") ?? DEFAULT_SUPABASE_URL).replace(
    /\/+$/,
    "",
  );
  const anonKey = env("SUPABASE_ANON_KEY");
  if (anonKey === undefined) {
    throw new ConfigError(
      "SUPABASE_ANON_KEY がありません。Supabase Dashboard > Project Settings > API keys の公開キー" +
        "(anon / publishable)を環境変数で渡してください。service_role キーは使いません",
    );
  }
  return { base, anonKey };
}

function homeDir(): string {
  const home = env("HOME");
  if (home === undefined) {
    throw new ConfigError(
      "HOME がありません。REVIEW_DEMO_STATE_DIR で状態ファイルの置き場所を指定してください",
    );
  }
  return home;
}

function stateDirectory(): string {
  return stateDir(homeDir(), env("REVIEW_DEMO_STATE_DIR"));
}

function statePath(slot: number): string {
  return `${stateDirectory()}/${stateFileName(slot)}`;
}

async function loadState(slot: number): Promise<SessionState> {
  try {
    return parseState(await Deno.readTextFile(statePath(slot)));
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      throw new CommandError(
        `状態ファイルがありません: ${
          statePath(slot)
        }\n先に create を実行してください`,
      );
    }
    throw error;
  }
}

async function saveState(slot: number, state: SessionState): Promise<void> {
  const directory = stateDirectory();
  await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
  const path = statePath(slot);
  const temporary = `${path}.tmp`;
  await Deno.writeTextFile(temporary, serializeState(state), { mode: 0o600 });
  await Deno.rename(temporary, path);
  try {
    await Deno.chmod(path, 0o600);
  } catch {
    // Windows など chmod が無い環境では、mkdir の権限に任せる
  }
}

async function removeState(slot: number): Promise<void> {
  try {
    await Deno.remove(statePath(slot));
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null) {
    throw new CommandError(`${label}の応答の形が想定と違います`);
  }
  return value as Record<string, unknown>;
}

function text(value: unknown, label: string): string {
  if (typeof value !== "string" || value === "") {
    throw new CommandError(`${label}が応答にありません`);
  }
  return value;
}

function httpError(label: string, response: Resp): never {
  const body = response.text.length > 500
    ? `${response.text.slice(0, 500)}…`
    : response.text;
  throw new CommandError(
    `${label}: HTTP ${response.status}${body === "" ? "" : ` — ${body}`}`,
  );
}

interface SignedIn {
  userId: string;
  accessToken: string;
  refreshToken: string;
}

/** 匿名サインイン(アプリと同じ /auth/v1/signup。印だけ足す) */
async function signUp(api: Api): Promise<SignedIn> {
  const response = await request("POST", `${api.base}/auth/v1/signup`, {
    headers: {
      apikey: api.anonKey,
      "content-type": "application/json",
    },
    body: JSON.stringify({ data: { [REVIEW_DEMO_MARKER]: true } }),
  });
  if (response.status !== 200) {
    httpError("匿名サインアップ", response);
  }
  const body = record(response.json, "匿名サインアップ");
  const user = record(body.user, "匿名サインアップの user");
  return {
    userId: text(user.id, "user.id"),
    accessToken: text(body.access_token, "access_token"),
    refreshToken: text(body.refresh_token, "refresh_token"),
  };
}

/** スロットを保ったままセッションを更新する */
async function session(
  api: Api,
  slot: number,
  state: SessionState,
): Promise<{ jwt: string; state: SessionState }> {
  const response = await api.refresh(state.refreshToken);
  if (response.status !== 200) {
    throw new CommandError(
      "セッションの更新に失敗しました。状態ファイルの refresh_token が失効しています。" +
        "匿名アカウントは再ログインできないので、create からやり直してください" +
        `(HTTP ${response.status})`,
    );
  }
  const body = record(response.json, "セッション更新");
  const next: SessionState = {
    ...state,
    refreshToken: text(body.refresh_token, "refresh_token"),
  };
  await saveState(slot, next);
  return { jwt: text(body.access_token, "access_token"), state: next };
}

function printInvite(state: SessionState): void {
  if (state.invite === null) {
    console.log("  招待コード  : まだ発行していません(new-invite で発行)");
    return;
  }
  console.log(
    `  招待コード  : ${state.invite.token}( ${
      formatJst(state.invite.expiresAt)
    } まで有効・1回きり )`,
  );
  console.log(
    "  ※ このコードを App Store Connect の Notes for Review に貼ってください。リポジトリには書かない",
  );
}

function printCreated(state: SessionState, slot: number): void {
  console.log(`相手役を作成しました(slot ${slot})`);
  console.log(`  ニックネーム: ${state.nickname}`);
  console.log(`  ユーザー ID : ${state.userId}`);
  console.log(`  約束        : ${state.promise.emoji} ${state.promise.title}`);
  printInvite(state);
  console.log(
    `  ※ セッションは ${
      statePath(slot)
    } に保存しました(0600)。消すときは delete --slot ${slot}`,
  );
}

/** snapshot の要点だけを表示する(JSON は --json のとき) */
function printSnapshot(
  snapshot: Record<string, unknown>,
  args: ParsedArgs,
): void {
  if (args.json) {
    console.log(JSON.stringify(snapshot, null, 2));
    return;
  }
  const show = (label: string, value: unknown) => {
    console.log(
      `  ${label}: ${
        value === null || value === undefined ? "-" : String(value)
      }`,
    );
  };
  console.log("いまの状態");
  show("ペア ID", snapshot.pairId);
  show("相手の名前", snapshot.partnerName);
  show("自分のきょう", snapshot.todayMeDone === true ? "完了" : "まだ");
  show("相手のきょう", snapshot.todayPartnerDone === true ? "完了" : "まだ");
  show("ふたりストリーク", snapshot.streakCurrent);
  show(
    "相手の写真(きょう)",
    snapshot.hasPartnerPhotoToday === true ? "あり" : "なし",
  );
  show("チケット", snapshot.ticketBalance);
}

async function commandCreate(args: ParsedArgs): Promise<void> {
  const { base, anonKey } = config();
  const api = new Api(base, anonKey);
  const signedIn = await signUp(api);
  try {
    const nickname = args.nickname ?? "";
    const patch = await api.rest(
      signedIn.accessToken,
      "PATCH",
      `users?id=eq.${signedIn.userId}`,
      {
        json: { nickname },
        prefer: "return=representation",
      },
    );
    if (patch.status !== 200) httpError("ニックネームの保存", patch);
    if (!Array.isArray(patch.json) || patch.json.length !== 1) {
      throw new CommandError(
        "ニックネームの保存が空振りしました(RLS か user.id の不一致)。状態は保存していません",
      );
    }

    const promise = await api.fn(signedIn.accessToken, "promise-set", "POST", {
      json: { title: args.promise, emoji: args.emoji },
    });
    if (promise.status !== 200) httpError("約束の作成", promise);

    const invite = await api.fn(signedIn.accessToken, "invite-create", "POST", {
      json: {},
    });
    if (invite.status !== 200) httpError("招待コードの発行", invite);
    const inviteBody = record(invite.json, "招待コードの発行");
    const token = text(inviteBody.token, "token");
    const expiresAt = text(inviteBody.expiresAt, "expiresAt");

    const state: SessionState = {
      version: 1,
      userId: signedIn.userId,
      refreshToken: signedIn.refreshToken,
      nickname,
      promise: { title: args.promise ?? "", emoji: args.emoji ?? "" },
      invite: { token, expiresAt },
      createdAt: new Date().toISOString(),
    };
    await saveState(args.slot, state);
    printCreated(state, args.slot);
  } catch (error) {
    // 途中で失敗したら、作った匿名ユーザーを消して残さない(消せなくても元のエラーを返す)
    try {
      await api.fn(signedIn.accessToken, "delete-account", "POST");
    } catch {
      // 後片付けの失敗は、元のエラーを隠さない
    }
    throw error;
  }
}

async function commandNewInvite(args: ParsedArgs): Promise<void> {
  const { base, anonKey } = config();
  const api = new Api(base, anonKey);
  const loaded = await loadState(args.slot);
  const { jwt, state } = await session(api, args.slot, loaded);
  const invite = await api.fn(jwt, "invite-create", "POST", { json: {} });
  if (invite.status !== 200) httpError("招待コードの発行", invite);
  const body = record(invite.json, "招待コードの発行");
  const next: SessionState = {
    ...state,
    invite: {
      token: text(body.token, "token"),
      expiresAt: text(body.expiresAt, "expiresAt"),
    },
  };
  await saveState(args.slot, next);
  console.log(`招待コードを発行しました(slot ${args.slot})`);
  printInvite(next);
}

async function commandCheckin(args: ParsedArgs): Promise<void> {
  const { base, anonKey } = config();
  const api = new Api(base, anonKey);
  const loaded = await loadState(args.slot);
  const { jwt } = await session(api, args.slot, loaded);
  const dateLocal = jstDate(new Date());

  if (args.photo === undefined) {
    const response = await api.fn(jwt, "checkin", "POST", {
      json: { dateLocal },
    });
    if (response.status !== 200) httpError("チェックイン", response);
    const body = record(response.json, "チェックイン");
    console.log(
      `チェックインしました(slot ${args.slot} / ${dateLocal})` +
        (body.alreadyCheckedIn === true
          ? " ※今日はすでに完了していました"
          : ""),
    );
    printSnapshot(record(body.snapshot, "snapshot"), args);
    return;
  }

  let bytes: Uint8Array<ArrayBuffer>;
  try {
    bytes = await Deno.readFile(args.photo);
  } catch {
    throw new CommandError(`写真を読めません: ${args.photo}`);
  }
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
    throw new CommandError(
      "写真は JPEG を指定してください(--photo / .jpg)。アプリと同じく image/jpeg で送ります",
    );
  }
  if (bytes.length > 6 * 1024 * 1024) {
    throw new CommandError(
      "写真が 6 MiB を超えています(photos バケットの上限。migration 0008)。縮小してから指定してください",
    );
  }

  const issued = await api.fn(jwt, "checkin", "POST", {
    json: { dateLocal, requestPhotoUpload: true },
  });
  if (issued.status !== 200) {
    httpError("チェックイン(アップロード URL の発行)", issued);
  }
  const issuedBody = record(
    issued.json,
    "チェックイン(アップロード URL の発行)",
  );
  const upload = record(issuedBody.photoUpload, "photoUpload");
  const photo = record(upload.photo, "photo");
  const thumb = record(upload.thumb, "thumb");
  const photoPath = text(photo.path, "photo.path");
  const thumbPath = text(thumb.path, "thumb.path");

  for (const [label, target] of [["原寸", photo], ["サムネ", thumb]] as const) {
    const path = text(target.path, `${label}.path`);
    const token = text(target.token, `${label}.token`);
    const put = await api.signedUpload(path, token, bytes);
    if (put.status < 200 || put.status >= 300) {
      httpError(`${label}のアップロード`, put);
    }
  }

  const response = await api.fn(jwt, "checkin", "POST", {
    json: { dateLocal, photoPath },
  });
  if (response.status !== 200) httpError("チェックイン(写真つき)", response);
  const body = record(response.json, "チェックイン(写真つき)");
  console.log(
    `写真つきでチェックインしました(slot ${args.slot} / ${dateLocal})\n  原寸: ${photoPath}\n  サムネ: ${thumbPath}`,
  );
  printSnapshot(record(body.snapshot, "snapshot"), args);
}

async function commandNudge(args: ParsedArgs): Promise<void> {
  const { base, anonKey } = config();
  const api = new Api(base, anonKey);
  const loaded = await loadState(args.slot);
  const { jwt } = await session(api, args.slot, loaded);
  const response = await api.fn(jwt, "nudge", "POST", {
    json: { stamp: args.stamp },
  });
  if (response.status !== 200) httpError("つつく", response);
  const body = record(response.json, "つつく");
  console.log(
    `つつきました(slot ${args.slot} / ${args.stamp})。今日の残り: ${body.remainingToday}`,
  );
}

async function commandStatus(args: ParsedArgs): Promise<void> {
  const { base, anonKey } = config();
  const api = new Api(base, anonKey);
  const loaded = await loadState(args.slot);
  const { jwt, state } = await session(api, args.slot, loaded);
  const response = await api.fn(jwt, "snapshot", "GET");
  if (response.status !== 200) httpError("状態の取得", response);
  const body = record(response.json, "状態の取得");
  const snapshot = record(body.snapshot, "snapshot");
  printSnapshot(snapshot, args);
  if (state.invite === null) {
    console.log("  招待コード  : 未発行(new-invite で発行)");
  } else {
    const expired = Date.parse(state.invite.expiresAt) <= Date.now();
    console.log(
      `  招待コード  : ${state.invite.token}( ${
        formatJst(state.invite.expiresAt)
      }${expired ? " / 失効済み。new-invite で再発行" : ""} )`,
    );
  }
}

async function commandDelete(args: ParsedArgs): Promise<void> {
  const { base, anonKey } = config();
  const api = new Api(base, anonKey);
  const loaded = await loadState(args.slot);
  const { jwt } = await session(api, args.slot, loaded);
  const response = await api.fn(jwt, "delete-account", "POST");
  if (response.status !== 200) httpError("アカウントの削除", response);
  await removeState(args.slot);
  console.log(
    `相手役を削除しました(slot ${args.slot})。状態ファイルも消しました`,
  );
}

function printHelp(): void {
  console.log(`審査用デモの相手役(issue #30)

  使い方: bash products/lien/scripts/review-demo/partner.sh <command> [--slot 1|2] [options]

  create       匿名の相手役を作り、約束と招待コードを用意する
               --nickname <8文字まで> --promise <20文字まで> --emoji <絵文字>
  new-invite   招待コードを再発行する(72時間で失効したとき)
  checkin      相手役として今日のチェックインをする
               --photo <file.jpg> を付けると、写真つき(原寸+サムネ)で送る
  nudge        相手役として、定型スタンプのつつきを送る(--stamp 👋 など)
  status       ペア・今日の状態・招待コードの期限を表示する
  delete       相手役のアカウントを削除する(delete-account。状態ファイルも消す)
  help         この使い方

  2組のデモは --slot 1 / --slot 2 で別々の状態ファイルに保存する(既定は 1)。
  必要な環境変数: SUPABASE_ANON_KEY(公開キーのみ。service_role は使わない)
  任意: SUPABASE_URL / REVIEW_DEMO_STATE_DIR(既定 ~/.lien-review-demo)

  ※ 招待コードはリポジトリに書かず、App Store Connect の Notes for Review に貼る。
  ※ セッション(refresh_token)は状態ファイル(0600)にだけ保存し、画面には出さない。`);
}

async function main(): Promise<void> {
  const args = parseArgs(Deno.args);
  switch (args.command) {
    case "create":
      await commandCreate(args);
      break;
    case "new-invite":
      await commandNewInvite(args);
      break;
    case "checkin":
      await commandCheckin(args);
      break;
    case "nudge":
      await commandNudge(args);
      break;
    case "status":
      await commandStatus(args);
      break;
    case "delete":
      await commandDelete(args);
      break;
    case "help":
      printHelp();
      break;
  }
}

try {
  await main();
} catch (error) {
  if (error instanceof UsageError || error instanceof ConfigError) {
    console.error(`ERROR: ${error.message}`);
    Deno.exit(2);
  }
  if (error instanceof CommandError) {
    console.error(`ERROR: ${error.message}`);
    Deno.exit(1);
  }
  console.error(
    `ERROR: ${error instanceof Error ? error.message : String(error)}`,
  );
  Deno.exit(1);
}
