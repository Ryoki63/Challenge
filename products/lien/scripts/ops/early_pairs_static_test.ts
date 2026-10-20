// early_pairs_static_test.ts — 先行ペア募集(MK4 / issue #77)の文面を静的に検査する
//
// 下書きのまま投稿・送信されると困る種類の事故を、CI で止める:
//   1. X の本文が 140 字を超える / 日付を断定する(公開日は審査結果で動く)
//   2. 罰・煽り・誇大表現、v1.0 に無い機能、競合名が本文に混ざる
//   3. 連絡先・ストア URL を推測で埋める(G4 / G0 の確定前に送らないためのトークン)
//   4. 記録欄から組 ID が抜ける / 記入例が集計に混ざる
//
// 対象は「本文」の見出し(`## 本文…`)に続く引用ブロックと、知人向けの文面。
// 手順や注意書きの地の文は対象外(禁止語の一覧そのものを書いているため)。
//
// 実行(ファイルを読むので --allow-read が要る。lien-ci の ops-tests ジョブで回る):
//   deno test --allow-read products/lien/scripts/ops/

const DIR = new URL("../../marketing/early-pairs/", import.meta.url);
const README = new URL("README.md", DIR);
const X_POST = new URL("x-post.md", DIR);
const ACQUAINTANCE = new URL("acquaintance.md", DIR);
const ACCEPTANCE = new URL("acceptance.md", DIR);
const TRACKER = new URL("tracker.md", DIR);

const FILES = [README, X_POST, ACQUAINTANCE, ACCEPTANCE, TRACKER];

const X_BODY_LIMIT = 140;

// アプリ本体の禁止語 8 語(LienTests の PunishmentFreeLint と同じ)+ 投稿用の追加語。
const BANNED = new RegExp(
  [
    "枯れ",
    "サボ",
    "罰",
    "恥",
    "ダメ",
    "怒",
    "遅い",
    "まだやってない",
    "失敗",
    "逃す",
    "急げ",
    "今すぐ",
    "絶対",
    "必ず",
    "日本一",
    "No\\.?\\s?1",
    "業界初",
    "唯一",
    "永久無料",
    "完全無料",
    "最強",
    "神アプリ",
    "誰でも",
    "限定",
    "保証",
    "確実",
  ].join("|"),
);

// v1.0 に無い機能(REQUIREMENTS §3 の [v1.0.1] / [v1.1] / [v2+])。
const NOT_IN_V1 =
  /課金|プレミアム|アルバム|複数ペア|Sign in with Apple|Apple でログイン|カメラ|Android|有料/;

// 競合サービス名(TASKPLAN §9.4 の T32 で全廃)。
const COMPETITOR = /pairy|ぺあり|ペアリー/i;

// X の本文で断定しない日付(公開日は審査結果に依存する)。
const DATE_ASSERTION =
  /[0-9]{1,2}\s*月\s*[0-9]{1,2}\s*日|[0-9]{1,2}\/[0-9]{1,2}|[0-9]{4}\s*年/;

const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`assert failed: ${msg}`);
}

async function read(url: URL): Promise<string> {
  return await Deno.readTextFile(url);
}

/** 見出し `## 本文…` に続く引用ブロックを取り出す(見出しは含まない) */
function quoteBlocks(text: string): string[] {
  const lines = text.split("\n");
  const blocks: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (!/^#{2,4}\s+(代替)?本文/.test(lines[i])) continue;
    const body: string[] = [];
    let started = false;
    for (let j = i + 1; j < lines.length; j++) {
      const line = lines[j];
      if (line.startsWith(">")) {
        started = true;
        body.push(line.replace(/^>\s?/, ""));
        continue;
      }
      if (!started) continue; // 見出し直後の空行
      break;
    }
    if (body.length > 0) blocks.push(body.join("\n").trimEnd());
  }
  return blocks;
}

/** 見出しの文言で引用ブロックを 1 つ取り出す */
function quoteBlockUnder(text: string, headingIncludes: string): string {
  const lines = text.split("\n");
  const start = lines.findIndex((line) =>
    /^#{2,4}\s+(代替)?本文/.test(line) && line.includes(headingIncludes)
  );
  if (start < 0) {
    throw new Error(`本文の見出しがありません: ${headingIncludes}`);
  }
  const body: string[] = [];
  for (let j = start + 1; j < lines.length; j++) {
    if (lines[j].startsWith(">")) {
      body.push(lines[j].replace(/^>\s?/, ""));
      continue;
    }
    if (body.length === 0) continue;
    break;
  }
  return body.join("\n").trimEnd();
}

