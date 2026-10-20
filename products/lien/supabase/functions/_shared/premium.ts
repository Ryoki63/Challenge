// _shared/premium.ts — ペアのプレミアム判定(純粋ロジック)
//
// 正本: docs/REQUIREMENTS.md §3.14 / §5(プレミアム判定は plan カラムではなく
//       メンバーの users.premium_until から導出する)
//
// これまで grant-tickets/core.ts に置いていた derivePairPlan を、snapshot(pairPlan)と
// RevenueCat Webhook からも使えるよう _shared へ移した(T33)。grant-tickets/core.ts は
// 後方互換のため同じ名前を再エクスポートする(invite-accept/core.ts の import を変えない)。
//
// 依存は tickets.ts の型だけ。I/O も時刻の取得も持たない(now は呼び出し側が渡す)。

import type { PairPlan } from "./tickets.ts";

export type { PairPlan };

/**
 * ペアのプラン導出(REQUIREMENTS §5)。
 * いずれかのメンバーの premium_until が now より未来なら premium。
 * null / undefined / 過去 / 不正な日時文字列は free 扱い(防御的。
 * DB の値が壊れていても、課金者以外にプレミアムを見せない側へ倒す)。
 */
export function derivePairPlan(
  premiumUntils: ReadonlyArray<string | null | undefined>,
  now: Date,
): PairPlan {
  const nowMs = now.getTime();
  const isPremium = premiumUntils.some((p) => {
    if (p === null || p === undefined) return false;
    const t = new Date(p).getTime();
    return Number.isFinite(t) && t > nowMs;
  });
  return isPremium ? "premium" : "free";
}
