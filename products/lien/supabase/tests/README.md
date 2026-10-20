# 合成データによる RLS 回帰テスト

```sh
deno test --config products/lien/supabase/tests/deno.json --frozen --allow-read --allow-env=NODE_ENV products/lien/supabase/tests/
```

PGlite のインメモリ PostgreSQL で `0001_init.sql`
を実行し、旧ポリシーの漏えいを再現したあと、`0009_reactions_select_visible_checkin.sql`
の適用後に同じデータで遮断を確認する。既存 DB への追加 migration
として検証し、初期 migration の過去履歴は変更しない。

- UUID・プロフィール・約束・チェックイン・リアクションはすべてテスト内の合成値。
- Supabase へは接続せず、実 JWT・環境ファイル・認証情報は使わない。
- `auth.uid()` は transaction-local な `request.jwt.claim.sub` から UUID
  を読む。毎回 `authenticated`（BYPASSRLS なし）で SELECT
  し、所有者・スーパーユーザーによる誤った PASS を防ぐ。
- auth / Storage の Supabase 管理オブジェクトだけを最小限 stub
  化し、アプリのテーブル・helper・GRANT・RLS は実 migration を実行する。他の
  migration（cron / Storage / push 設定など）は今回の検証対象外。
- 対照:
  現役ペア内で受け取ったリアクション、本人の送信履歴、本人チェックインへの受信、無関係なペア、成立日前の履歴、ペア解消後の遮断。
- 初回だけ固定バージョンの npm
  パッケージを取得する。テスト実行時のネットワーク権限は不要。CI の `lien-ci`
  で同じコマンドを毎 push 実行する。

このテストは DB の認可境界の検証であり、本番への migration 適用や iOS
の実機確認を意味しない。
