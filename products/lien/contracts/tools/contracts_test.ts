// contracts_test.ts — コミット済みの契約フィクスチャが、サーバー実装の現在の出力と一致することの検査
//
//   deno test --allow-read products/lien/contracts/tools/
//
// サーバー(supabase/functions)の応答形を変えたら、generate.ts で再生成して差分をレビューする。
// 差分があるまま放置すると、iOS(ContractFixtureTests)が古い形を前提にデコードを検証し続けてしまう。

import { buildFixtures, serialize } from "./generate.ts";

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
  const outDir = new URL("../", import.meta.url);
  const present: string[] = [];
  for await (const entry of Deno.readDir(outDir)) {
    if (entry.isFile && entry.name.endsWith(".json")) present.push(entry.name);
  }
  const orphans = present.filter((n) => !expected.has(n));
  if (orphans.length > 0) {
    throw new Error(
      `generate.ts が作らない JSON があります: ${orphans.join(", ")}`,
    );
  }
});
