// generate.ts — iOS ⇔ サーバーの契約フィクスチャ(products/lien/contracts/*.json)の生成器
//
// フィクスチャは手書きしない。サーバー(supabase/functions/**/core.ts と _shared/*.ts)の
// **実際のハンドラ**を、メモリ上の偽リポジトリで固定入力のまま走らせ、その応答 JSON をそのまま保存する。
// iOS は同じ JSON を LienTests のリソースとして読み、本番と同じデコーダで復元できることをテストする
// (ios/LienTests/ContractFixtureTests.swift)。サーバーの応答形が変わって生成物が変わったら、
// このスクリプトを再実行して差分をレビューし、iOS のデコードが追従していることを確認する。
//
// 使い方(リポジトリルートから):
//   deno run --allow-read --allow-write products/lien/contracts/tools/generate.ts          # 書き出し
//   deno run --allow-read products/lien/contracts/tools/generate.ts --check                # 差分があれば exit 1
//
// 入力はすべて固定(時刻 = 2026-06-11T08:30:00Z = JST 17:30、UUID・token も固定)なので、
// 同じサーバーコードからは常に同じバイト列が出る(--check が CI/手元で使える理由)。

import { handleSnapshot } from "../../supabase/functions/snapshot/core.ts";
import { handleCheckin } from "../../supabase/functions/checkin/core.ts";
import { handleCheckinCancel } from "../../supabase/functions/checkin-cancel/core.ts";
import { handlePromiseSet } from "../../supabase/functions/promise-set/core.ts";
import { handleInviteCreate } from "../../supabase/functions/invite-create/core.ts";
import { handleInviteAccept } from "../../supabase/functions/invite-accept/core.ts";
import { handleNudge } from "../../supabase/functions/nudge/core.ts";
import { handleReact } from "../../supabase/functions/react/core.ts";
import {
  NUDGE_STAMPS,
  REACTION_STAMPS,
} from "../../supabase/functions/_shared/messages.ts";

// ---- 固定入力 -------------------------------------------------------------

/** JST 2026-06-11 17:30。todayLocal = 2026-06-11 */
const NOW = new Date("2026-06-11T08:30:00.000Z");
const TODAY = "2026-06-11";

const USER_ME = "a1111111-1111-4111-8111-111111111111";
const USER_PARTNER = "b2222222-2222-4222-8222-222222222222";
const PAIR_ID = "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a";
const PARTNER_CHECKIN_ID = "8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80";
const MY_CHECKIN_ID = "5d9e3b17-6a24-4c88-b1f0-3e7a9c2d4f61";

/** invite-create の乱数(各バイト = 58 文字アルファベット上の位置)→ token "AbCd2345" */
const INVITE_RANDOM_BYTES = new Uint8Array([0, 26, 2, 28, 50, 51, 52, 53]);

const WEB_BASE_URL = "https://ryoki63.github.io/Challenge";

// ---- 偽リポジトリ(全ハンドラの Repo をまとめて満たす。ネットワーク不要)-------------------

interface UserRow {
  id: string;
  nickname: string;
  timezone: string;
  pushToken: string | null;
}

interface CheckinRow {
  id: string;
  userId: string;
  dateLocal: string;
  photoPath: string | null;
}

interface WorldInit {
  /** ペアを成立させるか(false = ソロ) */
  paired: boolean;
  /** 自分の約束(null = 未設定) */
  myPromise: { title: string; emoji: string } | null;
  /** 自分が今日チェックイン済みか */
  meDone: boolean;
  /** 相手が今日チェックイン済みか */
  partnerDone: boolean;
  /** 相手の今日のチェックインに写真があるか */
  partnerPhoto: boolean;
}

class World {
  users: UserRow[] = [
    {
      id: USER_ME,
      nickname: "あきら",
      timezone: "Asia/Tokyo",
      pushToken: "device-token-me",
    },
    {
      id: USER_PARTNER,
      nickname: "ゆうき",
      timezone: "Asia/Tokyo",
      pushToken: "device-token-partner",
    },
  ];
  promises = new Map<string, { id: string; title: string; emoji: string }>();
  pair: { pairId: string; startedOn: string; memberIds: string[] } | null =
    null;
  checkins: CheckinRow[] = [];
  streakDays: Array<{ dateLocal: string; kind: "both" | "ticket" }> = [];
  plant: { grownDays: number; name: string | null } | null = null;
  invites = new Map<
    string,
    { fromUser: string; expiresAtIso: string; usedAtIso: string | null }
  >();
  signedUploads = 0;

