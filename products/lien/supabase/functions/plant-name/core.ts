// plant-name/core.ts — POST /plant-name の本体ロジック(I/O はリポジトリ/プッシャー注入)
//
// 正本: docs/GROWTH.md §5.3(名前付け)・§8.1(plant-name の仕様)/ docs/REQUIREMENTS.md §3.9
//        / docs/DESIGN.md §5.3(plant-name 行)・§4(サイレントプッシュ)
//
// 仕様の要点:
//   - POST { name, mode }。mode は "first"(最初に付ける)か "rename"(あとから変える)
//   - first: plants.name が null のときだけ書く。**先に付けた人の名前に決まる**。すでに名前があれば
//     409 already_named と今の名前を返す(誰が付けたかは返さない・アプリ内にも書かない。再インストールで
//     「自分が付けたか」の記録が消えても誤表示にならないため — GROWTH §5.3)。
//     同時に2人が first を送っても書けるのは1人だけ(repo の条件付き更新 WHERE name IS NULL で一意に決着)
//   - rename: 上書き。名前が変わったときだけ相手へ知らせる(同じ名前への rename は何も起きない)
//   - name: 前後の空白を除いて 1〜8字(Unicode コードポイント)。改行などの制御文字を含まない
//   - 有効なペア(active)が必須。ソロには鉢が無い(409 no_pair)
//   - 相手へは snapshot 同梱のサイレント push(pair_update)で知らせる。相手名義の可視通知
//     (「ゆうき: 『みどり』と名づけたよ」)は P1 で、messages.ts の文言を T16 と調整してから(GROWTH §5.3)。
//     相手のアプリは次に開いたとき、snapshot.plantName の変化から「名前が『みどり』にかわったよ」を出す
//   - サイレント push は配送保証なし(DESIGN §4)。送信失敗(ok:false / throw)でも本処理は 200
//
// 書き込み対象は**呼び出し本人のペアの鉢だけ**(ペアは JWT 由来の userId から引く。pairId を入力に取らない)

import {
  loadSnapshotForUser,
  type PairSnapshot,
  type SnapshotRepo,
} from "../_shared/snapshot.ts";
import type { LienPushType } from "../_shared/apns.ts";

/** 名前の最大字数(Unicode コードポイント。ニックネームと同じ 8 字 — REQUIREMENTS §3.2・§5) */
export const PLANT_NAME_MAX_LENGTH = 8;

export type PlantNameMode = "first" | "rename";

export interface PlantNameRepo extends SnapshotRepo {
  /**
   * plants.name が null のときだけ書く(UPDATE ... WHERE pair_id = ? AND name IS NULL)。
   * 書けたら true、すでに名前があって書かなかったら false(同時に相手が先に付けた場合を含む)
   */
  setPlantNameIfUnset(pairId: string, name: string): Promise<boolean>;
  /** 名前を上書きする(rename) */
  setPlantName(pairId: string, name: string): Promise<void>;
}

/** push 送信口(実装は ApnsClient。テストはモック)。結果の ok は記録用で処理は止めない */
export interface Pusher {
  send(
    deviceToken: string,
    payload: Record<string, unknown>,
    opts?: { pushType?: "alert" | "background"; priority?: number },
  ): Promise<{ ok: boolean }>;
}

export interface PlantNameDeps {
  repo: PlantNameRepo;
  pusher: Pusher;
  now?: () => Date;
}

export interface PlantNameRequest {
  userId: string;
  name: string;
  /** "first" | "rename"(それ以外は 400 invalid_mode) */
  mode: string;
}

export type PlantNameResult =
  | {
    status: 200;
    /** name: 保存された名前(trim・正規化後)/ snapshot: 呼び出し本人視点(plantName が入る) */
    body: { name: string; snapshot: PairSnapshot };
  }
  | {
    status: 409;
    /** first で、すでに名前があった(先に付けた人の名前に決まる)。name は今の名前 */
    body: { error: "already_named"; name: string };
  }
  | { status: 400 | 404 | 409; body: { error: string } };

