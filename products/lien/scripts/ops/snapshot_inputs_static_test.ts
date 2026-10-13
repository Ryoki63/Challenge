// snapshot_inputs_static_test.ts — snapshot の入力(現役のペアの読み出し)の静的テスト(issue #19)
//
// snapshot の ticketBalance(ペア共有のお休みチケットの残数。ホームの残数バッジ)は、各 Function の index.ts の
// getActivePair が pairs.ticket_balance を読んで渡す。単体テストの偽リポジトリでは index.ts を通らないので、
// 「ticket_balance を select し忘れた(バッジが黙って出なくなる)」を検知できない。各 index.ts が
// _shared/pair_rows.ts の ACTIVE_PAIR_SELECT / toSnapshotPair を使っていること、pairs の select を直書きして
// ticket_balance が抜けていないことを、ソースを読んで検査する(push_env_static_test.ts と同じ考え方)。
//
// 実行: deno test --allow-read products/lien/scripts/ops/(lien-ci の ops-tests ジョブ)

const FUNCTIONS = new URL("../../supabase/functions/", import.meta.url);

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
  return await Deno.readTextFile(new URL(rel, FUNCTIONS));
}

/** コメント行を除いたコード(行頭の // と * だけを見る。この検査が見る文字列はコメントに書かれうるため) */
function codeOf(src: string): string {
  return src.split("\n").filter((l) =>
    !l.trim().startsWith("//") && !l.trim().startsWith("*")
  ).join("\n");
}

/** index.ts に getActivePair を実装している Function */
async function functionsWithActivePair(): Promise<string[]> {
  const names: string[] = [];
  for await (const entry of Deno.readDir(FUNCTIONS)) {
    if (!entry.isDirectory || entry.name.startsWith("_")) continue;
    let index: string;
    try {
      index = await read(`${entry.name}/index.ts`);
    } catch {
      continue;
    }
    if (index.includes("async getActivePair(")) names.push(entry.name);
  }
  return names.sort();
}

/** index.ts の getActivePair の本体(次のメソッドの手前まで)。メソッドは 4 スペースの字下げで並ぶ */
function activePairBody(code: string): string {
  const start = code.indexOf("async getActivePair(");
  if (start < 0) return "";
  const next = code.indexOf("\n    async ", start + 1);
  return next < 0 ? code.slice(start) : code.slice(start, next);
}

/**
 * snapshot の組み立てに使わない(残数を読まなくてよい)Function。
 * invite-create の getActivePair は「すでにペアが居るか」を見るだけで、snapshot を作らない
 */
const NO_SNAPSHOT = ["invite-create"];

Deno.test("getActivePair を実装する Function は 12 個(増えたら、その index.ts も下の検査に入る)", async () => {
  assertEquals(await functionsWithActivePair(), [
    "checkin",
    "checkin-cancel",
    "close-day",
    "delete-account",
    "invite-accept",
    "invite-create",
    "nudge",
    "pair-dissolve",
    "plant-name",
    "promise-set",
    "react",
    "snapshot",
  ]);
});

Deno.test("snapshot を組み立てる Function の index.ts は、現役のペアの読み出しに ACTIVE_PAIR_SELECT / toSnapshotPair を使う(ticket_balance の読み忘れ防止)", async () => {
  for (const fn of await functionsWithActivePair()) {
    if (NO_SNAPSHOT.includes(fn)) continue;
    const body = activePairBody(codeOf(await read(`${fn}/index.ts`)));
    assert(body.length > 0, `${fn}: getActivePair の本体を取り出せない`);
    assert(
      body.includes(".select(ACTIVE_PAIR_SELECT)"),
      `${fn}: getActivePair が ACTIVE_PAIR_SELECT で読んでいない(ticket_balance が抜ける)`,
    );
    assert(
      body.includes("toSnapshotPair("),
      `${fn}: toSnapshotPair で行を変換していない(ticketBalance が snapshot に届かない)`,
    );
    // pairs の列を直書きの select で読まない(ticket_balance が抜ける)
    assert(
      !body.includes("pairs!inner("),
      `${fn}: getActivePair が pairs!inner を直書きの select で読んでいる(ticket_balance が抜ける)`,
    );
  }
});

Deno.test("ACTIVE_PAIR_SELECT は ticket_balance を読む。toSnapshotPair はそれを ticketBalance に渡す", async () => {
  const src = codeOf(await read("_shared/pair_rows.ts"));
  assert(
    /ACTIVE_PAIR_SELECT =\s*"[^"]*pairs!inner\([^"]*\bticket_balance\b[^"]*\)"/
      .test(src),
    "ACTIVE_PAIR_SELECT に ticket_balance が無い",
  );
  assert(
    src.includes("row.ticketBalance = balance"),
    "toSnapshotPair が ticket_balance を ticketBalance に渡していない",
  );
});

Deno.test("loadSnapshotForUser は読んだ残数を snapshot に渡す(ticketBalance: pair.ticketBalance)", async () => {
  const src = codeOf(await read("_shared/snapshot.ts"));
  assert(
    /ticketBalance:\s*pair\.ticketBalance/.test(src),
    "loadSnapshotForUser が pair.ticketBalance を buildPairSnapshot に渡していない",
  );
  assert(
    /ticketBalance:\s*null/.test(src),
    "ソロの snapshot が ticketBalance: null を出していない(キーを省略しない)",
  );
});
