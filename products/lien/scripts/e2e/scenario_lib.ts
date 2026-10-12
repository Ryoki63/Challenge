// scenario_lib.ts — 通しテストの手順(steps_*.ts)が共有する型・道具
//
// Ctx(API・報告・フィクスチャ・状態)、User、World(手順をまたいで受け渡す値)と、応答の確認の道具
// (expectFields / expectError / getSnapshot / viaSignedUrl)。手順そのものは steps_setup.ts / steps_flow.ts /
// steps_after.ts、順序は scenario.ts。

import type { Api, Resp } from "./client.ts";
import type { Fixtures } from "./fixtures.ts";
import { E2E_PROMISE_PREFIX } from "./marker.ts";
import type { Mgmt } from "./mgmt.ts";
import { Abort, redact, type Reporter } from "./report.ts";
import { jsonEqual } from "./shape.ts";
import type { StateStore } from "./state.ts";

export type J = Record<string, unknown>;
export type Label = "A" | "B" | "C";

export interface ScenarioOptions {
  /** ペア外のユーザー C を作る(既定 true) */
  outsider: boolean;
  /** 最後に Management API で DB の中身を SELECT して確かめる(既定 true) */
  dbChecks: boolean;
}

export interface Ctx {
  api: Api;
  rep: Reporter;
  fx: Fixtures;
  state: StateStore;
  /** JST の今日(YYYY-MM-DD) */
  today: string;
  mgmt: Mgmt | null;
  options: ScenarioOptions;
}

export interface User {
  label: Label;
  id: string;
  jwt: string;
  nickname: string;
  promise: { title: string; emoji: string };
  /** promise-set が返した現役の約束の id */
  promiseId?: string;
  /** セッションの更新用(メモリ内だけ。状態ファイルには書かない) */
  refresh: string;
}

// ---- 小さな道具 ----

export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const ISO_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;
/**
 * 招待コード: 8 文字英数、紛らわしい 0 / O / 1 / l **だけ**を除く(DESIGN §5.1・REQUIREMENTS §3.2)。
 * 大文字の I は除かれない(サーバーの INVITE_TOKEN_ALPHABET の 58 文字に入っている)。
 * サーバーの文字集合とのずれは scenario_lib_test.ts が止める(以前は I も除いていて、約 13% のトークンで偽の FAIL が出た)
 */
export const INVITE_TOKEN_RE = /^[A-NP-Za-km-z2-9]{8}$/;

/**
 * 「存在しない招待」に使う token。形式(8 文字英数)は正しいので invite-accept の形式検査を通り、
 * 「0」を含むのでサーバーの生成器(0 を出さない)が作る token とは決して一致しない → 必ず 404 invite_not_found になる
 * (公開後に、実ユーザーの有効な招待と偶然一致して、テストユーザーが実ユーザーとペアになることがない)
 */
export const NEVER_ISSUED_INVITE_TOKEN = "ZZZZ0000";

export const obj = (v: unknown): J =>
  v !== null && typeof v === "object" && !Array.isArray(v) ? (v as J) : {};
export const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
export const brief = (r: Resp): string =>
  `HTTP ${r.status} ${redact(r.text).slice(0, 160)}`;