  constructor(init: WorldInit) {
    if (init.myPromise) {
      this.promises.set(USER_ME, {
        id: "c3333333-3333-4333-8333-333333333333",
        ...init.myPromise,
      });
    }
    if (init.paired) {
      this.promises.set(USER_PARTNER, {
        id: "d4444444-4444-4444-8444-444444444444",
        title: "ランニング",
        emoji: "🏃",
      });
      this.pair = {
        pairId: PAIR_ID,
        startedOn: "2026-06-01",
        memberIds: [USER_ME, USER_PARTNER],
      };
      this.streakDays = [
        "2026-06-05",
        "2026-06-06",
        "2026-06-07",
        "2026-06-08",
        "2026-06-09",
        "2026-06-10",
      ]
        .map((dateLocal) => ({ dateLocal, kind: "both" as const }));
      this.plant = { grownDays: 13, name: "みどり" };
    }
    if (init.meDone) {
      this.checkins.push({
        id: MY_CHECKIN_ID,
        userId: USER_ME,
        dateLocal: TODAY,
        photoPath: null,
      });
    }
    if (init.partnerDone) {
      this.checkins.push({
        id: PARTNER_CHECKIN_ID,
        userId: USER_PARTNER,
        dateLocal: TODAY,
        photoPath: init.partnerPhoto
          ? `pairs/${PAIR_ID}/${TODAY}/${USER_PARTNER}/photo.jpg`
          : null,
      });
    }
  }

  // -- SnapshotRepo --
  getUser(id: string) {
    return Promise.resolve(this.users.find((u) => u.id === id) ?? null);
  }
  getActivePromise(id: string) {
    return Promise.resolve(this.promises.get(id) ?? null);
  }
  getActivePair(id: string) {
    if (!this.pair || !this.pair.memberIds.includes(id)) {
      return Promise.resolve(null);
    }
    const partnerId = this.pair.memberIds.find((m) => m !== id)!;
    return Promise.resolve({
      pairId: this.pair.pairId,
      startedOn: this.pair.startedOn,
      partner: this.users.find((u) => u.id === partnerId)!,
    });
  }
  getCheckin(userId: string, dateLocal: string) {
    const row = this.checkins.find((c) =>
      c.userId === userId && c.dateLocal === dateLocal
    );
    return Promise.resolve(row ? { photoPath: row.photoPath } : null);
  }
  listStreakDays() {
    return Promise.resolve([...this.streakDays]);
  }
  getPlant() {
    return Promise.resolve(this.plant ? { ...this.plant } : null);
  }

  // -- CheckinRepo --
  upsertCheckin(
    p: { userId: string; dateLocal: string; photoPath: string | null },
  ) {
    const existing = this.checkins.find((c) =>
      c.userId === p.userId && c.dateLocal === p.dateLocal
    );
    if (!existing) {
      this.checkins.push({
        id: MY_CHECKIN_ID,
        userId: p.userId,
        dateLocal: p.dateLocal,
        photoPath: p.photoPath,
      });
      return Promise.resolve({ created: true, photoUpdated: false });
    }
    if (p.photoPath !== null && existing.photoPath !== p.photoPath) {
      existing.photoPath = p.photoPath;
      return Promise.resolve({ created: false, photoUpdated: true });
    }
    return Promise.resolve({ created: false, photoUpdated: false });
  }
  createSignedUploadUrl(_path: string) {
    this.signedUploads++;
    // 実物は Storage が発行する署名トークン(JWT)。形だけ固定の擬似値にする
    return Promise.resolve({
      token: `signed-upload-token-${this.signedUploads}`,
    });
  }

  // -- CheckinCancelRepo --
  deleteCheckin(p: { userId: string; dateLocal: string }) {
    const before = this.checkins.length;
    this.checkins = this.checkins.filter((c) =>
      !(c.userId === p.userId && c.dateLocal === p.dateLocal)
    );
    return Promise.resolve({ deleted: this.checkins.length < before });
  }

  // -- PromiseSetRepo --
  upsertActivePromise(
    p: {
      userId: string;
      title: string;
      emoji: string;
      remindAt: string | null;
    },
  ) {
    const existing = this.promises.get(p.userId);
    const id = existing?.id ?? "c3333333-3333-4333-8333-333333333333";
    this.promises.set(p.userId, { id, title: p.title, emoji: p.emoji });
    return Promise.resolve({
      promise: { id, title: p.title, emoji: p.emoji, remindAt: p.remindAt },
      created: !existing,
    });
  }

