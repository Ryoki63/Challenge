// contracts_test.ts — コミット済みの契約フィクスチャが、サーバー実装の現在の出力と一致することの検査
//
//   deno test --allow-read products/lien/contracts/tools/
//
// サーバー(supabase/functions)の応答形を変えたら、generate.ts で再生成して差分をレビューする。
// 差分があるまま放置すると、iOS(ContractFixtureTests)が古い形を前提にデコードを検証し続けてしまう。

import { buildFixtures, serialize } from "./generate.ts";

/**
 * generate.ts が作らない、手書きのフィクスチャ(PV #59)。
 * サーバーの Edge Function ではなく PostgREST(`GET /rest/v1/checkins?select=id,photo_path&…`)と
 * Storage(`POST /storage/v1/object/sign/photos/<path>`)の応答なので、`supabase/functions` の実ハンドラからは作れない。
 * iOS の `PartnerCheckinRow` / `StorageSignResponse` の受け口で読む(PartnerPhotoContractTests)。
 * 本番の実応答との突き合わせ(キー・型)は backend レーンの API E2E(#67)が行う。
 * README の「手書きのフィクスチャ」の表と同じ一覧にする(足したら両方)。
 */
const HAND_WRITTEN = [
  "partner-checkin.photo.json",
  "partner-checkin.no-photo.json",
  "partner-checkin.none.json",
  "storage-sign.ok.json",
];

Deno.test("契約フィクスチャ: コミット済みの JSON がサーバー実装の出力と一致する", async () => {
  const fixtures = await buildFixtures();
  const outDir = new URL("../", import.meta.url);
  const drifted: string[] = [];
  for (const [name, value] of fixtures) {
    let current: string | null = null;
    try {
      current = await Deno.readTextFile(new URL(`${name}.json`, outDir));
    } catch {
      // 無い = 差分
    }
    if (current !== serialize(value)) drifted.push(`${name}.json`);
  }
  if (drifted.length > 0) {
    throw new Error(
      `契約フィクスチャが生成結果と一致しません: ${drifted.join(", ")}\n` +
        `deno run --allow-read --allow-write products/lien/contracts/tools/generate.ts で再生成してください`,
    );
  }
});

Deno.test("契約フィクスチャ: 作る JSON と置いてある JSON が1対1(孤児ファイルなし)", async () => {
  const fixtures = await buildFixtures();
  const expected = new Set([...fixtures.keys()].map((n) => `${n}.json`));
  for (const name of HAND_WRITTEN) expected.add(name);
  const outDir = new URL("../", import.meta.url);
  const present: string[] = [];
  for await (const entry of Deno.readDir(outDir)) {
    if (entry.isFile && entry.name.endsWith(".json")) present.push(entry.name);
  }
  const orphans = present.filter((n) => !expected.has(n));
  if (orphans.length > 0) {
    throw new Error(
      `generate.ts が作らない JSON があります: ${orphans.join(", ")}\n` +
        `手書きのフィクスチャなら contracts_test.ts の HAND_WRITTEN と README の表に足してください`,
    );
  }
});

Deno.test("契約フィクスチャ: 手書きの JSON は実在し、読め、生成物と重ならない", async () => {
  const fixtures = await buildFixtures();
  const generated = new Set([...fixtures.keys()].map((n) => `${n}.json`));
  const outDir = new URL("../", import.meta.url);
  for (const name of HAND_WRITTEN) {
    if (generated.has(name)) {
      throw new Error(
        `${name} は generate.ts も作っている。手書きの一覧から外してください`,
      );
    }
    let text: string;
    try {
      text = await Deno.readTextFile(new URL(name, outDir));
    } catch {
      throw new Error(
        `手書きのフィクスチャ ${name} がありません(HAND_WRITTEN が古い?)`,
      );
    }
    try {
      JSON.parse(text);
    } catch (e) {
      throw new Error(`${name} が JSON として読めません: ${e}`);
    }
    if (!text.endsWith("\n")) {
      throw new Error(`${name} は末尾に改行を付けてください(生成物と同じ体裁)`);
    }
  }
});
