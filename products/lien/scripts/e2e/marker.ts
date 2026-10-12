// marker.ts — 通しテストが作ったユーザーの目印(サインアップ・手順と、後片付け・一覧の安全装置が共有する)
//
// 実ユーザーも同じ匿名ユーザーなので、「E2E-A/B/C というニックネーム」だけでは通しテストのものと断定できない
// (ニックネームは利用者が自由に付けられる)。後片付け(cleanup)と一覧(list)は、次の目印を重ねて確かめる:
//   1. サインアップの data に入れた lien_e2e = true(→ auth.users.raw_user_meta_data。アプリは付けない)
//   2. ニックネーム E2E-A / E2E-B / E2E-C(手順 S03)
//   3. 絵文字 🧪(手順 S03。--user 指定のときだけ要求する)
//   4. 約束のタイトルが「E2E 」で始まる(手順 S05。これに合わない約束を持つユーザーは対象外)
// 値を変えるときは、サインアップ・手順(steps_setup.ts / scenario_lib.ts)と、この定数を使う cleanup.ts を一緒に直す。
// 整合は cleanup_test.ts / scenario_lib_test.ts が見る。

/** サインアップの data に入れる印のキー(auth.users.raw_user_meta_data のキー) */
export const E2E_META_KEY = "lien_e2e";

/** 印の値。SQL では raw_user_meta_data ->> 'lien_e2e' = 'true' で比べる */
export const E2E_META_VALUE = true;

/** 手順 S03 で付けるアバター絵文字 */
export const E2E_EMOJI = "🧪";

/** 手順 S05 の約束のタイトルの接頭辞(半角スペースまで含む) */
export const E2E_PROMISE_PREFIX = "E2E ";

/** ニックネーム(手順 S01 の E2E-<ラベル>) */
export const E2E_NICKNAME_RE = /^E2E-[ABC]$/;
