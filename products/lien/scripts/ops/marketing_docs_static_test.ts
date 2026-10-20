// marketing_docs_static_test.ts — 審査用の文書と実装のずれを止める静的テスト(issue #30 / T30)
//
// #58 のレビューで見つかった2種類のずれを、CI で再発しないように固定する:
//   1. D6(計測は SDK なし・SQL)なのに、プライバシーポリシーが「利用状況を自動取得」と書いていた
//   2. D3(Sign in with Apple は v1.0.1)なのに、v1.0 の取得情報に SIWA の識別子があった
// あわせて、App Privacy の草案(review-notes §2.1)が PrivacyInfo.xcprivacy の収集データ型と一致すること、
// 審査用デモの運用(§1.3)が実在するスクリプトを指すことも検査する。
//
// 実行(ファイルを読むので --allow-read が要る。lien-ci の ops-tests ジョブで回る):
//   deno test --allow-read products/lien/scripts/ops/

const LIEN = new URL("../../", import.meta.url); // products/lien/
const MARKETING = new URL("marketing/", LIEN);
const IOS = new URL("ios/", LIEN);

const POLICY_MD = new URL("privacy-policy.md", MARKETING);
const POLICY_HTML = new URL("legal/privacy.html", MARKETING);
const REVIEW_NOTES = new URL("review-notes.md", MARKETING);
const CHECKLIST_G4 = new URL("legal/CHECKLIST-G4.md", MARKETING);
const MANIFEST_APP = new URL("Lien/PrivacyInfo.xcprivacy", IOS);
const MANIFEST_NSE = new URL("LienNSE/PrivacyInfo.xcprivacy", IOS);
const MANIFEST_WIDGET = new URL("LienWidget/PrivacyInfo.xcprivacy", IOS);

async function read(url: URL): Promise<string> {
  return await Deno.readTextFile(url);
}

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`assert failed: ${msg}`);
}

/** 見出しで囲まれた節を切り出す(見出し行は含む) */
function section(
  text: string,
  startHeading: string,
  endHeading: string,
): string {
  const start = text.indexOf(startHeading);
  if (start < 0) throw new Error(`見出しがありません: ${startHeading}`);
  const end = text.indexOf(endHeading, start + startHeading.length);
  if (end < 0) throw new Error(`終わりの見出しがありません: ${endHeading}`);
  return text.slice(start, end);
}

/** Markdown の表の行(先頭が | の行)だけを返す */
function markdownTableRows(text: string): string[] {
  return text.split("\n").filter((line) => line.trimStart().startsWith("|"));
}

/** HTML の tr 行だけを返す */
function htmlTableRows(text: string): string[] {
  return text.split("\n").filter((line) => line.includes("<tr>"));
}

/** xcprivacy の NSPrivacyCollectedDataType の値を取り出す */
function collectedDataTypes(plist: string): string[] {
  const values: string[] = [];
  const pattern =
    /<key>NSPrivacyCollectedDataType<\/key>\s*<string>([^<]+)<\/string>/g;
  for (const match of plist.matchAll(pattern)) values.push(match[1]);
  return values;
}

Deno.test("プライバシーポリシー(md): v1.0 で SIWA の識別子・利用状況を取得しない", async () => {
  const text = await read(POLICY_MD);
  const rows = markdownTableRows(text);
  assert(
    !rows.some((row) => row.includes("Sign in with Apple")),
    "v1.0 の取得情報の表に Sign in with Apple の行がある(D3 で v1.0.1 に移動)",
  );
  assert(
    !rows.some((row) => row.includes("利用状況")),
    "v1.0 の取得情報の表に「利用状況」の行がある(D6 で計測しない)",
  );
  assert(
    text.includes("分析 SDK") && text.includes("送信しません"),
    "計測のために何も送らない旨の記載が無い(D6)",
  );
  assert(
    text.includes("v1.0 では Sign in with Apple 連携を提供していません"),
    "v1.0 で SIWA を提供しない旨の記載が無い(D3)",
  );
});

Deno.test("プライバシーポリシー(html): md と同じ(表の行に SIWA・利用状況が無い)", async () => {
  const text = await read(POLICY_HTML);
  const rows = htmlTableRows(text);
  assert(
    !rows.some((row) => row.includes("Sign in with Apple")),
    "html の取得情報の表に Sign in with Apple の行がある",
  );
  assert(
    !rows.some((row) => row.includes("利用状況")),
    "html の取得情報の表に「利用状況」の行がある",
  );
  assert(
    text.includes("分析 SDK") && text.includes("送信しません"),
    "html に計測のために何も送らない旨の記載が無い",
  );
  assert(
    text.includes("v1.0 では Sign in with Apple 連携を提供していません"),
    "html に v1.0 で SIWA を提供しない旨の記載が無い",
  );
});

