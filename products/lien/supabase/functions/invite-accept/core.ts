// invite-accept/core.ts — POST /invite-accept の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/DESIGN.md §5.1(token: 72h・1回限り)/ §5.3「invite-accept: ペア作成
//        (双方が未ペアであること検査)→ 両者へpush」/ §6(招待フロー)
//        / docs/REQUIREMENTS.md §3.2
//
// 処理: token 検証(形式・存在・期限・未使用)→ 双方未ペア検査 → invite を先に
//   クレーム(used_at 打刻。条件付き更新で同時受諾の競合を防ぐ)→ pairs +
//   pair_members 作成(started_on = 受諾者ローカルの当日)→ 初期チケット付与
//   (migration 0001 の決定: 初期付与は invite-accept の責務。ledger 整合のため
//   DB 既定値では配らない)→ plants 行作成(ペア成立で種が植えられる —
//   REQUIREMENTS §3.9)→ 両者へ pair_update push(snapshot 同梱)
//
// push 失敗は処理成功扱い(DESIGN §5.5。自己修復経路 GET /snapshot がある)

import {
  dateLocalInTimeZone,
  loadSnapshotForUser,
  type PairSnapshot,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";
import { buildVisiblePushPayload } from "../_shared/apns.ts";
import { pairEstablishedBody, pushDisplayName } from "../_shared/messages.ts";
import { grantMonthlyTickets } from "../_shared/tickets.ts";
import { derivePairPlan } from "../grant-tickets/core.ts";
import type { Pusher } from "../checkin/core.ts";

/** v1 の植物品種(品種選択は v1.1 の課金アイテム — REQUIREMENTS §3.9)*/
export const DEFAULT_PLANT_SPECIES = "basic";

const TOKEN_FORMAT = /^[A-Za-z0-9]{8}$/; // invites.token の CHECK と同じ(migration 0001)

export interface InviteRow {
  token: string;
  fromUser: string;
  /** ISO8601 */
  expiresAtIso: string;
  /** ISO8601 | null(null = 未使用) */
  usedAtIso: string | null;
}

export interface InviteAcceptRepo extends SnapshotRepo {
  getInvite(token: string): Promise<InviteRow | null>;
  /**
   * used_at を条件付きで打刻する(UPDATE ... WHERE used_at IS NULL)。
   * 既に使用済みなら false(同時受諾の競合をここで一意に決着させる)
   */
  claimInvite(token: string, usedAtIso: string): Promise<boolean>;
  createPair(params: {
    startedOn: string;
    ticketBalance: number;
  }): Promise<{ pairId: string }>;
  addPairMembers(pairId: string, userIds: [string, string]): Promise<void>;
  insertTicketLedger(params: {
    pairId: string;
    delta: number;
    reason: "monthly";
    dateLocal: string;
  }): Promise<void>;
  createPlant(params: { pairId: string; species: string }): Promise<void>;
  /** users.premium_until(初期チケットのプラン判定 — REQUIREMENTS §5) */
  getPremiumUntil(userId: string): Promise<string | null>;
}

export interface InviteAcceptDeps {
  repo: InviteAcceptRepo;
  pusher: Pusher;
  now?: () => Date;
}

export type InviteAcceptResult =
  | { status: 200; body: { pairId: string; snapshot: PairSnapshot } }
  | { status: 400 | 404 | 409 | 410 | 500; body: { error: string } };

export async function handleInviteAccept(
  deps: InviteAcceptDeps,
  req: { userId: string; token: string },
): Promise<InviteAcceptResult> {
  const now = deps.now ?? (() => new Date());
  const at = now();

  // 1. token 形式(8文字英数)。不正形式は DB を引かずに弾く
  if (!TOKEN_FORMAT.test(req.token)) {
    return { status: 400, body: { error: "invalid_token" } };
  }

  const accepter = await deps.repo.getUser(req.userId);
  if (!accepter) {
    return { status: 404, body: { error: "user_not_found" } };
  }

  // 2. 招待の存在・自己受諾・未使用・期限(REQUIREMENTS §3.2: 72h / 1回限り)
  const invite = await deps.repo.getInvite(req.token);
  if (!invite) {
    return { status: 404, body: { error: "invite_not_found" } };
  }
  if (invite.fromUser === req.userId) {
    return { status: 400, body: { error: "cannot_accept_own_invite" } };
  }
  if (invite.usedAtIso !== null) {
    return { status: 410, body: { error: "invite_already_used" } };
  }
  if (at.getTime() >= new Date(invite.expiresAtIso).getTime()) {
    return { status: 410, body: { error: "invite_expired" } };
  }

  const inviter = await deps.repo.getUser(invite.fromUser);
  if (!inviter) {
    // 発行者がアカウント削除済み等。invites は users へ cascade なので通常は届かない
    return { status: 404, body: { error: "invite_not_found" } };
  }

  // 3. 双方が未ペアであること(DESIGN §5.3。v1 は1ユーザー1ペア)
  if (await deps.repo.getActivePair(req.userId)) {
    return { status: 409, body: { error: "already_paired" } };
  }
  if (await deps.repo.getActivePair(invite.fromUser)) {
    return { status: 409, body: { error: "partner_already_paired" } };
  }

  // 4. invite を先にクレーム(1回限りの一意な決着点。同時受諾はここで片方が負ける)
  const claimed = await deps.repo.claimInvite(req.token, at.toISOString());
  if (!claimed) {
    return { status: 410, body: { error: "invite_already_used" } };
  }

  // 5. ペア作成。started_on = 受諾者ローカルの当日(成立日からふたりストリーク開始 —
  //    REQUIREMENTS §3.2。国内ペア前提で両者の TZ は実質同一 — §3.4)
  const startedOn = dateLocalInTimeZone(at, accepter.timezone);

  // 初期チケット: プランに応じた月次付与ルールで0枚から付与(free 2 / premium 5。
  //    migration 0001 の決定: 初期付与は invite-accept の責務)
  const premiumUntils = await Promise.all([
    deps.repo.getPremiumUntil(req.userId),
    deps.repo.getPremiumUntil(invite.fromUser),
  ]);
  const plan = derivePairPlan(premiumUntils, at);
  const initial = grantMonthlyTickets(0, plan);

  const { pairId } = await deps.repo.createPair({
    startedOn,
    ticketBalance: initial.newBalance,
  });
  await deps.repo.addPairMembers(pairId, [invite.fromUser, req.userId]);
  if (initial.granted > 0) {
    await deps.repo.insertTicketLedger({
      pairId,
      delta: initial.granted,
      reason: "monthly",
      dateLocal: startedOn,
    });
  }

  // 6. plants 行作成(ペア成立で種が植えられる — REQUIREMENTS §3.9)
  await deps.repo.createPlant({ pairId, species: DEFAULT_PLANT_SPECIES });

  // 7. 両者へ pair_update push(受信者視点の snapshot 同梱。title は相手名 — DESIGN §4)。
  //    失敗しても処理は成功扱い(DESIGN §5.5)
  const recipients: Array<{ user: typeof accepter; partner: typeof accepter }> =
    [
      { user: inviter, partner: accepter },
      { user: accepter, partner: inviter },
    ];
  for (const { user, partner } of recipients) {
    if (!user.pushToken) continue;
    try {
      const snapshot = await loadSnapshotForUser(deps.repo, {
        userId: user.id,
        now: at,
      });
      const payload = buildVisiblePushPayload({
        title: pushDisplayName(partner.nickname),
        body: pairEstablishedBody(),
        type: "pair_update",
        snapshot,
      });
      await deps.pusher.send(user.pushToken, payload);
    } catch (e) {
      console.error("invite-accept: push 送信に失敗:", e);
    }
  }

  // 8. 受諾者視点の snapshot を返却
  const snapshot = await loadSnapshotForUser(deps.repo, {
    userId: req.userId,
    now: at,
  });
  return { status: 200, body: { pairId, snapshot } };
}