/** JS の length は UTF-16 のコードユニット数(絵文字を 2 字と数える保守的な側) */
function effectiveLength(text: string): number {
  return text.length;
}

Deno.test("募集文のファイルが揃っている", async () => {
  for (const url of FILES) {
    const stat = await Deno.stat(url);
    assert(stat.isFile, `${url.pathname} がファイルではありません`);
  }
});

Deno.test("X の本文は 140 字以内で、日付・禁止語・未実装機能・競合名を含まない", async () => {
  const bodies = quoteBlocks(await read(X_POST));
  assert(bodies.length === 4, `X の本文は 4 本のはずが ${bodies.length} 本`);

  for (const [index, body] of bodies.entries()) {
    const label = `X 本文 ${index + 1}`;
    assert(
      effectiveLength(body) <= X_BODY_LIMIT,
      `${label} が ${effectiveLength(body)} 字(上限 ${X_BODY_LIMIT})`,
    );
    assert(!DATE_ASSERTION.test(body), `${label} に日付の断定がある`);
    const banned = body.match(BANNED);
    assert(!banned, `${label} に禁止語「${banned?.[0]}」がある`);
    const feature = body.match(NOT_IN_V1);
    assert(!feature, `${label} に v1.0 に無い機能「${feature?.[0]}」がある`);
    assert(!COMPETITOR.test(body), `${label} に競合サービス名がある`);
  }

  const text = await read(X_POST);
  const explained = text.split("数値の根拠").length - 1;
  assert(explained >= 4, `数値の根拠が ${explained} 個しかない(投稿は 4 本)`);
});

Deno.test("受け入れ手順の文面に禁止語・未実装機能が混ざらない", async () => {
  for (const url of [ACCEPTANCE, ACQUAINTANCE]) {
    const text = await read(url);
    const bodies = url === ACCEPTANCE ? quoteBlocks(text) : [text];
    assert(bodies.length > 0, `${url.pathname} に本文がない`);

    for (const [index, body] of bodies.entries()) {
      const label = `${url.pathname} の文面 ${index + 1}`;
      const banned = body.match(BANNED);
      assert(!banned, `${label} に禁止語「${banned?.[0]}」がある`);
      const feature = body.match(NOT_IN_V1);
      assert(!feature, `${label} に v1.0 に無い機能「${feature?.[0]}」がある`);
      assert(!COMPETITOR.test(body), `${label} に競合サービス名がある`);
    }
  }
});

Deno.test("連絡先とストア URL はトークンのまま(G4・G0 の確定前に埋めない)", async () => {
  const acceptance = await read(ACCEPTANCE);
  assert(
    acceptance.includes("<CONTACT_EMAIL>"),
    "受け入れ手順に <CONTACT_EMAIL> が無い(G4 の確定値に置換する目印)",
  );
  assert(
    acceptance.includes("<APP_STORE_URL>"),
    "受け入れ手順に <APP_STORE_URL> が無い(G0 後の確定値に置換する目印)",
  );

  for (const url of FILES) {
    const text = await read(url);
    const email = text.match(EMAIL);
    assert(
      !email,
      `${url.pathname} にメールアドレスらしき文字列「${
        email?.[0]
      }」がある(値は G4 で決める)`,
    );
  }
});

Deno.test("フィードバックの質問は 3 問だけ", async () => {
  const body = quoteBlockUnder(await read(ACCEPTANCE), "Day 3 の 3 問");
  for (const n of [1, 2, 3]) {
    assert(body.includes(`${n}. `), `Day 3 の質問 ${n} が無い`);
  }
  assert(!body.includes("4. "), "Day 3 の質問が 4 問以上ある(3 問以内にする)");
});

Deno.test("記録欄に P01〜P10 と欠測の表記がある", async () => {
  const tracker = await read(TRACKER);
  for (let n = 1; n <= 10; n++) {
    const id = `P${String(n).padStart(2, "0")}`;
    assert(tracker.includes(`| ${id} |`), `記録欄に ${id} の行が無い`);
  }
  assert(tracker.includes("| P00 |"), "記入例(P00)が無い");
  assert(tracker.includes("—"), "欠測の表記(—)が無い");
  assert(
    tracker.includes("P00 は**書式の見本**"),
    "P00 を集計に入れない注意書きが無い",
  );
});

Deno.test("README・手順書の相対リンクが実在する", async () => {
  for (const url of FILES) {
    const text = await read(url);
    for (const match of text.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)) {
      const target = match[1];
      if (target.startsWith("http") || target.startsWith("#")) continue;
      const resolved = new URL(target, url);
      const stat = await Deno.stat(resolved);
      assert(stat.isFile || stat.isDirectory, `リンク先がない: ${target}`);
    }
  }
});
