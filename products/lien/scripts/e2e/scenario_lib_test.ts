// scenario_lib_test.ts — scenario_lib.ts の純粋な部分の deno test。ネットワーク・本番は使わない
//
//   deno test --allow-read products/lien/scripts/e2e/
//
// 見るもの:
//   - 招待 token の形(INVITE_TOKEN_RE)が、サーバーの文字集合(invite-create/core.ts の INVITE_TOKEN_ALPHABET)と
//     仕様(DESIGN §5.1・REQUIREMENTS §3.2: 0 / O / 1 / l だけを除く)に一致すること。以前の正規表現は大文字の I も除いて
//     いて、本物の生成器が作る token の約 13% を弾き、本番に対する通しテストが約 8 回に 1 回、偽の FAIL になった
//   - 存在しない招待に使う token が、必ず存在しないこと
//   - 署名付き URL の改ざんが、署名バイトを実際に変えること(最後の文字の詰め物ビットだけを変えない)
//   - 署名の発行の失敗の契約(storage-sign.not-found.json)の判定
//   - 約束のタイトルが、後片付けの目印の接頭辞で始まること

import {
  generateInviteToken,
  INVITE_TOKEN_ALPHABET,
  INVITE_TOKEN_LENGTH,
  type RandomBytes,
} from "../../supabase/functions/invite-create/core.ts";
import { E2E_NICKNAME_RE, E2E_PROMISE_PREFIX } from "./marker.ts";
import {
  INVITE_TOKEN_RE,
  NEVER_ISSUED_INVITE_TOKEN,
  PROMISES,
  SIGN_FAILURE_STATUS,
  signFailureProblems,
  tamperSignedUrl,
} from "./scenario_lib.ts";
import { assertEquals } from "./test_util.ts";

// ---- 招待 token ----

/** 仕様: 8 文字の英数から、紛らわしい 0 / O / 1 / l **だけ**を除く(58 文字)。サーバーのコードとは別に書いた正本 */
const SPEC_EXCLUDED = new Set(["0", "O", "1", "l"]);
const SPEC_ALPHABET = [
  ..."ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
].filter((ch) => !SPEC_EXCLUDED.has(ch));

const sorted = (s: Iterable<string>): string => [...s].sort().join("");

Deno.test("サーバーの招待 token の文字集合は、仕様(英数から 0/O/1/l だけを除いた 58 文字)と同じ", () => {
  assertEquals(sorted(INVITE_TOKEN_ALPHABET), sorted(SPEC_ALPHABET));
  assertEquals(INVITE_TOKEN_ALPHABET.length, 58);
  assertEquals(INVITE_TOKEN_LENGTH, 8);
  // 大文字の I は除かれていない(以前の正規表現が見落としていた点)
  assertEquals(INVITE_TOKEN_ALPHABET.includes("I"), true);
});

Deno.test("INVITE_TOKEN_RE は、サーバーの文字集合の全文字を通し、0/O/1/l・記号・長さ違いは通さない", () => {
  // 58 文字のどれで作った token も通る(I を含む)
  for (const ch of INVITE_TOKEN_ALPHABET) {
    assertEquals(INVITE_TOKEN_RE.test(ch.repeat(8)), true, `文字 ${ch}`);
  }
  // どの位置にあっても通る(先頭・末尾・途中の I)
  for (const t of ["Iabcdefg", "abcdefgI", "abcIdefg", "IIIIIIII"]) {
    assertEquals(INVITE_TOKEN_RE.test(t), true, t);
  }
  // 除かれる 4 文字は、どの位置にあっても通らない
  for (const ch of SPEC_EXCLUDED) {
    for (const t of [`${ch}abcdefg`, `abcdefg${ch}`, `abc${ch}defg`]) {
      assertEquals(INVITE_TOKEN_RE.test(t), false, t);
    }
  }
  // ASCII 全体で見て、通る文字 = サーバーの文字集合(過不足なし)
  for (let code = 0; code < 128; code++) {
    const ch = String.fromCharCode(code);
    assertEquals(
      INVITE_TOKEN_RE.test(ch.repeat(8)),
      INVITE_TOKEN_ALPHABET.includes(ch),
      `U+${code.toString(16).padStart(4, "0")} ${JSON.stringify(ch)}`,
    );
  }
  // 長さは 8 だけ
  assertEquals(INVITE_TOKEN_RE.test("abcdefg"), false);
  assertEquals(INVITE_TOKEN_RE.test("abcdefghi"), false);
  assertEquals(INVITE_TOKEN_RE.test(""), false);
});

/** 0, 1, 2, … 255, 0, 1, … と返す乱数(棄却される 232 以上のバイトも混ざる)。58 文字がすべて何度も現れる */
function sequentialBytes(): RandomBytes {
  let n = 0;
  return (length) => Uint8Array.from({ length }, () => n++ % 256);
}

