// react/core.ts — POST /react の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/REQUIREMENTS.md §3.8「リアクション」/ docs/DESIGN.md §5.3(react 行)/ §4(可視push)
//
// 仕様の要点(REQUIREMENTS §3.8):
//   - 相手のチェックイン(と写真)にスタンプ1つ(❤️🔥👏😂🥹💪)。自由入力は無し(語彙外は400)
//   - 1チェックインにつき1人1つ(reactions テーブルの UNIQUE(checkin_id, from_user))。
//     別スタンプへの付け替えは上書きできる
//   - **相手への push は、そのチェックインへの最初のリアクションの1回だけ**(2026-10-12・TASKPLAN §9.4)。
//     付け替え(別スタンプへの上書き)でも、同じスタンプの再送でも、push は送り直さない
//     (付け替えのたびに通知が飛ぶと通知過多になる。相手の画面のスタンプは次に開いたときに更新される)
//   - 通知は「自分の名前名義」(= リアクションした側の名前。alert.title = pushDisplayName(自分))
//   - 同梱する snapshot は**受信者(相手)視点**で、「今日」は**相手のタイムゾーン**で決まる
//     (loadSnapshotForUser は対象ユーザーの users.timezone で date_local を出す。送り手の日付は使わない)
//   - 自分のチェックイン、またはアクティブなペアでない相手のチェックインへは不可(403)

import {
  loadSnapshotForUser,
  type PairSnapshot,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";
import {
  type ApnsSendOptions,
  buildVisiblePushPayload,
  sendOptionsFor,
} from "../_shared/apns.ts";
import {
  pushDisplayName,
  REACTION_STAMPS,
  reactionBody,
} from "../_shared/messages.ts";

export interface ReactCheckinRow {
  /** checkins.user_id(このチェックインの所有者) */
  userId: string;
}

export interface ReactRepo extends SnapshotRepo {
  /** checkins を id で取得(存在しなければ null) */
  getCheckinById(checkinId: string): Promise<ReactCheckinRow | null>;

  /** 既存のリアクション(同一 checkin × 同一 from_user。無ければ null) */
  getReaction(
    params: { checkinId: string; fromUserId: string },
  ): Promise<{ stamp: string } | null>;

  /** 新規なら insert、既存なら stamp を更新する(UNIQUE(checkin_id, from_user)) */
  upsertReaction(
    params: { checkinId: string; fromUserId: string; stamp: string },
  ): Promise<void>;
}

/** push 送信口(実装は ApnsClient。テストはモック)。結果の ok は記録用で処理は止めない */
export interface Pusher {
  send(
    deviceToken: string,
    payload: Record<string, unknown>,
    /** environment は受信者の users.push_env(sendOptionsFor)。未設定は APNS_ENV */
    opts?: ApnsSendOptions,
  ): Promise<{ ok: boolean }>;
}

export interface ReactDeps {
  repo: ReactRepo;
  pusher: Pusher;
  now?: () => Date;
}

export interface ReactRequest {
  userId: string;
  checkinId: string;
  /** REACTION_STAMPS のいずれか(語彙外は 400) */
  stamp: string;
}

export type ReactResult =
  | {
    status: 200;
    /**
     * changed: **保存内容が変わったか**。新規作成 or 別スタンプへの付け替えなら true、
     * 同じスタンプの再送(無変更)なら false。push を送ったかどうかとは別
     * (push は新規作成のときだけ。付け替えは changed: true でも push しない)
     */
    body: { changed: boolean };
  }
  | { status: 400 | 403 | 404 | 409; body: { error: string } };

export async function handleReact(
  deps: ReactDeps,
  req: ReactRequest,
): Promise<ReactResult> {
  const now = deps.now ?? (() => new Date());

  // 1. 語彙検証(自由入力は入れない方針 — §3.8)
  if (!REACTION_STAMPS.includes(req.stamp)) {
    return { status: 400, body: { error: "invalid_stamp" } };
  }

  const user = await deps.repo.getUser(req.userId);
  if (!user) {
    return { status: 404, body: { error: "user_not_found" } };
  }

  // 2. 対象チェックインの存在確認
  const checkin = await deps.repo.getCheckinById(req.checkinId);
  if (!checkin) {
    return { status: 404, body: { error: "checkin_not_found" } };
  }

  // 3. ペア必須(ソロはリアクションする相手がいない)
  const pair = await deps.repo.getActivePair(req.userId);
  if (!pair) {
    return { status: 409, body: { error: "no_pair" } };
  }

  // 4. 対象は「現在のアクティブなパートナー」のチェックインのみ(自分自身や
  //    無関係の相手のチェックインには不可。旧パートナーのチェックインも
  //    ペア解消後はここで弾かれる — reactions_select_pair の読み取り可視範囲とは別軸)
  if (checkin.userId !== pair.partner.id) {
    return { status: 403, body: { error: "not_partner" } };
  }

  // 5. 既存のリアクション(最初の1回かどうかと、保存内容が変わるかの判定に使う)
  const existing = await deps.repo.getReaction({
    checkinId: req.checkinId,
    fromUserId: req.userId,
  });
  const isFirst = existing === null;
  // 保存内容が変わるか(新規 or 付け替え)。同じスタンプの再送は変わらない=false(冪等)
  const changed = isFirst || existing.stamp !== req.stamp;

  // スタンプの付け替えは許す(上書き)。同じスタンプの再送は実質 no-op の upsert
  await deps.repo.upsertReaction({
    checkinId: req.checkinId,
    fromUserId: req.userId,
    stamp: req.stamp,
  });

  // 6. 相手(チェックインの持ち主)へ可視push。**最初のリアクションの1回だけ**送る。
  //    付け替え・同一スタンプの再送では送らない(通知過多を避ける — TASKPLAN §9.4)。
  //    ※ 同じユーザーが同時に2回「最初の」リアクションを送ると、双方が existing=null を見て
  //      2回送りうる(連打の競合)。端末側でボタンを押下中に無効化する前提で許容する
  if (isFirst && pair.partner.pushToken) {
    try {
      // 受信者(相手)視点。todayLocalOverride は渡さない = 「今日」は相手の timezone で決まる
      // (送り手と相手のタイムゾーンが違っても、相手の日付で todayMeDone / todayPartnerDone が出る)
      const partnerSnapshot: PairSnapshot = await loadSnapshotForUser(
        deps.repo,
        { userId: pair.partner.id, now: now() },
      );
      const payload = buildVisiblePushPayload({
        // 通知は自分の名前名義(REQUIREMENTS §3.8。リアクションした側の名前で届く)
        title: pushDisplayName(user.nickname),
        body: reactionBody(req.stamp),
        type: "reaction",
        snapshot: partnerSnapshot,
      });
      await deps.pusher.send(
        pair.partner.pushToken,
        payload,
        sendOptionsFor(pair.partner),
      );
    } catch (e) {
      console.error("react: push 送信に失敗:", e);
    }
  }

  return { status: 200, body: { changed } };
}
