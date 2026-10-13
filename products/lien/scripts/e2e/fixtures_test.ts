// fixtures_test.ts — fixtures.ts(契約フィクスチャから作る応答の形)の deno test。ネットワーク・本番は使わない
//
//   deno test --allow-read products/lien/scripts/e2e/

import {
  buildFixtures,
  loadFixtures,
  OPTIONAL_FILES,
  REQUIRED_FILES,
} from "./fixtures.ts";
import { diffShape } from "./shape.ts";

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

function clone<T>(v: T): T {
  return JSON.parse(JSON.stringify(v));
}

type J = Record<string, unknown>;

Deno.test("loadFixtures: 19 ファイルが読める・語彙とエラー台帳がある", async () => {
  const fx = await loadFixtures();
  assertEquals(Object.keys(fx.raw).length, 19);
  assertEquals(fx.stamps.nudge.length, 6);
  assertEquals(fx.stamps.reaction.length, 6);
  assertEquals(Array.isArray(fx.errors["checkin"]?.["no_pair"]), true);
});

Deno.test("各フィクスチャは、自分の系統の形に収まる", async () => {
  const fx = await loadFixtures();
  const cases: Array<[string, keyof typeof fx]> = [
    ["snapshot.paired.json", "snapshotGet"],
    ["snapshot.solo.json", "snapshotGet"],
    ["snapshot.empty.json", "snapshotGet"],
    ["checkin.paired.json", "checkin"],
    ["checkin.solo.json", "checkin"],
    ["checkin.photo-upload.json", "checkin"],
    ["checkin-cancel.ok.json", "checkinCancel"],
    ["promise-set.ok.json", "promiseSet"],
    ["invite-create.ok.json", "inviteCreate"],
    ["invite-accept.ok.json", "inviteAccept"],
    ["nudge.ok.json", "nudge"],
    ["react.ok.json", "react"],
    ["plant-name.ok.json", "plantName"],
    ["plant-name.already-named.json", "plantNameAlreadyNamed"],
    ["pair-dissolve.ok.json", "pairDissolve"],
    ["pair-dissolve.already.json", "pairDissolve"],
    ["delete-account.ok.json", "deleteAccount"],
  ];
  for (const [file, family] of cases) {
    // deno-lint-ignore no-explicit-any
    assertEquals(diffShape(fx.raw[file], fx[family] as any), [], file);
  }
});

Deno.test("snapshot を含む応答は、PairSnapshot の合成した形で見る(名前なし・ソロの null を許す)", async () => {
  const fx = await loadFixtures();
  // nudge.ok.json は名前付きだが、実際は名前が付く前の plantName = null がありうる
  const nudge = clone(fx.raw["nudge.ok.json"]) as { snapshot: J };
  nudge.snapshot.plantName = null;
  assertEquals(diffShape(nudge, fx.nudge), []);
  // checkin-cancel.ok.json はペア成立済みだが、ソロの取消ではペア関連が null になる
  const cancel = clone(fx.raw["checkin-cancel.ok.json"]) as { snapshot: J };
  Object.assign(cancel.snapshot, {
    pairId: null,
    partnerName: null,
    partnerPromiseTitle: null,
    partnerPromiseEmoji: null,
    plantNextStageAt: null,
    plantName: null,
  });
  assertEquals(diffShape(cancel, fx.checkinCancel), []);
});

Deno.test("snapshot の中のキー欠落・型違い・増えたキーは、どの応答でも拾う", async () => {
  const fx = await loadFixtures();
  const broken = clone(fx.raw["nudge.ok.json"]) as { snapshot: J };
  delete broken.snapshot.plantStageFloor;
  broken.snapshot.streakCurrent = "1";
  broken.snapshot.brandNewKey = true;
  assertEquals(
    diffShape(broken, fx.nudge).map((d) => `${d.kind}:${d.path}`).sort(),
    [
      "extra:$.snapshot.brandNewKey",
      "missing:$.snapshot.plantStageFloor",
      "type:$.snapshot.streakCurrent",
    ],
  );
});