  // -- NudgeRepo --
  listRecentNudgesBySender() {
    return Promise.resolve([]);
  }
  insertNudge() {
    return Promise.resolve();
  }

  // -- ReactRepo --
  getCheckinById(id: string) {
    const row = this.checkins.find((c) => c.id === id);
    return Promise.resolve(row ? { userId: row.userId } : null);
  }
  getReaction() {
    return Promise.resolve(null);
  }
  upsertReaction() {
    return Promise.resolve();
  }

  // -- InviteCreateRepo --
  insertInvite(
    p: { token: string; fromUser: string; expiresAtIso: string },
  ) {
    this.invites.set(p.token, {
      fromUser: p.fromUser,
      expiresAtIso: p.expiresAtIso,
      usedAtIso: null,
    });
    return Promise.resolve({ inserted: true });
  }

  // -- InviteAcceptRepo --
  getInvite(token: string) {
    const row = this.invites.get(token);
    return Promise.resolve(
      row
        ? {
          token,
          fromUser: row.fromUser,
          expiresAtIso: row.expiresAtIso,
          usedAtIso: row.usedAtIso,
        }
        : null,
    );
  }
  claimInvite(token: string, usedAtIso: string) {
    const row = this.invites.get(token);
    if (!row || row.usedAtIso !== null) return Promise.resolve(false);
    row.usedAtIso = usedAtIso;
    return Promise.resolve(true);
  }
  createPair(p: { startedOn: string }) {
    this.pair = { pairId: PAIR_ID, startedOn: p.startedOn, memberIds: [] };
    return Promise.resolve({ pairId: PAIR_ID });
  }
  addPairMembers(_pairId: string, userIds: string[]) {
    this.pair!.memberIds = [...userIds];
    return Promise.resolve();
  }
  insertTicketLedger() {
    return Promise.resolve();
  }
  createPlant() {
    this.plant = { grownDays: 0, name: null };
    return Promise.resolve();
  }
  getPremiumUntil() {
    return Promise.resolve(null);
  }
}

// deno-lint-ignore no-explicit-any
type AnyRepo = any;

/** 呼ばれた push を記録する(応答は ok) */
function capturingPusher() {
  const sent: Array<
    { deviceToken: string; payload: Record<string, unknown> }
  > = [];
  return {
    sent,
    pusher: {
      send: (deviceToken: string, payload: Record<string, unknown>) => {
        sent.push({ deviceToken, payload });
        return Promise.resolve({ ok: true });
      },
    },
  };
}

function world(overrides: Partial<WorldInit> = {}): World {
  return new World({
    paired: true,
    myPromise: { title: "筋トレ", emoji: "💪" },
    meDone: false,
    partnerDone: false,
    partnerPhoto: false,
    ...overrides,
  });
}

function must200<T extends { status: number; body: unknown }>(
  name: string,
  result: T,
): T["body"] {
  if (result.status !== 200) {
    throw new Error(
      `${name}: 200 を期待したが ${result.status}: ${
        JSON.stringify(result.body)
      }`,
    );
  }
  return result.body;
}

// ---- フィクスチャの生成 ---------------------------------------------------