/**
 * サイレント更新のペイロード(DESIGN §4。promise-set/core.ts と同型 —
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

/** 名前に使えない文字: 制御文字(改行・タブ・NUL など)・行/段落区切り・対になっていないサロゲート */
const FORBIDDEN_CHARS = /[\p{Cc}\p{Zl}\p{Zp}\p{Cs}]/u;

/** 空白・制御・書式文字(ゼロ幅スペースなど)だけの名前を弾く: 見える文字が1つは要る */
const VISIBLE_CHAR = /[^\p{Cc}\p{Cf}\p{Z}]/u;

/** Unicode コードポイント数(UTF-16 の .length は使わない。promise-set と同じ数え方) */
function codePointLength(s: string): number {
  return [...s].length;
}

/**
 * 名前を検査して整える。使えない名前なら null。
 * 前後の空白を除き(途中の空白は残す)、NFC に正規化する(濁点の分解形などで字数を誤って数えず、
 * 見た目が同じ名前を同じ文字列にそろえる)。
 */
export function normalizePlantName(raw: string): string | null {
  const name = raw.normalize("NFC").trim();
  if (name.length === 0) return null;
  if (codePointLength(name) > PLANT_NAME_MAX_LENGTH) return null;
  if (FORBIDDEN_CHARS.test(name)) return null;
  if (!VISIBLE_CHAR.test(name)) return null;
  return name;
}

export async function handlePlantName(
  deps: PlantNameDeps,
  req: PlantNameRequest,
): Promise<PlantNameResult> {
  const now = deps.now ?? (() => new Date());

  // 1. 入力検証(DB を引く前に弾く)
  if (req.mode !== "first" && req.mode !== "rename") {
    return { status: 400, body: { error: "invalid_mode" } };
  }
  const name = normalizePlantName(req.name);
  if (name === null) {
    return { status: 400, body: { error: "invalid_name" } };
  }

  const user = await deps.repo.getUser(req.userId);
  if (!user) {
    return { status: 404, body: { error: "user_not_found" } };
  }

  // 2. 有効なペアが必須(ソロには鉢が無い)。鉢は本人のペアのものに限る
  const pair = await deps.repo.getActivePair(req.userId);
  if (!pair) {
    return { status: 409, body: { error: "no_pair" } };
  }
  const plant = await deps.repo.getPlant(pair.pairId);
  if (!plant) {
    // ペア成立時に invite-accept が作る行が無い(データ不整合)。名前を付ける先が無い
    return { status: 404, body: { error: "plant_not_found" } };
  }

  // 3. 書き込み
  let changed: boolean;
  if (req.mode === "first") {
    // 先に付けた人の名前に決まる。すでにあれば今の名前を返して終わり
    if (plant.name !== null) {
      return {
        status: 409,
        body: { error: "already_named", name: plant.name },
      };
    }
    const wrote = await deps.repo.setPlantNameIfUnset(pair.pairId, name);
    if (!wrote) {
      // 読んでから書くまでの間に、相手が先に付けた。決まった名前を読み直して返す
      const current = await deps.repo.getPlant(pair.pairId);
      if (current?.name == null) {
        return { status: 404, body: { error: "plant_not_found" } };
      }
      return {
        status: 409,
        body: { error: "already_named", name: current.name },
      };
    }
    changed = true;
  } else {
    // rename: 上書き。同じ名前なら何もしない(書き込みも相手への知らせも不要)
    changed = plant.name !== name;
    if (changed) await deps.repo.setPlantName(pair.pairId, name);
  }

  // 4. 自分用 snapshot(plantName が入る)
  const snapshot = await loadSnapshotForUser(deps.repo, {
    userId: req.userId,
    now: now(),
  });

  // 5. 変わったときだけ、相手へサイレント push(相手視点の snapshot 同梱)
  if (changed && pair.partner.pushToken) {
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
      // 名前の保存自体は成功させる(自己修復経路 GET /snapshot がある — DESIGN §4)
      console.error("plant-name: push 送信に失敗:", e);
    }
  }

  return { status: 200, body: { name, snapshot } };
}
