// photo_cleanup_static_test.ts — 写真の実体の掃除とバケットの制限の静的テスト(issue #68)
//
// 取り消し(checkin-cancel)と差し替え(checkin)は、行を書き換えるだけでなく Storage の実体も消す。
// 単体テストの偽リポジトリでは index.ts を通らないので、「消した行の photo_path を返し忘れた」
// 「Storage の remove を呼ばない実装になっている」を検知できない。ソースを読んで検査する。
// あわせて、photos バケットの制限(migration 0008)が、アプリの上限と整合した値のままであることを検査する。
//
// 実行: deno test --allow-read products/lien/scripts/ops/(lien-ci の ops-tests ジョブ)

const SUPABASE = new URL("../../supabase/", import.meta.url);

function assert(cond: boolean, msg = ""): void {
  if (!cond) throw new Error(`assert failed: ${msg}`);
}

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

async function read(rel: string): Promise<string> {
  return await Deno.readTextFile(new URL(rel, SUPABASE));
}

/** コメント行を除いたコード */
function codeOf(src: string): string {
  return src.split("\n").filter((l) =>
    !l.trim().startsWith("//") && !l.trim().startsWith("*")
  ).join("\n");
}

/** SQL の行コメント(-- ...)を落とす */
function stripSqlComments(sql: string): string {
  return sql.split("\n").map((line) => line.replace(/--.*$/, "")).join("\n");
}

Deno.test("checkin-cancel/index.ts: 消した行の photo_path を返し、service role で photos バケットのオブジェクトを消す", async () => {
  const code = codeOf(await read("functions/checkin-cancel/index.ts"));
  assert(
    /\.delete\(\)[\s\S]*?\.select\("id, photo_path"\)/.test(code),
    'deleteCheckin が photo_path を返していない(.delete().select("id, photo_path"))',
  );
  assert(
    /photoPath:\s*typeof photoPath === "string" \? photoPath : null/.test(code),
    "deleteCheckin が消した行の photoPath を返していない",
  );
  assert(
    /async removePhotos\(/.test(code) &&
      /db\.storage\.from\("photos"\)\.remove\(paths\)/.test(code),
    "removePhotos が photos バケットの remove を呼んでいない",
  );
});

Deno.test("checkin-cancel/core.ts: 行を消したあとで実体を消し、失敗しても取消は成功にする", async () => {
  const code = codeOf(await read("functions/checkin-cancel/core.ts"));
  const deleteAt = code.indexOf("deps.repo.deleteCheckin(");
  const removeAt = code.indexOf("removeCancelledPhotos(deps.repo");
  const pushAt = code.indexOf("deps.pusher.send(");
  assert(deleteAt > 0 && removeAt > 0 && pushAt > 0, "呼び出しが見つからない");
  assert(
    deleteAt < removeAt && removeAt < pushAt,
    "順序が 行の削除 → 実体の削除 → 相手への push になっていない",
  );
  assert(
    /try\s*\{\s*await repo\.removePhotos\(paths\);\s*\}\s*catch/.test(code),
    "実体の削除が try/catch で包まれていない(失敗で取消が失敗になる)",
  );
});

Deno.test("checkin/index.ts: 写真を差し替えたとき更新前の photo_path を返し、service role で実体を消せる", async () => {
  const code = codeOf(await read("functions/checkin/index.ts"));
  assert(
    /previousPhotoPath:\s*typeof existing\.photo_path === "string"/.test(code),
    "upsertCheckin が更新前の photo_path(previousPhotoPath)を返していない",
  );
  assert(
    /async removePhotos\(/.test(code) &&
      /db\.storage\.from\("photos"\)\.remove\(paths\)/.test(code),
    "removePhotos が photos バケットの remove を呼んでいない",
  );
});

Deno.test("消す写真は本人の区画だけ: ownPhotoObjectsOf で検査してから消す", async () => {
  const cancel = codeOf(await read("functions/checkin-cancel/core.ts"));
  assert(
    cancel.includes("ownPhotoObjectsOf(params.rowPhotoPath, params.userId)"),
    "checkin-cancel: 行の photo_path を本人の区画かどうか検査していない",
  );
  const checkin = codeOf(await read("functions/checkin/core.ts"));
  assert(
    checkin.includes(
      "ownPhotoObjectsOf(params.previousPhotoPath, params.userId)",
    ),
    "checkin: 古い photo_path を本人の区画かどうか検査していない",
  );
  // 決定的なパスは呼び出し本人の userId だけで作る(相手の ID を使わない)
  assert(
    /photoUploadPaths\(\s*params\.pairId,\s*params\.dateLocal,\s*params\.userId,?\s*\)/
      .test(cancel),
    "checkin-cancel: 決定的なパスが本人の userId で作られていない",
  );
});

Deno.test("migration 0008: photos バケットの制限は 6 MiB・image/jpeg だけ(アプリの上限と整合)", async () => {
  const sql = stripSqlComments(
    await read("migrations/0008_photo_bucket_limits.sql"),
  );
  // アプリが受け取る原寸の上限は 6 MiB(PartnerPhotoLimits.original)。サムネ(512KB)は同じバケットなので別には縛れない
  assertEquals(6 * 1024 * 1024, 6291456);
  assert(
    /file_size_limit\s*=\s*6291456\b/.test(sql),
    "file_size_limit が 6 MiB(6291456)でない",
  );
  assert(
    /allowed_mime_types\s*=\s*array\['image\/jpeg'\]/.test(sql),
    "allowed_mime_types が image/jpeg だけでない",
  );
  assert(/where id = 'photos'/.test(sql), "対象が photos バケットだけでない");
  assert(
    /if not found then\s*raise exception/.test(sql),
    "バケットが無いときに止まらない(黙って適用済みになる)",
  );
  // 追加系のみ: ポリシー・関数・表を作らない/消さない
  assert(
    !/\b(drop|create|alter|delete|truncate)\b/i.test(sql),
    "バケットの 2 列の更新以外の DDL / delete が入っている",
  );
});
