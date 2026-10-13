// images_test.ts — images.ts の deno test(ネットワーク・本番は使わない)
//
//   deno test --allow-read products/lien/scripts/e2e/
//
// 見るもの: 上限超え・JPEG 以外の確認に使うバイト列が、確認したい性質を本当に持っていること
// (上限を 1 バイト超える・JPEG の見た目 / PNG のシグネチャで JPEG でない)と、通しテストが前提にする上限が
// バケットの制限(migration 0008)と同じ値であること。

import {
  looksLikeJpeg,
  oversizedJpegLike,
  PHOTO_1,
  PHOTO_LIMIT_BYTES,
  PNG_LIKE,
  THUMB,
} from "./images.ts";
import { assertEquals } from "./test_util.ts";

Deno.test("oversizedJpegLike: 上限(6 MiB)を 1 バイトだけ超える・先頭は JPEG(Content-Type 以外で断られない)", () => {
  const bytes = oversizedJpegLike();
  assertEquals(bytes.length, PHOTO_LIMIT_BYTES + 1);
  assertEquals(PHOTO_LIMIT_BYTES, 6 * 1024 * 1024);
  assertEquals(looksLikeJpeg(bytes), true);
});

Deno.test("PNG_LIKE: PNG のシグネチャで始まり、JPEG ではない。通常の写真は上限に収まる JPEG", () => {
  assertEquals(
    [...PNG_LIKE.slice(0, 8)],
    [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  );
  assertEquals(looksLikeJpeg(PNG_LIKE), false);
  for (const ok of [PHOTO_1, THUMB]) {
    assertEquals(looksLikeJpeg(ok), true);
    assertEquals(ok.length <= PHOTO_LIMIT_BYTES, true);
  }
});

Deno.test("PHOTO_LIMIT_BYTES は migration 0008 の file_size_limit と同じ(通しテストの前提とバケットの制限がずれない)", async () => {
  const sql = await Deno.readTextFile(
    new URL(
      "../../supabase/migrations/0008_photo_bucket_limits.sql",
      import.meta.url,
    ),
  );
  const m = /file_size_limit\s*=\s*(\d+)/.exec(
    sql.split("\n").map((l) => l.replace(/--.*$/, "")).join("\n"),
  );
  assertEquals(m !== null && Number(m[1]) === PHOTO_LIMIT_BYTES, true);
});