export function addDays(date: string, n: number): string {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

export function fakePushToken(): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** 期待する項目だけを比べる(snapshot の決定的な項目用) */
export function expectFields(
  c: Ctx,
  name: string,
  actual: unknown,
  expected: J,
): boolean {
  const a = obj(actual);
  const diffs = Object.entries(expected)
    .filter(([k, v]) => !jsonEqual(a[k], v))
    .map(([k, v]) =>
      `${k}: 期待 ${JSON.stringify(v)} / 実際 ${JSON.stringify(a[k])}`
    );
  return c.rep.check(name, diffs.length === 0, diffs.join(" / "));
}

/** エラー応答が errors.json のコード・ステータスと一致するか */
export function expectError(
  c: Ctx,
  name: string,
  r: Resp,
  fn: string,
  code: string,
): boolean {
  const allowed = c.fx.errors[fn]?.[code];
  if (!Array.isArray(allowed)) {
    c.rep.deviation(
      `${fn} の ${code} は errors.json に無い(サーバーに新しいコード?)`,
    );
  }
  const statusOk = Array.isArray(allowed) && allowed.includes(r.status);
  const codeOk = obj(r.json).error === code;
  return c.rep.check(
    name,
    statusOk && codeOk,
    `期待 ${code} / ${JSON.stringify(allowed)}、実際 ${brief(r)}`,
  );
}

export async function getSnapshot(c: Ctx, u: User, name: string): Promise<J> {
  const r = await c.api.fn(u.jwt, "snapshot", "GET");
  c.rep.check(`${name}: GET /snapshot → 200`, r.status === 200, brief(r));
  c.rep.shape(
    `${name}: 応答の形が契約フィクスチャと一致`,
    r.json,
    c.fx.snapshotGet,
  );
  return obj(obj(r.json).snapshot);
}

/**
 * PV #59 が使う、相手の当日の行の問い合わせ(PostgREST)。contracts/README.md の手書きフィクスチャ
 * (partner-checkin.*.json)の要求と同じ: `select=id,photo_path`、自分以外の今日の 1 行
 */
export function partnerRowsQuery(myId: string, dateLocal: string): string {
  return `checkins?select=id,photo_path&date_local=eq.${dateLocal}&user_id=neq.${myId}&limit=1`;
}

/** アプリ(StoragePhotoURLSigner)が要求する署名付き URL の寿命(秒) */
export const SIGN_EXPIRES_IN = 3600;

/** 署名付き URL を作って、ヘッダなしで取りに行く(PV の経路) */
export async function viaSignedUrl(
  c: Ctx,
  jwt: string | null,
  objectPath: string,
  expiresIn: number = SIGN_EXPIRES_IN,
): Promise<{ sign: Resp; get: Resp | null; signedUrl: string | null }> {
  const sign = await c.api.storageSign(jwt, objectPath, expiresIn);
  const url = obj(sign.json).signedURL;
  if (sign.status !== 200 || typeof url !== "string") {
    return { sign, get: null, signedUrl: null };
  }
  return { sign, get: await c.api.signedGet(url), signedUrl: url };
}

/** 署名の発行(POST sign)の失敗の HTTP ステータス。404 ではなく 400 で返る(本番の実測。contracts/README.md) */
export const SIGN_FAILURE_STATUS = 400;

/**
 * 署名の発行が失敗したときの応答が、手書きフィクスチャ(storage-sign.not-found.json)の契約どおりか。
 * 契約: HTTP 400・本文の statusCode と error がフィクスチャと同じ(message は文字列であればよい。アプリは前の 2 つだけ読む)。
 * 返すのは食い違いの説明(空なら契約どおり)
 */
export function signFailureProblems(
  status: number,
  body: unknown,
  fixture: J,
): string[] {
  const problems: string[] = [];
  if (status !== SIGN_FAILURE_STATUS) {
    problems.push(`HTTP ${status}(契約は ${SIGN_FAILURE_STATUS})`);
  }
  const b = obj(body);
  for (const key of ["statusCode", "error"]) {
    if (!jsonEqual(b[key], fixture[key])) {
      problems.push(
        `${key}: 期待 ${JSON.stringify(fixture[key])} / 実際 ${
          JSON.stringify(b[key])
        }`,
      );
    }
  }
  if (typeof b.message !== "string") problems.push("message が文字列でない");
  return problems;
}

/**
 * 署名付き URL の署名を 1 文字だけ変えた URL を返す(改ざんの確認用)。token が無ければ null。
 * 変えるのは署名部の末尾から 10 文字目。**最後の文字は変えない**: HS256 の署名(32 バイト = base64url の 43 文字)の
 * 最後の文字は下位 2 ビットが詰め物で、'A' → 'B' のように詰め物のビットだけが変わる置き換えは、寛容な復号では
 * 同じ署名バイトになり、改ざんにならない(以前は URL の最後の文字を変えていて、末尾が 'A' のとき偽の FAIL がありえた)
 */
export function tamperSignedUrl(url: string): string | null {
  const m = /([?&]token=)([^&#]+)/.exec(url);
  if (!m) return null;
  const token = m[2];
  const sigStart = token.lastIndexOf(".") + 1;
  if (sigStart === 0 || token.length - sigStart < 20) return null; // JWT の署名部として短すぎる
  const i = token.length - 10;
  const changed = token[i] === "A" ? "B" : "A";
  const tampered = token.slice(0, i) + changed + token.slice(i + 1);
  return url.slice(0, m.index) + m[1] + tampered +
    url.slice(m.index + m[0].length);
}

// ---- 手順をまたいで共有するもの ----

/** 約束のタイトルは「E2E 」で始める(後片付けが、これに合わない約束を持つユーザーを対象外にする。marker.ts) */
export const PROMISES: Record<Label, { title: string; emoji: string }> = {
  A: { title: `${E2E_PROMISE_PREFIX}散歩`, emoji: "🚶" },
  B: { title: `${E2E_PROMISE_PREFIX}水やり`, emoji: "🌿" },
  C: { title: `${E2E_PROMISE_PREFIX}読書`, emoji: "📚" },
};

/** 手順をまたいで受け渡す値と、作ったユーザー */
export interface World {
  users: Partial<Record<Label, User>>;
  /** この実行で作るユーザー(--no-outsider なら A / B だけ) */
  labels: Label[];
  /** ユーザーを取り出す。無ければ Abort(S01 の失敗) */
  need(label: Label): User;
  /** 途中で得る値 */
  d: {
    pairId?: string;
    photoPath?: string;
    thumbPath?: string;
    aCheckinId?: string;
    plantName?: string;
  };
}

export function createWorld(c: Ctx): World {
  const users: Partial<Record<Label, User>> = {};
  return {
    users,
    labels: c.options.outsider ? ["A", "B", "C"] : ["A", "B"],
    need: (label: Label): User => {
      const u = users[label];
      if (!u) throw new Abort(`ユーザー ${label} が無い(S01 の失敗)`);
      return u;
    },
    d: {},
  };
}
