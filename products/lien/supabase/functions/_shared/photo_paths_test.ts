// photo_paths_test.ts — photo_paths.ts の deno test(外部モジュール非依存・ネットワーク不要)
// 正本: docs/DESIGN.md §5.2(写真のパスは本人単位)/ migration 0004 の is_valid_own_photo_upload / issue #68

import {
  isOwnPhotoPath,
  ownPhotoObjectsOf,
  PHOTO_FILE,
  photoUploadPaths,
  THUMB_FILE,
} from "./photo_paths.ts";

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

const PAIR = "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a";
const ME = "a1111111-1111-4111-8111-111111111111";
const PARTNER = "b2222222-2222-4222-8222-222222222222";

Deno.test("photoUploadPaths: 原寸とサムネは同じ本人の区画(pairs/<pair>/<date>/<user>/)に置く", () => {
  assertEquals(PHOTO_FILE, "photo.jpg");
  assertEquals(THUMB_FILE, "photo_thumb.jpg");
  assertEquals(photoUploadPaths(PAIR, "2026-06-11", ME), {
    photo: `pairs/${PAIR}/2026-06-11/${ME}/photo.jpg`,
    thumb: `pairs/${PAIR}/2026-06-11/${ME}/photo_thumb.jpg`,
  });
  // 同じ日でも本人ごとにパスが違う(上書きし合わない — issue #52)
  assertEquals(
    photoUploadPaths(PAIR, "2026-06-11", ME).photo ===
      photoUploadPaths(PAIR, "2026-06-11", PARTNER).photo,
    false,
  );
});

Deno.test("isOwnPhotoPath: 本人の原寸のパスだけ true(相手の区画・旧形式・サムネ・余計な階層は false)", () => {
  const mine = photoUploadPaths(PAIR, "2026-06-11", ME);
  assertEquals(isOwnPhotoPath(mine.photo, PAIR, ME), true);
  assertEquals(isOwnPhotoPath(mine.thumb, PAIR, ME), false, "サムネ");
  assertEquals(isOwnPhotoPath(mine.photo, PAIR, PARTNER), false, "他人");
  assertEquals(isOwnPhotoPath(mine.photo, "other-pair", ME), false, "他ペア");
  assertEquals(
    isOwnPhotoPath(`pairs/${PAIR}/2026-06-11/photo.jpg`, PAIR, ME),
    false,
    "旧形式",
  );
  assertEquals(
    isOwnPhotoPath(`pairs/${PAIR}/2026-6-11/${ME}/photo.jpg`, PAIR, ME),
    false,
    "日付の形式不正",
  );
  assertEquals(
    isOwnPhotoPath(`${mine.photo}/x`, PAIR, ME),
    false,
    "余計な階層",
  );
});

Deno.test("ownPhotoObjectsOf: 本人の区画の原寸のパスから、原寸+サムネのパス・ペア・日付を返す", () => {
  const mine = photoUploadPaths(PAIR, "2026-06-11", ME);
  assertEquals(ownPhotoObjectsOf(mine.photo, ME), {
    photo: mine.photo,
    thumb: mine.thumb,
    pairId: PAIR,
    dateLocal: "2026-06-11",
  });
  // ペアは問わない(同じ日のうちにペアを組み直すと、行が前のペアの区画を指す)
  assertEquals(
    ownPhotoObjectsOf(`pairs/old-pair/2026-06-11/${ME}/photo.jpg`, ME)?.pairId,
    "old-pair",
  );
});

Deno.test("ownPhotoObjectsOf: 他人の区画・旧形式・サムネ・規約外・区画の細工は null(消さない)", () => {
  const mine = photoUploadPaths(PAIR, "2026-06-11", ME);
  const cases: Array<[string, string]> = [
    ["相手の区画", `pairs/${PAIR}/2026-06-11/${PARTNER}/photo.jpg`],
    ["旧形式(ペア×日付単位)", `pairs/${PAIR}/2026-06-11/photo.jpg`],
    ["サムネのパス", mine.thumb],
    ["規約外のファイル名", `pairs/${PAIR}/2026-06-11/${ME}/evil.jpg`],
    ["日付の形式不正", `pairs/${PAIR}/2026-6-11/${ME}/photo.jpg`],
    ["日付が日付でない文字", `pairs/${PAIR}/xxxx-xx-xx/${ME}/photo.jpg`],
    ["pairs でない", `x/${PAIR}/2026-06-11/${ME}/photo.jpg`],
    ["ペアの区画が ..", `pairs/../2026-06-11/${ME}/photo.jpg`],
    ["ペアの区画が .", `pairs/./2026-06-11/${ME}/photo.jpg`],
    ["ペアの区画が空", `pairs//2026-06-11/${ME}/photo.jpg`],
    ["余計な階層", `${mine.photo}/x`],
    ["階層が足りない", `pairs/${PAIR}/${ME}/photo.jpg`],
    ["空文字", ""],
    [
      "本人の ID を前方一致で含む別の ID",
      `pairs/${PAIR}/2026-06-11/${ME}x/photo.jpg`,
    ],
  ];
  for (const [name, path] of cases) {
    assertEquals(ownPhotoObjectsOf(path, ME), null, name);
  }
  assertEquals(ownPhotoObjectsOf(mine.photo, ""), null, "userId が空");
});
