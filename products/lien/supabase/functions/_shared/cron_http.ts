// _shared/cron_http.ts — cron 専用 Function(close-day / grant-tickets)の HTTP 層
//
// 正本: docs/DESIGN.md §5.3(close-day / grant-tickets)/ §7(シークレット)/ issue #60
//
// 認証・リクエスト本文の解釈・エラー応答を1か所に集める。index.ts は
//   「秘密の取り出し → Supabase リポジトリ実装 → handleCronRequest に渡す」
// だけの薄い I/O 層のままにする(リモート import の supabase-js は index.ts に隔離)。
//
// 方針(手で叩くことがある運用用エンドポイントなので、黙って通さない):
//   - 認証は `Authorization: Bearer <秘密>` の完全一致だけ(定数時間比較)。秘密が未設定・短すぎる
//     ときは全拒否する(空文字どうしの一致や、弱い秘密で通ってしまう事故を防ぐ)
//   - 認証より先に本文を読まない(認証前の呼び出し元に、本文の検証結果を見せない)
//   - 本文は「空」か「JSON オブジェクト」だけ。壊れた JSON を空として扱わない
//     (`{"dateLocal":"2026-10-11","notify":false` のように途切れた本文が、既定値=通知あり・
//      昨日の確定として動くと、止めたかったリセット通知が飛ぶ)
//   - 知らないキーは 400(`notifiy` のような打ち間違いで、既定値のまま動かさない)

/** 秘密の最小長。32 文字(= 16 バイトの 16 進)未満は設定ミスとして全拒否する */
export const MIN_CRON_SECRET_LENGTH = 32;

export type ParseResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

/** 秘密が使える状態か(未設定・短すぎるときは false。isAuthorizedCronRequest が全拒否にする条件) */
export function isCronSecretUsable(
  secret: string | undefined,
): secret is string {
  return !!secret && secret.length >= MIN_CRON_SECRET_LENGTH;
}

/**
 * 起動時に1回呼ぶ。秘密が使えない状態なら、全拒否になることをログで知らせる
 * (Function secrets に LIEN_CRON_SECRET を入れ忘れたときに、401 の理由が分かるように)
 */
export function warnIfCronSecretUnusable(
  label: string,
  secret: string | undefined,
): void {
  if (!isCronSecretUsable(secret)) {
    console.error(
      `${label}: LIEN_CRON_SECRET が未設定か短すぎます(${MIN_CRON_SECRET_LENGTH} 文字以上が必要)。` +
        "すべての呼び出しを 401 で拒否します(scripts/OPS.md の鍵の更新を参照)",
    );
  }
}

/**
 * `Authorization` ヘッダから Bearer トークンを取り出す。
 * `Bearer ` の接頭辞が無い・トークンが空の場合は空文字(= 認証失敗扱い)
 */
export function bearerToken(header: string | null): string {
  if (!header) return "";
  const m = /^Bearer\s+(\S+)\s*$/i.exec(header);
  return m ? m[1] : "";
}

/**
 * 定数時間の文字列比較(UTF-8 のバイト列で比較し、長さの差も含めて最後まで走査する)。
 * 秘密の長さは固定で漏れても困らないが、先頭一致の長さがタイミングに出ないようにする
 */
export function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  const length = Math.max(ea.length, eb.length);
  for (let i = 0; i < length; i++) {
    diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  }
  return diff === 0;
}

/**
 * cron 呼び出しの認証。secret が未設定・短すぎるときは常に false。
 * service role key など「別の鍵」は受け付けない(秘密と完全一致のときだけ true)
 */
export function isAuthorizedCronRequest(
  authorization: string | null,
  secret: string | undefined,
): boolean {
  if (!isCronSecretUsable(secret)) return false;
  const token = bearerToken(authorization);
  if (token === "") return false;
  return timingSafeEqual(token, secret);
}

/**
 * リクエスト本文を「空 → {}」「JSON オブジェクト → そのまま」として読む。
 * 壊れた JSON・配列・null・数値・文字列は `invalid_json`(空として扱わない)
 */
export async function readOptionalJsonObject(
  req: Request,
): Promise<ParseResult<Record<string, unknown>>> {
  let text: string;
  try {
    text = await req.text();
  } catch {
    return { ok: false, error: "invalid_json" };
  }
  if (text.trim() === "") return { ok: true, value: {} };
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, error: "invalid_json" };
  }
  if (
    typeof parsed !== "object" || parsed === null || Array.isArray(parsed)
  ) {
    return { ok: false, error: "invalid_json" };
  }
  return { ok: true, value: parsed as Record<string, unknown> };
}

/** 許可したキー以外が含まれていれば `unknown_field`(打ち間違いを既定値で通さない) */
export function rejectUnknownKeys(
  body: Record<string, unknown>,
  allowed: readonly string[],
): ParseResult<true> {
  for (const key of Object.keys(body)) {
    if (!allowed.includes(key)) return { ok: false, error: "unknown_field" };
  }
  return { ok: true, value: true };
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export interface CronHandlerOptions<T> {
  /** ログ用の関数名 */
  label: string;
  /** cron 専用の秘密(LIEN_CRON_SECRET)。未設定・短すぎるときは全リクエストを 401 にする */
  secret: string | undefined;
  /** 本文(JSON オブジェクト)→ 本体への入力。不正なら { ok: false, error } で 400 */
  parse: (body: Record<string, unknown>) => ParseResult<T>;
  /** 本体(core.ts の handle*)。{ status, body } をそのまま JSON 応答にする */
  run: (input: T) => Promise<{ status: number; body: unknown }>;
}

/**
 * cron 専用 Function の HTTP ハンドラ。
 *   405(POST 以外)→ 401(認証)→ 400(本文)→ 本体 → 500(予期しない例外)の順
 */
export async function handleCronRequest<T>(
  req: Request,
  opts: CronHandlerOptions<T>,
): Promise<Response> {
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  if (!isAuthorizedCronRequest(req.headers.get("Authorization"), opts.secret)) {
    return json(401, { error: "unauthorized" });
  }

  const body = await readOptionalJsonObject(req);
  if (!body.ok) return json(400, { error: body.error });

  const input = opts.parse(body.value);
  if (!input.ok) return json(400, { error: input.error });

  try {
    const result = await opts.run(input.value);
    return json(result.status, result.body);
  } catch (e) {
    console.error(`${opts.label}: 予期しないエラー:`, e);
    return json(500, { error: "internal_error" });
  }
}