Deno.test("本物の generateInviteToken が作る token は、どれも INVITE_TOKEN_RE を通る(58 文字がすべて現れる並びで)", () => {
  const random = sequentialBytes();
  const seen = new Set<string>();
  for (let i = 0; i < 200; i++) {
    const token = generateInviteToken(random);
    assertEquals(INVITE_TOKEN_RE.test(token), true, token);
    for (const ch of token) seen.add(ch);
  }
  assertEquals(sorted(seen), sorted(INVITE_TOKEN_ALPHABET));
});

Deno.test("既定の乱数で 3000 回作っても、すべて通る(以前の正規表現では約 13% が落ちた)", () => {
  const failures: string[] = [];
  for (let i = 0; i < 3000; i++) {
    const token = generateInviteToken();
    if (!INVITE_TOKEN_RE.test(token)) failures.push(token);
  }
  assertEquals(failures, []);
});

Deno.test("以前の正規表現は、本物の生成器の token を弾いていた(このテストが検出できる不具合の再現)", () => {
  const old = /^[A-HJ-NP-Za-km-z2-9]{8}$/; // I も除いていた版
  const random = sequentialBytes();
  let rejected = 0;
  for (let i = 0; i < 200; i++) {
    if (!old.test(generateInviteToken(random))) rejected++;
  }
  assertEquals(rejected > 0, true);
});

Deno.test("NEVER_ISSUED_INVITE_TOKEN: サーバーの形式検査は通り、生成器の文字集合には無い文字を含む(必ず存在しない)", async () => {
  // invite-accept の TOKEN_FORMAT(= invites.token の CHECK と同じ)。同じ式をここにも持つが、サーバー側が変わったら気づくよう中身も見る
  const serverFormat = /^[A-Za-z0-9]{8}$/;
  const src = await Deno.readTextFile(
    new URL("../../supabase/functions/invite-accept/core.ts", import.meta.url),
  );
  assertEquals(
    src.includes("const TOKEN_FORMAT = /^[A-Za-z0-9]{8}$/;"),
    true,
    "invite-accept の TOKEN_FORMAT が変わった。NEVER_ISSUED_INVITE_TOKEN が形式検査を通るか見直す",
  );
  assertEquals(serverFormat.test(NEVER_ISSUED_INVITE_TOKEN), true);
  assertEquals(
    [...NEVER_ISSUED_INVITE_TOKEN].some((ch) =>
      !INVITE_TOKEN_ALPHABET.includes(ch)
    ),
    true,
  );
  assertEquals(INVITE_TOKEN_RE.test(NEVER_ISSUED_INVITE_TOKEN), false);
});

// ---- 署名付き URL の改ざん ----

function bytesToB64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** 寛容な base64url 復号(詰め物ビットを無視する。jose / Buffer.from と同じ振る舞い) */
function lenientB64urlToBytes(s: string): number[] {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  return [...Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))];
}

/** 32 バイトの署名(HS256)。最後のバイトで、末尾の文字を決められる(0x10 → 'A') */
function signature(lastByte: number): string {
  const bytes = Uint8Array.from({ length: 32 }, (_, i) => (i * 37 + 11) % 256);
  bytes[31] = lastByte;
  return bytesToB64url(bytes);
}

function signedUrl(sig: string, tail = ""): string {
  const header = bytesToB64url(new TextEncoder().encode('{"alg":"HS256"}'));
  const payload = bytesToB64url(
    new TextEncoder().encode('{"url":"photos/x/photo.jpg","iat":1}'),
  );
  return `/object/sign/photos/pairs/p/2026-10-13/u/photo.jpg?token=${header}.${payload}.${sig}${tail}`;
}

const tokenOf = (url: string): string =>
  /[?&]token=([^&]+)/.exec(url)?.[1] ?? "";
const sigOf = (url: string): string => tokenOf(url).split(".")[2];

Deno.test("tamperSignedUrl: 署名の途中の 1 文字だけが変わり、署名のバイト列が実際に変わる(末尾の文字が何でも)", () => {
  // 末尾の文字が 16 通り(canonical な base64url の末尾は下位 2 ビットが 0 の文字だけ)のどれでも
  for (let nibble = 0; nibble < 16; nibble++) {
    const url = signedUrl(signature(nibble));
    const tampered = tamperSignedUrl(url);
    if (tampered === null) throw new Error("改ざんできなかった");
    assertEquals(tampered.length, url.length);
    const diffs = [...url].flatMap((ch, i) => ch === tampered[i] ? [] : [i]);
    assertEquals(diffs.length, 1, `末尾 ${url.at(-1)}`);
    // 変えた位置は、URL の末尾から 10 文字目(最後の文字・詰め物のビットを含む末尾の数文字ではない)
    assertEquals(diffs[0], url.length - 10, `末尾 ${url.at(-1)}`);
    // 寛容な復号でも、署名のバイト列が変わる
    assertEquals(
      JSON.stringify(lenientB64urlToBytes(sigOf(url))) !==
        JSON.stringify(lenientB64urlToBytes(sigOf(tampered))),
      true,
      `末尾 ${url.at(-1)}`,
    );
  }
});

