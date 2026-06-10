// invite-create/core.ts — POST /invite-create の本体ロジック(I/O はリポジトリ注入)
//
// 正本: docs/DESIGN.md §5.1(token は8文字英数・紛らわしい 0/O/1/l を除外・有効期限72h・
//        1回限り)/ §5.3 / §6(招待フロー: lien:// と https ページURL の2形式)
//        / docs/REQUIREMENTS.md §3.2(招待の有効期限72時間 / 1リンク1回限り)
//
// 設計:
//   - token 生成は乱数源(randomBytes)を注入可能にし、テストで決定論化する。
//     既定は crypto.getRandomValues。剰余の偏りを避けるため棄却サンプリング
//   - 1回限り・期限・未使用の検査は invite-accept 側の責務(本関数は発行のみ)
//   - v1 は1ユーザー1ペア(REQUIREMENTS §1)なので、既にペアがいる発行者は 409

import type { SnapshotPairRow, SnapshotUserRow } from "../_shared/snapshot.ts";

/** 8文字英数。紛らわしい 0 / O / 1 / l を除外した58文字(DESIGN §5.1) */
export const INVITE_TOKEN_ALPHABET =
  "ABCDEFGHIJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

export const INVITE_TOKEN_LENGTH = 8;

/** 有効期限 72時間(REQUIREMENTS §3.2) */
export const INVITE_TTL_HOURS = 72;

/** token 衝突(PK 重複)時の再生成上限。58^8 空間で実質起きないが防御的に */
const MAX_TOKEN_ATTEMPTS = 5;

export type RandomBytes = (length: number) => Uint8Array;

const defaultRandomBytes: RandomBytes = (length) =>
  crypto.getRandomValues(new Uint8Array(length));

/**
 * 招待トークンを生成する。各バイトを棄却サンプリング
 * (alphabet 長 58 の倍数 232 以上は捨てる)して一様分布を保つ。
 */
export function generateInviteToken(
  randomBytes: RandomBytes = defaultRandomBytes,
): string {
  const n = INVITE_TOKEN_ALPHABET.length;
  const limit = 256 - (256 % n); // 232。これ以上のバイトは棄却
  let token = "";
  while (token.length < INVITE_TOKEN_LENGTH) {
    for (const b of randomBytes(INVITE_TOKEN_LENGTH)) {
      if (b >= limit) continue;
      token += INVITE_TOKEN_ALPHABET[b % n];
      if (token.length === INVITE_TOKEN_LENGTH) break;
    }
  }
  return token;
}

export interface InviteCreateRepo {
  getUser(userId: string): Promise<SnapshotUserRow | null>;
  /** 自分が属する active なペア(発行者が既ペアなら発行拒否に使う) */
  getActivePair(userId: string): Promise<SnapshotPairRow | null>;
  /**
   * invites へ insert。token の PK 衝突時は throw せず { inserted: false } を返す
   * (呼び出し側が再生成してリトライする)。
   */
  insertInvite(params: {
    token: string;
    fromUser: string;
    expiresAtIso: string;
  }): Promise<{ inserted: boolean }>;
}

export interface InviteCreateDeps {
  repo: InviteCreateRepo;
  /**
   * 招待静的ページのベースURL(DESIGN §6: https://<GH_PAGES>)。
   * webUrl = `${webBaseUrl}/lien/i/?t=<token>` を組み立てる
   */
  webBaseUrl: string;
  now?: () => Date;
  randomBytes?: RandomBytes;
}

export type InviteCreateResult =
  | {
    status: 200;
    body: {
      token: string;
      /** カスタムスキーム形式: lien://invite/<token>(DESIGN §3.6 / §6) */
      appUrl: string;
      /** 静的ページ形式: https://<GH_PAGES>/lien/i/?t=<token>(DESIGN §6) */
      webUrl: string;
      /** ISO8601。発行時刻 + 72h */
      expiresAt: string;
    };
  }
  | { status: 404 | 409 | 500; body: { error: string } };

export async function handleInviteCreate(
  deps: InviteCreateDeps,
  req: { userId: string },
): Promise<InviteCreateResult> {
  const now = deps.now ?? (() => new Date());
  const randomBytes = deps.randomBytes ?? defaultRandomBytes;

  const user = await deps.repo.getUser(req.userId);
  if (!user) {
    return { status: 404, body: { error: "user_not_found" } };
  }

  // v1 は1ユーザー1ペア(REQUIREMENTS §1)。既ペアの発行は 409
  const pair = await deps.repo.getActivePair(req.userId);
  if (pair) {
    return { status: 409, body: { error: "already_paired" } };
  }

  const issuedAt = now();
  const expiresAtIso = new Date(
    issuedAt.getTime() + INVITE_TTL_HOURS * 60 * 60 * 1000,
  ).toISOString();

  // PK 衝突時のみ再生成(DESIGN §5.5 の精神: リトライは有限回で止まる)
  for (let attempt = 1; attempt <= MAX_TOKEN_ATTEMPTS; attempt++) {
    const token = generateInviteToken(randomBytes);
    const { inserted } = await deps.repo.insertInvite({
      token,
      fromUser: req.userId,
      expiresAtIso,
    });
    if (inserted) {
      const base = deps.webBaseUrl.replace(/\/+$/, "");
      return {
        status: 200,
        body: {
          token,
          appUrl: `lien://invite/${token}`,
          webUrl: `${base}/lien/i/?t=${token}`,
          expiresAt: expiresAtIso,
        },
      };
    }
  }
  return { status: 500, body: { error: "token_generation_failed" } };
}
