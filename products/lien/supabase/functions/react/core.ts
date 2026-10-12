// react/core.ts — POST /react の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/REQUIREMENTS.md §3.8「リアクション」/ docs/DESIGN.md §5.3(react 行)/ §4(可視push)
//
// 仕様の要点(REQUIREMENTS §3.8):
//   - 相手のチェックイン(と写真)にスタンプ1つ(❤️🔥👏😂🥹💪)。自由入力は無し(語彙外は400)
//   - 1チェックインにつき1人1つ(reactions テーブルの UNIQUE(checkin_id, from_user))。
//     同じスタンプの再送は 200 冪等(push を再送しない)。別スタンプへの変更は上書き+再push
//   - 通知は「自分の名前名義」(= リアクションした側の名前。alert.title = pushDisplayName(自分))
//   - 自分のチェックイン、またはアクティブなペアでない相手のチェックインへは不可(403)

import {
  loadSnapshotForUser,
  type PairSnapshot,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";
import { buildVisiblePushPayload } from "../_shared/apns.ts";
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
    /** changed: 新規作成 or スタンプ変更で push した場合 true。同一スタンプ再送(無変更)は false */
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

  // 5. 冪等性: 同一スタンプの再送は push せずに 200(通知の二重発火防止)
  const existing = await deps.repo.getReaction({
    checkinId: req.checkinId,
    fromUserId: req.userId,
  });
  const changed = !existing || existing.stamp !== req.stamp;

  await deps.repo.upsertReaction({
    checkinId: req.checkinId,
    fromUserId: req.userId,
    stamp: req.stamp,
  });

  // 6. 相手(チェックインの持ち主)へ可視push。新規 or スタンプ変更のときだけ送る
  if (changed && pair.partner.pushToken) {
    try {
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
      await deps.pusher.send(pair.partner.pushToken, payload);
    } catch (e) {
      console.error("react: push 送信に失敗:", e);
    }
  }

  return { status: 200, body: { changed } };
}
