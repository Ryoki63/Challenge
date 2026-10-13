// _shared/auth_errors.ts — 認証サーバー(Supabase Auth)への問い合わせの失敗の分類(issue #23 のレビュー指摘)
//
// ユーザー向けの Edge Function は、Authorization の JWT を adminClient.auth.getUser(token) で確かめる。
// この呼び出しの失敗には 2 種類ある:
//
//   1. 認証サーバーが「この JWT は使えない」と答えた(期限切れ・署名の不正・ユーザーが居ない、など 4xx)
//        → 401 { error: "unauthorized" }   確定した拒否
//   2. 認証サーバーに聞けなかった・認証サーバーが不調(通信の失敗・5xx)
//        → 503 { error: "auth_unavailable" }   一時的。利用者のログインが無効とは言えない
//
// 以前は 2 も 401 にしていた。アプリは 401 が続くと「ログイン状態を確認できません」の確認を出し、利用者が
// 「はじめからやり直す」を選ぶと、匿名アカウントには二度と戻れない。認証サーバーの障害で、そこへ誘導しないために分ける。
// アプリ側(SessionHealthMonitor)は 503 を「セッションの良し悪しとは関係がない」失敗として数えない。
//
// supabase-js(auth-js)のエラー:
//   AuthRetryableFetchError … fetch が失敗した(status 0)、または 502 / 503 / 504
//   AuthUnknownError        … 応答が JSON で読めなかった(ゲートウェイの HTML のエラーページなど)
//   AuthApiError            … status = 認証サーバーの応答の HTTP ステータス(4xx = 確定した拒否 / 5xx = 不調)
//   AuthSessionMissingError … JWT が空など(status 400)
// 名前と status だけを見る(supabase-js を import しない — テストはネットワーク不要)。

/** auth-js の AuthError のうち、分類に使う部分 */
export interface AuthErrorLike {
  name?: string;
  status?: number;
}

/** 認証サーバーに聞けなかった/不調だったことを表すエラーの名前 */
const UNAVAILABLE_ERROR_NAMES = new Set([
  "AuthRetryableFetchError",
  "AuthUnknownError",
]);

/**
 * getUser の失敗が「認証サーバーの不調・通信の失敗」か(true なら 503、false なら確定した拒否として 401)。
 * 判断できないエラー(status が無い・名前が違う)は、確定した拒否として扱う(これまでの 401 のまま)
 */
export function isAuthServiceUnavailable(
  error: AuthErrorLike | null | undefined,
): boolean {
  if (!error) return false;
  if (error.name && UNAVAILABLE_ERROR_NAMES.has(error.name)) return true;
  if (typeof error.status === "number") {
    return error.status === 0 || error.status >= 500;
  }
  return false;
}