Deno.test("以前の改ざん(URL の最後の文字だけ)は、末尾が 'A' のとき署名のバイト列を変えない(偽の FAIL の再現)", () => {
  const url = signedUrl(signature(0x10));
  assertEquals(url.endsWith("A"), true);
  const old = url.slice(0, -1) + (url.endsWith("A") ? "B" : "A");
  assertEquals(
    JSON.stringify(lenientB64urlToBytes(sigOf(url))),
    JSON.stringify(lenientB64urlToBytes(sigOf(old))),
  );
  // 新しい改ざんは、この URL でもバイト列を変える
  const tampered = tamperSignedUrl(url) as string;
  assertEquals(
    JSON.stringify(lenientB64urlToBytes(sigOf(url))) !==
      JSON.stringify(lenientB64urlToBytes(sigOf(tampered))),
    true,
  );
});

Deno.test("tamperSignedUrl: token の後ろに別のパラメータがあっても、token の中だけを変える", () => {
  const url = signedUrl(signature(3), "&download=1");
  const tampered = tamperSignedUrl(url) as string;
  assertEquals(tampered.endsWith("&download=1"), true);
  assertEquals(tampered.length, url.length);
  assertEquals(
    tokenOf(tampered).split(".").slice(0, 2),
    tokenOf(url).split(".").slice(0, 2),
  );
  assertEquals(sigOf(tampered) !== sigOf(url), true);
});

Deno.test("tamperSignedUrl: token が無い・JWT の形でない・署名が短いときは null", () => {
  assertEquals(tamperSignedUrl("/object/sign/photos/p/photo.jpg"), null);
  assertEquals(tamperSignedUrl("/object/sign/photos/p?token=abc"), null);
  assertEquals(
    tamperSignedUrl("/object/sign/photos/p?token=a.b.shortsig"),
    null,
  );
});

// ---- 署名の発行の失敗の契約 ----

const NOT_FOUND_FIXTURE = {
  statusCode: "404",
  error: "not_found",
  message: "Object not found",
};

Deno.test("signFailureProblems: HTTP 400 と本文の statusCode / error が契約どおりなら食い違いなし(余計なキーは許す)", () => {
  assertEquals(SIGN_FAILURE_STATUS, 400);
  assertEquals(
    signFailureProblems(400, NOT_FOUND_FIXTURE, NOT_FOUND_FIXTURE),
    [],
  );
  assertEquals(
    signFailureProblems(
      400,
      { ...NOT_FOUND_FIXTURE, extra: "x", message: "Object not found!" },
      NOT_FOUND_FIXTURE,
    ),
    [],
  );
});

Deno.test("signFailureProblems: 404 に変わった・statusCode / error が違う・message が無いは食い違いとして返す", () => {
  assertEquals(
    signFailureProblems(404, NOT_FOUND_FIXTURE, NOT_FOUND_FIXTURE).length,
    1,
  );
  assertEquals(
    signFailureProblems(
      400,
      { ...NOT_FOUND_FIXTURE, statusCode: "403" },
      NOT_FOUND_FIXTURE,
    ).length,
    1,
  );
  assertEquals(
    signFailureProblems(
      400,
      { ...NOT_FOUND_FIXTURE, error: "forbidden" },
      NOT_FOUND_FIXTURE,
    ).length,
    1,
  );
  assertEquals(
    signFailureProblems(
      400,
      { statusCode: "404", error: "not_found" },
      NOT_FOUND_FIXTURE,
    )
      .length,
    1,
  );
  // 本文が JSON でない
  assertEquals(
    signFailureProblems(400, undefined, NOT_FOUND_FIXTURE).length,
    3,
  );
});

// ---- 目印の整合 ----

Deno.test("約束のタイトルは「E2E 」で始まり(更新後も)、20 字以内。ニックネームは目印の形に合う", () => {
  for (const label of ["A", "B", "C"] as const) {
    const title = PROMISES[label].title;
    assertEquals(title.startsWith(E2E_PROMISE_PREFIX), true, title);
    assertEquals(title.length <= 20, true, title);
    assertEquals(E2E_NICKNAME_RE.test(`E2E-${label}`), true, label);
  }
  // 手順 S05 の編集後のタイトル
  const edited = `${PROMISES.A.title}(更新)`;
  assertEquals(edited.startsWith(E2E_PROMISE_PREFIX), true);
  assertEquals(edited.length <= 20, true);
});
