-- ============================================================================
-- Lien migration 0005_push_env
--
-- 正本:
--   - APNs の環境の選び方: docs/DESIGN.md §4
--   - 背景: docs/REVIEW-2026-10-12.md §4.1(T08残)・§2 M5 / 承認: D4(2026-10-12 ユーザー「全部推奨で」)/ issue #53
--
-- 問題:
--   APNs の環境(sandbox / production)をサーバー全体の環境変数 APNS_ENV の単一値で切り替える運用だと、
--   開発ビルド(Xcode 直インストール = sandbox)と TestFlight(= production)のトークンが混在した瞬間に
--   片方へ通知が届かない(環境が違うトークンは BadDeviceToken になる)。
--
-- 変更:
--   - users.push_env を追加: そのデバイストークンが属する APNs 環境(sandbox | production)。
--     null = 未設定(従来の行・クライアントが未対応)。送信時は null のとき APNS_ENV にフォールバックする
--   - 本人が push_token / push_env を更新できる列 GRANT。push_token は 0001 で付与済みだが、
--     「2つはセットで更新する」ことが分かるよう両方を明示する(再付与は冪等)。
--     行の絞り込みは 0001 の users_update_self(id = auth.uid())のまま
--
-- 方針: 追加系のみ(列の追加+GRANT)。既存の行・列・ポリシーは変えない。
--   push_env の値の決定と保存は iOS 側(push_token の登録と同時に PATCH。issue #55 W1)。
--   サーバー側の使い方(トークンごとのエンドポイント選択・無効トークンの掃除)は
--   functions/_shared/apns.ts / pusher.ts。
-- ============================================================================

alter table public.users
  add column if not exists push_env text
  check (push_env in ('sandbox', 'production'));

comment on column public.users.push_env is
  'push_token が属する APNs 環境(sandbox | production)。null = 未設定(送信時は APNS_ENV にフォールバック)。クライアントが push_token と同時に更新する';

-- 列レベル GRANT(0001 §4 と同じ書き方)。authenticated が更新できるのは自分の行のプロフィール系の列のみ。
-- premium_until(RevenueCat Webhook が更新)・apple_sub・created_at は引き続きクライアントから変更不可
grant update (push_token, push_env) on table public.users to authenticated;
