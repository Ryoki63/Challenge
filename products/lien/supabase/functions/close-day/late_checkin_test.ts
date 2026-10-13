// late_checkin_test.ts — 「close-day の後に届く、昨日付けの遅れた checkin」のシナリオ(実ハンドラで通す)
//
// 正本: docs/REQUIREMENTS.md §3.9(回数は減らない)/ docs/GROWTH.md §3.2・§7.3 / docs/DESIGN.md §5.4
//
// 背景(2026-10-12 のレビュー指摘): 昨日の仮判定が「昨日の行が無い」だけで1日中かかっていた。
// ところが昨日の行が無いのは、確定前と、確定して**リセットされた**後(リセットの日は行を作らない)の
// どちらでも起きる。昨日付けの checkin は close-day の後からでも足せる(checkin は ±1日を許し、
// iOS の送信キューは日付をまたいで前日分を再送する)ので、リセット済みの昨日を「ふたり達成」と
// 見せてしまい、翌日に取り消していた(回数が減る・段階が戻る)。
//
// ここでは checkin / close-day / snapshot の実ハンドラを同じ偽リポジトリで通して、
// 時刻を進めながら snapshot の回数と段階が**減らない**ことを固定する。
// 1ファイルの中で完結させるため、個々の関数の細かい分岐は各 core_test.ts と _shared/snapshot_test.ts が担う。

