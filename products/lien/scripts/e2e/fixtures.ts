// fixtures.ts — products/lien/contracts/ の契約フィクスチャを読み、応答系統ごとの「形」を作る
//
// フィクスチャはサーバーの実ハンドラを固定入力で走らせた応答(contracts/README.md)。ここでは読むだけで、
// 編集しない(再生成は contracts/tools/generate.ts)。本番の応答がずれていたら、フィクスチャを直すのではなく
// 「サーバーとフィクスチャのどちらが正か」を判断して issue にする。
//
// 手書きのフィクスチャ(PostgREST / Storage の応答。PV #59 が足したもの: partner-checkin.*.json /
// storage-sign.ok.json)は **あれば** 突き合わせる。無ければ該当の確認を SKIP にする(必須ファイルではない)。

import { type Schema, schemaFrom } from "./shape.ts";

export const CONTRACTS_DIR = new URL("../../contracts/", import.meta.url);

type J = Record<string, unknown>;

export interface Fixtures {
  /** 読み込んだ JSON そのまま(ファイル名 → 内容) */
  raw: Record<string, J>;
  /** 手書きのフィクスチャのうち、読めたもの(ファイル名 → 内容。配列のものがある) */
  optional: Record<string, unknown>;
  /**
   * PairSnapshot 1 件の形。snapshot を含むすべてのフィクスチャ(snapshot.* / checkin.* / checkin-cancel /
   * invite-accept / nudge / plant-name)の `snapshot` を合成したもの。フィクスチャは 1 つの状態の標本にすぎず、
   * たとえば nudge.ok.json は名前付き(plantName が文字列)・checkin-cancel.ok.json はペア成立済みだが、
   * 実際の応答では名前が付く前は plantName が null、ソロならペア関連が null になる
   */
  snapshot: Schema;
  /** GET /snapshot の 200(`{ snapshot }`) */
  snapshotGet: Schema;
  /** POST /checkin の 200(paired + solo + photo-upload を合成。photoUpload は任意) */
  checkin: Schema;
  checkinCancel: Schema;
  promiseSet: Schema;
  inviteCreate: Schema;
  inviteAccept: Schema;
  nudge: Schema;
  react: Schema;
  plantName: Schema;
  plantNameAlreadyNamed: Schema;
  /** PostgREST の相手の当日の行(`[{ id, photo_path }]`。photo / no-photo / none を合成)。フィクスチャが無ければ undefined */
  partnerCheckin?: Schema;
  /** Storage の署名付き URL の発行(`{ signedURL }`)。フィクスチャが無ければ undefined */
  storageSign?: Schema;
  /** 関数名 → エラーコード → 許す HTTP ステータス */
  errors: Record<string, Record<string, number[]>>;
  stamps: { nudge: string[]; reaction: string[] };
}

/** `snapshot` キーの中身を、全フィクスチャを合成した PairSnapshot の形に差し替える */
function withSnapshot(schema: Schema, snapshot: Schema): Schema {
  const prop = schema.props?.get("snapshot");
  if (!schema.props || !prop) return schema;
  const props = new Map(schema.props);
  props.set("snapshot", { schema: snapshot, optional: prop.optional });
  return { ...schema, props };
}

/** `snapshot` を持つフィクスチャ(PairSnapshot の標本) */
const SNAPSHOT_FILES = [
  "snapshot.paired.json",
  "snapshot.solo.json",
  "snapshot.empty.json",
  "checkin.paired.json",
  "checkin.solo.json",
  "checkin.photo-upload.json",
  "checkin-cancel.ok.json",
  "invite-accept.ok.json",
  "nudge.ok.json",
  "plant-name.ok.json",
] as const;

/** 必須のフィクスチャ(Edge Function の実ハンドラから作ったもの) */
export const REQUIRED_FILES = [
  "snapshot.paired.json",
  "snapshot.solo.json",
  "snapshot.empty.json",
  "checkin.paired.json",
  "checkin.solo.json",
  "checkin.photo-upload.json",
  "checkin-cancel.ok.json",
  "promise-set.ok.json",
  "invite-create.ok.json",
  "invite-accept.ok.json",
  "nudge.ok.json",
  "react.ok.json",
  "plant-name.ok.json",
  "plant-name.already-named.json",
  "errors.json",
  "stamps.json",
] as const;

/** 任意のフィクスチャ(PostgREST / Storage の応答。手書き。PV #59) */
export const OPTIONAL_FILES = [
  "partner-checkin.photo.json",
  "partner-checkin.no-photo.json",
  "partner-checkin.none.json",
  "storage-sign.ok.json",
] as const;

/** 読み込み済みの JSON から、応答系統ごとの形を作る(ファイルを読まない純粋な部分。テストはこちらを使う) */
export function buildFixtures(
  raw: Record<string, J>,
  optional: Record<string, unknown> = {},
): Fixtures {
  const stamps = raw["stamps.json"] as { nudge: string[]; reaction: string[] };
  const snapshot = schemaFrom(...SNAPSHOT_FILES.map((f) => raw[f].snapshot));
  const family = (...files: (typeof REQUIRED_FILES)[number][]): Schema =>
    withSnapshot(schemaFrom(...files.map((f) => raw[f])), snapshot);

  const partnerFiles = [
    "partner-checkin.photo.json",
    "partner-checkin.no-photo.json",
    "partner-checkin.none.json",
  ];
  const partnerCheckin = partnerFiles.every((f) => f in optional)
    ? schemaFrom(...partnerFiles.map((f) => optional[f]))
    : undefined;
  const storageSign = "storage-sign.ok.json" in optional
    ? schemaFrom(optional["storage-sign.ok.json"])
    : undefined;

  return {
    raw,
    optional,
    snapshot,
    snapshotGet: family(
      "snapshot.paired.json",
      "snapshot.solo.json",
      "snapshot.empty.json",
    ),
    checkin: family(
      "checkin.paired.json",
      "checkin.solo.json",
      "checkin.photo-upload.json",
    ),
    checkinCancel: family("checkin-cancel.ok.json"),
    promiseSet: family("promise-set.ok.json"),
    inviteCreate: family("invite-create.ok.json"),
    inviteAccept: family("invite-accept.ok.json"),
    nudge: family("nudge.ok.json"),
    react: family("react.ok.json"),
    plantName: family("plant-name.ok.json"),
    plantNameAlreadyNamed: family("plant-name.already-named.json"),
    partnerCheckin,
    storageSign,
    errors: raw["errors.json"] as unknown as Fixtures["errors"],
    stamps: { nudge: stamps.nudge, reaction: stamps.reaction },
  };
}

export async function loadFixtures(
  dir: URL = CONTRACTS_DIR,
): Promise<Fixtures> {
  const raw: Record<string, J> = {};
  for (const f of REQUIRED_FILES) {
    raw[f] = JSON.parse(await Deno.readTextFile(new URL(f, dir))) as J;
  }
  const optional: Record<string, unknown> = {};
  for (const f of OPTIONAL_FILES) {
    try {
      optional[f] = JSON.parse(await Deno.readTextFile(new URL(f, dir)));
    } catch (e) {
      if (!(e instanceof Deno.errors.NotFound)) throw e;
    }
  }
  return buildFixtures(raw, optional);
}
