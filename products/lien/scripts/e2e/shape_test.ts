// shape_test.ts — shape.ts の deno test。ネットワーク・本番は使わない
//
//   deno test --allow-read products/lien/scripts/e2e/
//
// 実フィクスチャ(products/lien/contracts/)を読んで、「フィクスチャ自身は自分の形に収まる」「1 か所ずつ
// 壊すとずれとして検出される」ことを確かめる。通しテスト本体(e2e.ts)は本番を叩くので、ここでは動かさない。

import {
  diffShape,
  diffValues,
  formatDeviation,
  inferSchema,
  jsonEqual,
  schemaFrom,
} from "./shape.ts";

// ---- 自作 assert ヘルパ(外部モジュールを使わない。scripts/ops/*_test.ts と同じ) ----

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

const CONTRACTS = new URL("../../contracts/", import.meta.url);

async function fixture(name: string): Promise<Record<string, unknown>> {
  return JSON.parse(await Deno.readTextFile(new URL(name, CONTRACTS)));
}

function clone<T>(v: T): T {
  return JSON.parse(JSON.stringify(v));
}

Deno.test("フィクスチャ自身は、自分たちを合成した形に収まる", async () => {
  const names = [
    "snapshot.paired.json",
    "snapshot.solo.json",
    "snapshot.empty.json",
  ];
  const samples = await Promise.all(names.map(fixture));
  const schema = schemaFrom(...samples);
  for (const [i, s] of samples.entries()) {
    assertEquals(diffShape(s, schema), [], names[i]);
  }
});

Deno.test("snapshot: pairId はペアで string・ソロで null のどちらも通る(合成)", async () => {
  const paired = await fixture("snapshot.paired.json");
  const solo = await fixture("snapshot.solo.json");
  const schema = schemaFrom(paired, solo);
  assertEquals(diffShape(paired, schema), []);
  assertEquals(diffShape(solo, schema), []);
  // 1 つのフィクスチャだけの形では、ソロの null がずれになる(合成する理由)
  const pairedOnly = inferSchema(paired);
  const devs = diffShape(solo, pairedOnly);
  assertEquals(devs.some((d) => d.path === "$.snapshot.pairId"), true);
});

Deno.test("キーが 1 つ欠けると missing、増えると extra、型が変わると type", async () => {
  const paired = await fixture("snapshot.paired.json");
  const schema = schemaFrom(paired);

  const missing = clone(paired) as { snapshot: Record<string, unknown> };
  delete missing.snapshot.plantGrownDays;
  assertEquals(
    diffShape(missing, schema).map((d) => [d.path, d.kind]),
    [["$.snapshot.plantGrownDays", "missing"]],
  );

  const extra = clone(paired) as { snapshot: Record<string, unknown> };
  extra.snapshot.newKey = 1;
  assertEquals(
    diffShape(extra, schema).map((d) => [d.path, d.kind]),
    [["$.snapshot.newKey", "extra"]],
  );

  const wrongType = clone(paired) as { snapshot: Record<string, unknown> };
  wrongType.snapshot.streakCurrent = "6";
  assertEquals(
    diffShape(wrongType, schema).map((d) => [d.path, d.kind]),
    [["$.snapshot.streakCurrent", "type"]],
  );
});

Deno.test("整数の標本には小数を許さない(Swift の Int でデコードできない)", async () => {
  const paired = await fixture("snapshot.paired.json");
  const schema = schemaFrom(paired);
  const bad = clone(paired) as { snapshot: Record<string, unknown> };
  bad.snapshot.streakCurrent = 6.5;
  const devs = diffShape(bad, schema);
  assertEquals(devs.length, 1);
  assertEquals(devs[0].expected, "integer");
  assertEquals(formatDeviation(devs[0]).includes("integer"), true);
});

Deno.test("標本の一部にしか無いキーは任意(checkin の photoUpload)", async () => {
  const paired = await fixture("checkin.paired.json");
  const solo = await fixture("checkin.solo.json");
  const upload = await fixture("checkin.photo-upload.json");
  const schema = schemaFrom(paired, solo, upload);
  assertEquals(diffShape(paired, schema), []);
  assertEquals(diffShape(upload, schema), []);

  // photoUpload の中身は、あるなら形を守る
  const broken = clone(upload) as {
    photoUpload: { photo: Record<string, unknown> };
  };
  delete broken.photoUpload.photo.token;
  assertEquals(
    diffShape(broken, schema).map((d) => [d.path, d.kind]),
    [["$.photoUpload.photo.token", "missing"]],
  );
});

Deno.test("nullable で追加の null を許す(promise-set の remindAt)", async () => {
  const ok = await fixture("promise-set.ok.json");
  const schema = schemaFrom(ok);
  const withNull = clone(ok) as { promise: Record<string, unknown> };
  withNull.promise.remindAt = null;
  assertEquals(
    diffShape(withNull, schema).map((d) => d.path),
    ["$.promise.remindAt"],
  );
  assertEquals(
    diffShape(withNull, schema, { nullable: ["$.promise.remindAt"] }),
    [],
  );
});

Deno.test("配列は要素ごとに形を見る", () => {
  const schema = schemaFrom({ rows: [{ id: "a", n: 1 }] });
  assertEquals(
    diffShape({ rows: [{ id: "x", n: 2 }, { id: "y", n: 3 }] }, schema),
    [],
  );
  assertEquals(
    diffShape({ rows: [{ id: "x", n: 2 }, { id: 5, n: 3 }] }, schema).map((
      d,
    ) => d.path),
    ["$.rows[1].id"],
  );
});

Deno.test("diffValues: ignore した位置は比べない・それ以外の違いは拾う", async () => {
  const solo = await fixture("snapshot.solo.json");
  const actual = clone(solo) as { snapshot: Record<string, unknown> };
  actual.snapshot.updatedAt = "2026-10-13T00:00:00.000Z";
  actual.snapshot.myPromiseTitle = "E2E 読書";
  assertEquals(
    diffValues(actual, solo, [
      "$.snapshot.updatedAt",
      "$.snapshot.myPromiseTitle",
    ]),
    [],
  );
  actual.snapshot.plantStage = 1;
  assertEquals(
    diffValues(actual, solo, [
      "$.snapshot.updatedAt",
      "$.snapshot.myPromiseTitle",
    ]).map((d) => d.path),
    ["$.snapshot.plantStage"],
  );
});

Deno.test("jsonEqual: キーの順序は問わない", () => {
  assertEquals(jsonEqual({ a: 1, b: [1, 2] }, { b: [1, 2], a: 1 }), true);
  assertEquals(jsonEqual({ a: 1 }, { a: 2 }), false);
  assertEquals(jsonEqual({ a: 1 }, { a: 1, b: 2 }), false);
});