import { type CloseDayRepo, handleCloseDay } from "./core.ts";
import { type CheckinRepo, handleCheckin } from "../checkin/core.ts";
import { handleSnapshot } from "../snapshot/core.ts";
import type {
  PairSnapshot,
  SnapshotPairRow,
  SnapshotUserRow,
} from "../_shared/snapshot.ts";
import type { StreakDayKind, StreakDayRecord } from "../_shared/streak.ts";

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  if (!Object.is(actual, expected)) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${
        JSON.stringify(actual)
      }\n  expected: ${JSON.stringify(expected)}`,
    );
  }
}

// ---- 偽リポジトリ(CheckinRepo + CloseDayRepo を1つの世界で満たす) ----

const PAIR_ID = "pair-1";
const STARTED_ON = "2026-06-01";

const userA: SnapshotUserRow = {
  id: "user-a",
  nickname: "あきら",
  timezone: "Asia/Tokyo",
  pushToken: "token-a",
};
const userB: SnapshotUserRow = {
  id: "user-b",
  nickname: "ゆうき",
  timezone: "Asia/Tokyo",
  pushToken: "token-b",
};

interface SentPush {
  deviceToken: string;
  snapshot: PairSnapshot;
}

function makeWorld(initialBothDays: string[]) {
  const checkins = new Set<string>(); // `${userId}|${dateLocal}`
  const streak = new Map<string, StreakDayKind>(
    initialBothDays.map((d) => [d, "both"]),
  );
  const users = [userA, userB];
  const plantWrites: number[] = [];
  const sent: SentPush[] = [];

  const repo: CheckinRepo & CloseDayRepo = {
    getUser: (id) => Promise.resolve(users.find((u) => u.id === id) ?? null),
    getActivePromise: (id) =>
      Promise.resolve({ id: `prom-${id}`, title: "約束", emoji: "💪" }),
    getActivePair: (id): Promise<SnapshotPairRow | null> => {
      const partner = users.find((u) => u.id !== id)!;
      return Promise.resolve({
        pairId: PAIR_ID,
        startedOn: STARTED_ON,
        partner,
      });
    },
    getCheckin: (id, dateLocal) =>
      Promise.resolve(
        checkins.has(`${id}|${dateLocal}`) ? { photoPath: null } : null,
      ),
    listStreakDays: (): Promise<StreakDayRecord[]> =>
      Promise.resolve(
        [...streak.entries()].map(([dateLocal, kind]) => ({ dateLocal, kind })),
      ),
    getPlant: () => Promise.resolve({ grownDays: 0, name: null }),
    // CheckinRepo
    upsertCheckin: (p) => {
      const key = `${p.userId}|${p.dateLocal}`;
      const created = !checkins.has(key);
      checkins.add(key);
      return Promise.resolve({ created, photoUpdated: false });
    },
    createSignedUploadUrl: () => Promise.resolve({ token: "t" }),
    removePhotos: () => Promise.resolve(),
    // CloseDayRepo
    listPairsForClose: () =>
      Promise.resolve([{
        pairId: PAIR_ID,
        status: "active" as const,
        startedOn: STARTED_ON,
        ticketBalance: 0, // チケットなし = 片方だけの日はリセット
        memberIds: [userA.id, userB.id] as [string, string],
      }]),
    getStreakDay: (_pairId, dateLocal) =>
      Promise.resolve(streak.get(dateLocal) ?? null),
    hasRestDeclared: () => Promise.resolve(false),
    upsertStreakDay: (_pairId, dateLocal, kind) => {
      if (!streak.has(dateLocal)) streak.set(dateLocal, kind);
      return Promise.resolve();
    },
    updateTicketBalance: () => Promise.resolve(),
    insertTicketLedger: () => Promise.resolve(),
    updatePlantGrowth: (_pairId, grownDays) => {
      plantWrites.push(grownDays);
      return Promise.resolve();
    },
    recordStreakReset: () => Promise.resolve(),
  };

  const pusher = {
    send: (deviceToken: string, payload: Record<string, unknown>) => {
      const lien = payload.lien as { snapshot: PairSnapshot };
      sent.push({ deviceToken, snapshot: lien.snapshot });
      return Promise.resolve({ ok: true });
    },
  };

  const at = (iso: string) => () => new Date(iso);
  return {
    repo,
    pusher,
    sent,
    streak,
    plantWrites,
    checkin: (userId: string, dateLocal: string, nowIso: string) =>
      handleCheckin({ repo, pusher, now: at(nowIso) }, { userId, dateLocal }),
    closeDay: (nowIso: string) =>
      handleCloseDay({ repo, pusher, now: at(nowIso) }),
    snapshot: async (userId: string, nowIso: string) => {
      const result = await handleSnapshot(
        { repo, now: at(nowIso) },
        { userId },
      );
      if (result.status !== 200) throw new Error("snapshot が 200 でない");
      return result.body.snapshot;
    },
  };
}

const SIX_DAYS = [
  "2026-06-01",
  "2026-06-02",
  "2026-06-03",
  "2026-06-04",
  "2026-06-05",
  "2026-06-06",
];

/** 見たい値だけ(回数・段階・ストリーク) */
const view = (s: PairSnapshot) => ({
  streak: s.streakCurrent,
  grown: s.plantGrownDays,
  stage: s.plantStage,
});

Deno.test("遅れた checkin: close-day がリセットした後に届いても、回数と段階が一瞬増えて翌日に戻ることはない(応答・push・GET とも)", async () => {
  const w = makeWorld(SIX_DAYS); // 6/1〜6/6 の 6 回(めばえ)・チケット 0 枚

  // 6/7 21:00 JST: A がチェックイン(B は 23:58 にオフラインで押し、送信キューに残る)
  const first = await w.checkin("user-a", "2026-06-07", "2026-06-07T12:00:00Z");
  assertEquals(first.status, 200);

  // 6/8 0:10 JST: close-day が 6/7 を確定。A だけでチケットも無い → リセット(行を作らない)
  const closed = await w.closeDay("2026-06-07T15:10:00Z");
  assertEquals(closed.status, 200);
  if (closed.status === 200) {
    assertEquals(closed.body.reset, 1, "6/7 はリセット");
    assertEquals(closed.body.recordedBoth, 0);
  }
  assertEquals(w.streak.has("2026-06-07"), false, "リセットの日は行が無い");
  w.sent.length = 0; // ここまでの push（リセット通知）は検査対象外

  // 6/8 8:00 JST: B のキュー済みチェックイン(6/7 付け)が届く。checkin は ±1日を許すので 200
  const late = await w.checkin("user-b", "2026-06-07", "2026-06-07T23:00:00Z");
  assertEquals(late.status, 200);
  if (late.status === 200) {
    assertEquals(late.body.alreadyCheckedIn, false, "新規として受け付ける");
    // B への応答: 確定済みの 6/7 に「今日ふたり達成 +1」(段階アップ)を出さない。本当の今日(6/8)の状態
    assertEquals(
      JSON.stringify(view(late.body.snapshot)),
      JSON.stringify({ streak: 0, grown: 6, stage: 2 }),
      "応答の snapshot に +1 が出ない",
    );
    assertEquals(late.body.snapshot.todayMeDone, false, "6/8 はまだ");
  }
  // A への push（partner_checkin）に同梱される snapshot も同じ
  assertEquals(w.sent.length, 1, "相手 A へ push");
  assertEquals(w.sent[0].deviceToken, "token-a");
  assertEquals(
    JSON.stringify(view(w.sent[0].snapshot)),
    JSON.stringify({ streak: 0, grown: 6, stage: 2 }),
    "push の snapshot にも +1 が出ない",
  );

  // 6/8 12:00 JST・6/9 12:00 JST・6/10 12:00 JST の GET /snapshot: ずっと 6 回・めばえ（増えて戻らない）
  for (
    const [label, iso] of [
      ["6/8 12:00", "2026-06-08T03:00:00Z"],
      ["6/9 12:00", "2026-06-09T03:00:00Z"],
      ["6/10 12:00", "2026-06-10T03:00:00Z"],
    ]
  ) {
    for (const userId of ["user-a", "user-b"]) {
      assertEquals(
        JSON.stringify(view(await w.snapshot(userId, iso))),
        JSON.stringify({ streak: 0, grown: 6, stage: 2 }),
        `${label} ${userId}`,
      );
    }
  }
});

Deno.test("遅れた checkin: close-day の前(0:10 より前)に届けば窓の中なので数え、確定後も同じ値のまま", async () => {
  const w = makeWorld(SIX_DAYS);

  // 6/7 21:00 JST: A がチェックイン
  await w.checkin("user-a", "2026-06-07", "2026-06-07T12:00:00Z");

  // 6/8 0:05 JST: B のキュー済みチェックイン(6/7 付け)が届く。close-day(0:10)の前 = 窓の中
  const late = await w.checkin("user-b", "2026-06-07", "2026-06-07T15:05:00Z");
  assertEquals(late.status, 200);
  if (late.status === 200) {
    assertEquals(
      JSON.stringify(view(late.body.snapshot)),
      JSON.stringify({ streak: 7, grown: 7, stage: 3 }),
      "6/7 はふたり達成(確定前の先取り)",
    );
  }

  // 6/8 0:06 JST の GET: 6/7 の行はまだ無いが、窓の中なので仮判定で数える
  assertEquals(
    JSON.stringify(view(await w.snapshot("user-a", "2026-06-07T15:06:00Z"))),
    JSON.stringify({ streak: 7, grown: 7, stage: 3 }),
  );

  // 6/8 0:10 JST: close-day が 6/7 を both で確定(plants.grown_days を数え直して 7)
  const closed = await w.closeDay("2026-06-07T15:10:00Z");
  if (closed.status === 200) assertEquals(closed.body.recordedBoth, 1);
  assertEquals(w.streak.get("2026-06-07"), "both");
  assertEquals(w.plantWrites[w.plantWrites.length - 1], 7);

  // 確定後(窓の中も外も)同じ値。6/8 は誰もチェックインしない → 6/9 0:10 にリセット
  assertEquals(
    JSON.stringify(view(await w.snapshot("user-a", "2026-06-07T15:30:00Z"))),
    JSON.stringify({ streak: 7, grown: 7, stage: 3 }),
    "6/8 0:30(確定後・窓の中)",
  );
  assertEquals(
    JSON.stringify(view(await w.snapshot("user-a", "2026-06-08T03:00:00Z"))),
    JSON.stringify({ streak: 7, grown: 7, stage: 3 }),
    "6/8 12:00(窓の外。行で数える)",
  );
  await w.closeDay("2026-06-08T15:10:00Z"); // 6/8 を確定 → リセット(行なし)
  const next = view(await w.snapshot("user-a", "2026-06-09T03:00:00Z"));
  assertEquals(next.grown, 7, "回数は減らない(ストリークが途切れても縮まない)");
  assertEquals(next.stage, 3, "段階も戻らない");
  assertEquals(
    next.streak,
    0,
    "ストリークだけが途切れる(6/8 は誰も押していない)",
  );
});