Deno.test("review-notes §2.1: マニフェストの収集データ型をすべて説明している", async () => {
  const notes = await read(REVIEW_NOTES);
  const part = section(notes, "### 2.1 ", "### 2.2 ");
  const types = collectedDataTypes(await read(MANIFEST_APP));
  assert(
    types.length === 5,
    `本体の収集データ型が5つではない: ${types.join(", ")}`,
  );
  for (const type of types) {
    assert(
      part.includes(type),
      `review-notes §2.1 に ${type} が無い(App Privacy の草案とマニフェストのずれ)`,
    );
  }
});

Deno.test("review-notes §2.1: v1.0 で収集しないものを表に入れていない", async () => {
  const notes = await read(REVIEW_NOTES);
  const part = section(notes, "### 2.1 ", "### 2.2 ");
  const rows = markdownTableRows(part);
  assert(
    !rows.some((row) =>
      row.includes("apple_sub") || row.includes("Sign in with Apple")
    ),
    "§2.1 の表に SIWA の識別子がある(D3 で v1.0.1)",
  );
  assert(
    !rows.some((row) =>
      row.includes("利用状況") || row.includes("TelemetryDeck")
    ),
    "§2.1 の表に利用状況の計測がある(D6 で計測しない)",
  );
});

Deno.test("review-notes §1.3: 審査用デモの運用が実在するスクリプトを指す", async () => {
  const notes = await read(REVIEW_NOTES);
  const part = section(notes, "### 1.3 ", "### 1.4 ");
  assert(
    part.includes("scripts/review-demo/partner.sh") &&
      part.includes("partner.ts"),
    "§1.3 が相手役のスクリプト(partner.sh / partner.ts)を指していない",
  );
  assert(
    part.includes("Notes for Review"),
    "§1.3 に招待コードの記入先(Notes for Review)が無い",
  );
  assert(
    !part.includes("TBD: 実行後に実値"),
    "§1.3 に実値待ちの TBD が残っている(匿名認証にアカウント情報は無い)",
  );
});

Deno.test("G4 チェックリスト: 計測手段を未決定として残していない(D6)", async () => {
  const text = await read(CHECKLIST_G4);
  assert(
    !text.includes("自前テーブル or TelemetryDeck"),
    "CHECKLIST-G4 に計測手段の未決定項目が残っている(D6 で SQL に決定)",
  );
  assert(
    text.includes("分析 SDK") && text.includes("Sign in with Apple"),
    "CHECKLIST-G4 に D6・D3 の確認項目が無い",
  );
});

Deno.test("プライバシーマニフェスト: NSE と widget は収集データ・必須理由 API が空", async () => {
  for (
    const [label, url] of [["NSE", MANIFEST_NSE], [
      "widget",
      MANIFEST_WIDGET,
    ]] as const
  ) {
    const plist = await read(url);
    assert(
      collectedDataTypes(plist).length === 0,
      `${label} のマニフェストに収集データがある(ペイロードを App Group に書く/読むだけ)`,
    );
    const apiSection = plist.slice(
      plist.indexOf("<key>NSPrivacyAccessedAPITypes</key>"),
    );
    assert(
      apiSection.includes("<array>\n\t</array>") ||
        apiSection.includes("<array/>"),
      `${label} のマニフェストに必須理由 API の宣言がある`,
    );
  }
});

Deno.test("プライバシーマニフェスト: 3つともトラッキングなし・追跡ドメインなし", async () => {
  for (
    const [label, url] of [
      ["app", MANIFEST_APP],
      ["NSE", MANIFEST_NSE],
      ["widget", MANIFEST_WIDGET],
    ] as const
  ) {
    const plist = await read(url);
    assert(
      /<key>NSPrivacyTracking<\/key>\s*<false\/>/.test(plist),
      `${label}: NSPrivacyTracking が false ではない`,
    );
    assert(
      /<key>NSPrivacyTrackingDomains<\/key>\s*<array\s*\/>/.test(plist),
      `${label}: NSPrivacyTrackingDomains が空ではない`,
    );
  }
});