export async function buildFixtures(): Promise<Map<string, unknown>> {
  const out = new Map<string, unknown>();
  const clock = () => NOW;

  // GET /snapshot ---------------------------------------------------------
  {
    const w = world({ partnerDone: true, partnerPhoto: true });
    out.set(
      "snapshot.paired",
      must200(
        "snapshot.paired",
        await handleSnapshot({ repo: w as AnyRepo, now: clock }, {
          userId: USER_ME,
        }),
      ),
    );
  }
  {
    const w = world({ paired: false });
    out.set(
      "snapshot.solo",
      must200(
        "snapshot.solo",
        await handleSnapshot({ repo: w as AnyRepo, now: clock }, {
          userId: USER_ME,
        }),
      ),
    );
  }
  {
    // オンボ直後: 約束もペアもない
    const w = world({ paired: false, myPromise: null });
    out.set(
      "snapshot.empty",
      must200(
        "snapshot.empty",
        await handleSnapshot({ repo: w as AnyRepo, now: clock }, {
          userId: USER_ME,
        }),
      ),
    );
  }

  // POST /checkin -----------------------------------------------------------
  {
    // 相手が先に完了 → 自分が完了して「ふたり達成」。相手へ可視 push(snapshot 同梱)
    const w = world({ partnerDone: true });
    const { sent, pusher } = capturingPusher();
    out.set(
      "checkin.paired",
      must200(
        "checkin.paired",
        await handleCheckin(
          { repo: w as AnyRepo, pusher, now: clock, random: () => 0 },
          { userId: USER_ME, dateLocal: TODAY },
        ),
      ),
    );
    const toPartner = sent.find((s) =>
      s.deviceToken === "device-token-partner"
    );
    if (!toPartner) {
      throw new Error("checkin.paired: 相手への push が送られていない");
    }
    out.set("push.visible", toPartner.payload);
  }
  {
    // ソロ(ペアなし・写真なし)でも受け付ける
    const w = world({ paired: false });
    const { pusher } = capturingPusher();
    out.set(
      "checkin.solo",
      must200(
        "checkin.solo",
        await handleCheckin(
          { repo: w as AnyRepo, pusher, now: clock, random: () => 0 },
          { userId: USER_ME, dateLocal: TODAY },
        ),
      ),
    );
  }
  {
    // 写真添付の第1段: 署名付きアップロード URL(原寸+サムネ)を要求
    const w = world();
    const { pusher } = capturingPusher();
    out.set(
      "checkin.photo-upload",
      must200(
        "checkin.photo-upload",
        await handleCheckin(
          { repo: w as AnyRepo, pusher, now: clock, random: () => 0 },
          { userId: USER_ME, dateLocal: TODAY, requestPhotoUpload: true },
        ),
      ),
    );
  }

  // POST /checkin-cancel ----------------------------------------------------
  {
    const w = world({ meDone: true, partnerDone: true });
    const { sent, pusher } = capturingPusher();
    out.set(
      "checkin-cancel.ok",
      must200(
        "checkin-cancel.ok",
        await handleCheckinCancel(
          { repo: w as AnyRepo, pusher, now: clock },
          { userId: USER_ME, dateLocal: TODAY },
        ),
      ),
    );
    const toPartner = sent.find((s) =>
      s.deviceToken === "device-token-partner"
    );
    if (!toPartner) {
      throw new Error("checkin-cancel.ok: 相手へのサイレント push が無い");
    }
    out.set("push.silent", toPartner.payload);
  }

  // POST /promise-set -------------------------------------------------------
  {
    const w = world({ paired: false, myPromise: null });
    const { pusher } = capturingPusher();
    out.set(
      "promise-set.ok",
      must200(
        "promise-set.ok",
        await handlePromiseSet(
          { repo: w as AnyRepo, pusher, now: clock },
          { userId: USER_ME, title: "筋トレ", emoji: "💪", remindAt: "20:00" },
        ),
      ),
    );
  }

  // POST /invite-create / /invite-accept -------------------------------------
  {
    const w = world({ paired: false });
    out.set(
      "invite-create.ok",
      must200(
        "invite-create.ok",
        await handleInviteCreate(
          {
            repo: w as AnyRepo,
            webBaseUrl: WEB_BASE_URL,
            now: clock,
            randomBytes: () => INVITE_RANDOM_BYTES,
          },
          { userId: USER_ME },
        ),
      ),
    );
  }
  {
    // 相手(ゆうき)が発行した招待を、自分(あきら・ソロ)が受諾する
    const w = world({ paired: false });
    w.promises.set(USER_PARTNER, {
      id: "d4444444-4444-4444-8444-444444444444",
      title: "ランニング",
      emoji: "🏃",
    });
    w.invites.set("AbCd2345", {
      fromUser: USER_PARTNER,
      expiresAtIso: new Date(NOW.getTime() + 72 * 60 * 60 * 1000).toISOString(),
      usedAtIso: null,
    });
    const { pusher } = capturingPusher();
    out.set(
      "invite-accept.ok",
      must200(
        "invite-accept.ok",
        await handleInviteAccept(
          { repo: w as AnyRepo, pusher, now: clock },
          { userId: USER_ME, token: "AbCd2345" },
        ),
      ),
    );
  }

  // POST /nudge / /react ------------------------------------------------------
  {
    const w = world({ partnerDone: false });
    const { pusher } = capturingPusher();
    out.set(
      "nudge.ok",
      must200(
        "nudge.ok",
        await handleNudge(
          { repo: w as AnyRepo, pusher, now: clock, random: () => 0 },
          { userId: USER_ME, stamp: NUDGE_STAMPS[0] },
        ),
      ),
    );
  }
  {
    const w = world({ partnerDone: true });
    const { pusher } = capturingPusher();
    out.set(
      "react.ok",
      must200(
        "react.ok",
        await handleReact(
          { repo: w as AnyRepo, pusher, now: clock },
          {
            userId: USER_ME,
            checkinId: PARTNER_CHECKIN_ID,
            stamp: REACTION_STAMPS[0],
          },
        ),
      ),
    );
  }

  // 語彙(スタンプ)------------------------------------------------------------
  out.set("stamps", {
    nudge: [...NUDGE_STAMPS],
    reaction: [...REACTION_STAMPS],
  });

  // エラー文字列 --------------------------------------------------------------
  out.set("errors", await collectErrorCodes());

  return out;
}