Deno.test("pair-dissolve / delete-account の形: 解消した・すでに無かった、の両方を通し、キーの欠落・型違いを拾う", async () => {
  const fx = await loadFixtures();
  // 解消した応答とすでにペアが無かった応答の snapshot はどちらもソロの形(ペア関連が null)
  for (const file of ["pair-dissolve.ok.json", "pair-dissolve.already.json"]) {
    assertEquals(diffShape(fx.raw[file], fx.pairDissolve), [], file);
  }
  const broken = clone(fx.raw["pair-dissolve.ok.json"]) as J;
  broken.dissolved = "yes";
  delete (broken.snapshot as J).plantName;
  assertEquals(
    diffShape(broken, fx.pairDissolve).map((d) => `${d.kind}:${d.path}`).sort(),
    ["missing:$.snapshot.plantName", "type:$.dissolved"],
  );
  assertEquals(diffShape({ deleted: true }, fx.deleteAccount), []);
  assertEquals(
    diffShape({ deleted: "true" }, fx.deleteAccount).map((d) => d.kind),
    ["type"],
  );
  assertEquals(
    diffShape({ deleted: true, extra: 1 }, fx.deleteAccount).map((d) => d.kind),
    ["extra"],
  );
});

Deno.test("チェックインの photoUpload は任意・あれば形を守る", async () => {
  const fx = await loadFixtures();
  const plain = clone(fx.raw["checkin.paired.json"]);
  assertEquals(diffShape(plain, fx.checkin), []);
  const upload = clone(fx.raw["checkin.photo-upload.json"]) as {
    photoUpload: { thumb: J };
  };
  upload.photoUpload.thumb.path = 5;
  assertEquals(
    diffShape(upload, fx.checkin).map((d) => d.path),
    ["$.photoUpload.thumb.path"],
  );
});

Deno.test("任意の手書きフィクスチャが無くても読める(その確認は SKIP になる)", async () => {
  const fx = await loadFixtures();
  const withoutOptional = buildFixtures(fx.raw, {});
  assertEquals(withoutOptional.partnerCheckin, undefined);
  assertEquals(withoutOptional.storageSign, undefined);
  assertEquals(withoutOptional.storageSignNotFound, undefined);
  // 必須のものは変わらず使える
  assertEquals(diffShape(fx.raw["nudge.ok.json"], withoutOptional.nudge), []);
});

Deno.test("手書きフィクスチャ(PostgREST / Storage)があれば、行・署名の形を作る", async () => {
  const fx = await loadFixtures();
  const photoRow = [{
    id: "8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80",
    photo_path: "pairs/x/2026-10-13/y/photo.jpg",
  }];
  const noPhotoRow = [{
    id: "8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80",
    photo_path: null,
  }];
  const built = buildFixtures(fx.raw, {
    "partner-checkin.photo.json": photoRow,
    "partner-checkin.no-photo.json": noPhotoRow,
    "partner-checkin.none.json": [],
    "storage-sign.ok.json": { signedURL: "/object/sign/photos/p?token=t" },
    "storage-sign.not-found.json": {
      statusCode: "404",
      error: "not_found",
      message: "Object not found",
    },
  });
  const rows = built.partnerCheckin;
  const sign = built.storageSign;
  if (!rows || !sign) throw new Error("形が作られていない");
  // 写真あり・なし・0 件のどれも通る。キーの欠落・増加・型違いは拾う
  assertEquals(diffShape(photoRow, rows), []);
  assertEquals(diffShape(noPhotoRow, rows), []);
  assertEquals(diffShape([], rows), []);
  assertEquals(diffShape([{ id: "x" }], rows).map((d) => d.kind), ["missing"]);
  assertEquals(
    diffShape([{ id: "x", photo_path: 5 }], rows).map((d) => d.kind),
    ["type"],
  );
  assertEquals(
    diffShape([{ id: "x", photo_path: null, extra: 1 }], rows).map((d) =>
      d.kind
    ),
    ["extra"],
  );
  assertEquals(
    diffShape({ signedURL: "/object/sign/photos/q?token=u" }, sign),
    [],
  );
  assertEquals(diffShape({ signedUrl: "x" }, sign).map((d) => d.kind).sort(), [
    "extra",
    "missing",
  ]);
  // 署名の発行の失敗の本文は、そのままの JSON(値を比べる。形ではない)
  assertEquals(built.storageSignNotFound, {
    statusCode: "404",
    error: "not_found",
    message: "Object not found",
  });
  // オブジェクトでないもの(配列・null)は、フィクスチャとして扱わない
  assertEquals(
    buildFixtures(fx.raw, { "storage-sign.not-found.json": [] })
      .storageSignNotFound,
    undefined,
  );
  assertEquals(
    buildFixtures(fx.raw, { "storage-sign.not-found.json": null })
      .storageSignNotFound,
    undefined,
  );
});

Deno.test("OPTIONAL_FILES と REQUIRED_FILES は重ならない", () => {
  const overlap = OPTIONAL_FILES.filter((f) =>
    (REQUIRED_FILES as readonly string[]).includes(f)
  );
  assertEquals(overlap, []);
});
