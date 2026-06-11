// promise-set/core.ts — POST /promise-set の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/REQUIREMENTS.md §3.3「約束」
//        - 1人1つ。タイトル(20字)+絵文字+リマインド時刻(任意)
//        - いつでも編集可。**約束を変えてもストリークは継続**(寛容設計)
//        / docs/DESIGN.md §5.2「書き込みは Edge Function 経由(service role)」
//        / §5.3(promise-set 行 — 2026-06-11 実装同期・T12)/ §4(サイレントプッシュ)
//
// 編集の不変条件(REQUIREMENTS §3.3):
//   - 既存の現役の約束がある場合は**同一 promise_id への UPDATE**(archive+insert しない)。
//     checkins.promise_id の FK がそのまま生き続けるので、約束を変えてもストリーク・
//     チェックイン履歴に一切影響しない
//   - 現役の約束が無い場合のみ新規 insert(unique index promises_one_active_per_user が
//     「1人1つ」を DB でも担保 — migration 0001)
//
// バリデーション:
//   - title: trim 後 1〜20字。字数は Unicode コードポイントで数える(DB の
//     char_length(title) <= 20 と同じ数え方。絵文字込みでもズレない)
//   - emoji: 必須。クライアントは固定候補から選ぶ前提で、サーバーは長さ上限のみの
//     シンプル検査に留める(過剰な書記素解析をしない — issue #12)
//   - remindAt: "HH:MM" or null(DB 列は time。リマインドのローカル通知は T16 の責務)
//
// サイレントプッシュ(DESIGN §4。checkin-cancel/core.ts の buildSilentPushPayload と同型):
//   - ペアが居れば相手へ pair_update(受信者視点 snapshot 同梱)。相手のホーム/ウィジェットの
//     「相手の約束」表示を自己修復データごと更新する
//   - 配送保証なしのフォールバック扱い。送信失敗(ok:false / throw)でも本処理は 200

import {
  loadSnapshotForUser,
  type PairSnapshot,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";
import type { LienPushType } from "../_shared/apns.ts";

/** title の最大字数(Unicode コードポイント = Postgres char_length と同じ数え方) */
export const PROMISE_TITLE_MAX_LENGTH = 20;

/** emoji の最大字数(ZWJ 合成絵文字 👨‍👩‍👧‍👦 = 7 コードポイントまで許容する上限) */
export const PROMISE_EMOJI_MAX_LENGTH = 8;

/** remindAt の形式 "HH:MM"(00:00〜23:59) */
export const REMIND_AT_FORMAT = /^([01]\d|2[0-3]):[0-5]\d$/;

/** promises 1行ぶんの API 表現(remindAt は "HH:MM" | null) */
export interface PromiseRow {
  id: string;
  title: string;
  emoji: string;
  remindAt: string | null;
}

export interface PromiseSetRepo extends SnapshotRepo {
  /**
   * 本人の現役の約束(archived_at が null)を upsert する。
   * - 既存行があれば**同一 id への UPDATE**(created: false)— FK 継続でストリーク非影響
   * - 無ければ insert(created: true)
   */
  upsertActivePromise(params: {
    userId: string;
    title: string;
    emoji: string;
    remindAt: string | null;
  }): Promise<{ promise: PromiseRow; created: boolean }>;
}

/** push 送信口(実装は ApnsClient。テストはモック)。結果の ok は記録用で処理は止めない */
export interface Pusher {
  send(
    deviceToken: string,
    payload: Record<string, unknown>,
    opts?: { pushType?: "alert" | "background"; priority?: number },
  ): Promise<{ ok: boolean }>;
}

export interface PromiseSetDeps {
  repo: PromiseSetRepo;
  pusher: Pusher;
  now?: () => Date;
}

export interface PromiseSetRequest {
  userId: string;
  title: string;
  emoji: string;
  /** "HH:MM" | null(未指定はリマインドなし) */
  remindAt?: string | null;
}

export type PromiseSetResult =
  | { status: 200; body: { promise: PromiseRow; created: boolean } }
  | { status: 400 | 404; body: { error: string } };

/**
 * サイレント更新のペイロード(DESIGN §4。checkin-cancel/core.ts と同型 —
 * _shared 集約は見送り、各 function 内の重複を許容する既存方針に従う)
 */
export function buildSilentPushPayload(params: {
  type: LienPushType;
  /** 受信者視点の PairSnapshot */
  snapshot: PairSnapshot;
}): Record<string, unknown> {
  return {
    aps: { "content-available": 1 },
    lien: { type: params.type, snapshot: params.snapshot },
  };
}

/** APNs のサイレント push は apns-push-type: background / apns-priority: 5 が必須 */
export const SILENT_PUSH_OPTS = {
  pushType: "background",
  priority: 5,
} as const;

/** Unicode コードポイント数(Postgres char_length と一致。UTF-16 の .length は使わない) */
function codePointLength(s: string): number {
  return [...s].length;
}

export async function handlePromiseSet(
  deps: PromiseSetDeps,
  req: PromiseSetRequest,
): Promise<PromiseSetResult> {
  const now = deps.now ?? (() => new Date());

  // 1. 入力検証
  const title = req.title.trim();
  if (
    title.length === 0 || codePointLength(title) > PROMISE_TITLE_MAX_LENGTH
  ) {
    return { status: 400, body: { error: "invalid_title" } };
  }
  const emoji = req.emoji.trim();
  if (
    emoji.length === 0 || codePointLength(emoji) > PROMISE_EMOJI_MAX_LENGTH
  ) {
    return { status: 400, body: { error: "invalid_emoji" } };
  }
  const remindAt = req.remindAt ?? null;
  if (remindAt !== null && !REMIND_AT_FORMAT.test(remindAt)) {
    return { status: 400, body: { error: "invalid_remind_at" } };
  }

  const user = await deps.repo.getUser(req.userId);
  if (!user) {
    return { status: 404, body: { error: "user_not_found" } };
  }

  // 2. upsert(本人の約束のみ。他人の約束には一切触れない — userId は JWT 由来)
  const { promise, created } = await deps.repo.upsertActivePromise({
    userId: req.userId,
    title,
    emoji,
    remindAt,
  });

  // 3. ペアが居れば相手へサイレント push(相手画面の「相手の約束」を更新する。
  //    ソロ状態は送り先がない。失敗しても本処理は成功 — DESIGN §4)
  const pair = await deps.repo.getActivePair(req.userId);
  if (pair && pair.partner.pushToken) {
    try {
      const partnerSnapshot = await loadSnapshotForUser(deps.repo, {
        userId: pair.partner.id,
        now: now(),
      });
      const payload = buildSilentPushPayload({
        type: "pair_update",
        snapshot: partnerSnapshot,
      });
      await deps.pusher.send(pair.partner.pushToken, payload, SILENT_PUSH_OPTS);
    } catch (e) {
      // pusher が throw しても約束の保存自体は成功させる(自己修復経路がある)
      console.error("promise-set: push 送信に失敗:", e);
    }
  }

  return { status: 200, body: { promise, created } };
}