// ---- エラー文字列の収集(core.ts / index.ts のソースから) ------------------------------

const FUNCTIONS = [
  "snapshot",
  "invite-create",
  "invite-accept",
  "promise-set",
  "checkin",
  "checkin-cancel",
  "nudge",
  "react",
] as const;

/**
 * 各 function の core.ts(`status: 409, body: { error: "x" }`)と index.ts(`json(401, { error: "x" })`)に
 * 書かれたエラー応答を拾い、{ function: { code: [status...] } } にする。
 * iOS 側のエラーマップ(InviteClientError 等)がサーバーの実在する文字列だけを使っていること、
 * サーバーに増えたコードをクライアントが取りこぼしていないことをテストするための台帳
 */
async function collectErrorCodes(): Promise<
  Record<string, Record<string, number[]>>
> {
  const coreRe = /status:\s*(\d{3}),\s*body:\s*\{\s*error:\s*"([a-z_]+)"/g;
  const indexRe = /json\(\s*(\d{3}),\s*\{\s*error:\s*"([a-z_]+)"/g;
  const result: Record<string, Record<string, number[]>> = {};
  for (const fn of FUNCTIONS) {
    const codes: Record<string, Set<number>> = {};
    for (
      const [file, re] of [["core.ts", coreRe], ["index.ts", indexRe]] as const
    ) {
      const path = new URL(
        `../../supabase/functions/${fn}/${file}`,
        import.meta.url,
      );
      const source = await Deno.readTextFile(path);
      for (const m of source.matchAll(re)) {
        (codes[m[2]] ??= new Set()).add(Number(m[1]));
      }
    }
    const sorted: Record<string, number[]> = {};
    for (const code of Object.keys(codes).sort()) {
      sorted[code] = [...codes[code]].sort((a, b) => a - b);
    }
    result[fn] = sorted;
  }
  return result;
}

// ---- 入出力 -----------------------------------------------------------------------------

export function serialize(value: unknown): string {
  // 数値だけの配列(HTTP ステータスの列)は1行に畳んで読みやすくする
  const text = JSON.stringify(value, null, 2).replace(
    /\[\n\s+(\d+(?:,\n\s+\d+)*)\n\s+\]/g,
    (_match, inner: string) => `[${inner.replace(/,\n\s+/g, ", ")}]`,
  );
  return text + "\n";
}

async function main() {
  const check = Deno.args.includes("--check");
  const outDir = new URL("../", import.meta.url);
  const fixtures = await buildFixtures();

  let drift = 0;
  for (const [name, value] of fixtures) {
    const path = new URL(`${name}.json`, outDir);
    const text = serialize(value);
    if (check) {
      let current: string | null = null;
      try {
        current = await Deno.readTextFile(path);
      } catch {
        // 無い = 差分
      }
      if (current !== text) {
        console.error(`DRIFT: ${name}.json が生成結果と一致しません`);
        drift++;
      }
    } else {
      await Deno.writeTextFile(path, text);
      console.log(`wrote ${name}.json`);
    }
  }
  if (check) {
    if (drift > 0) {
      console.error(
        `\n${drift} 件の差分。サーバーの応答形が変わった可能性があります。\n` +
          `deno run --allow-read --allow-write products/lien/contracts/tools/generate.ts で再生成し、` +
          `差分をレビューして iOS のデコード(ContractFixtureTests)が追従していることを確認してください。`,
      );
      Deno.exit(1);
    }
    console.log(
      `OK: ${fixtures.size} 件のフィクスチャはサーバー実装の出力と一致`,
    );
  }
}

if (import.meta.main) {
  await main();
}
