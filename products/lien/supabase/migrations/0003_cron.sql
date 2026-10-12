-- ============================================================================
-- Lien migration 0003_cron
--
-- 正本:
--   - cron の設計: docs/GROWTH.md §7.1(close-day の定期実行)/ docs/DESIGN.md §5.3・§5.4
--   - 承認: D4(docs/REVIEW-2026-10-12.md §1。2026-10-12 ユーザー「全部推奨で」)/ issue #51
--
-- 目的:
--   close-day(毎日の確定)と grant-tickets(毎月のチケット付与)を本番で定期実行する。
--   これまで cron はどこにも登録されておらず、ストリーク確定・植物の成長・チケットの
--   消費と付与が一切進んでいなかった(2026-10-12 の読み取りで拡張・ジョブとも未導入を確認)。
--
-- 構成(Supabase の推奨どおり):
--   - pg_cron(スケジューラ。UTC で動く)を pg_catalog に、pg_net(非同期 HTTP)を
--     extensions に入れる。pg_net の関数は net スキーマに作られる
--   - 各ジョブは net.http_post で Edge Function を呼ぶ。Function 側は
--     「Authorization: Bearer <service role key> の完全一致」で cron 呼び出しを認証する
--     (close-day/index.ts・grant-tickets/index.ts)
--   - **鍵はこのファイルに書かない**。Vault の `lien_service_role_key` を実行時に参照する
--
-- 前提(この migration の外で1回だけ行う。値はリポジトリ・ログに出さない):
--   select vault.create_secret(
--     '<SERVICE_ROLE_KEY>', 'lien_service_role_key',
--     'close-day / grant-tickets を呼ぶ pg_cron 用の service role key');
--   ※ <SERVICE_ROLE_KEY> は「Edge Function が見る SUPABASE_SERVICE_ROLE_KEY」と同じ値にする。
--     このプロジェクトでは Dashboard の legacy service_role(eyJ...)ではなく、
--     default の secret key(sb_secret_...)が注入されている
--     (2026-10-12 実測: legacy キーで close-day を呼ぶと 401、secret key だと 200)。
--     取得: GET https://api.supabase.com/v1/projects/<ref>/api-keys?reveal=true の type=secret
--   ※ Vault に無い間もジョブは作れるが、実行時は Authorization が不正で 401 になる
--   ※ 鍵をローテーションしたら vault.update_secret で差し替える(手順: scripts/OPS.md)
--
-- スケジュール(pg_cron は UTC。JST = UTC+9 でサマータイムなし):
--   lien-grant-tickets  毎日 15:05 UTC で起動し、JST の日付が1日のときだけ呼ぶ(=毎月1日 00:05 JST)
--   lien-close-day      毎日 15:10 UTC(= 毎日 00:10 JST)
--   grant-tickets を毎日起動して JST の1日だけ通す理由: cron 式に「月末の翌日(JST)」を
--   書けないため。月の途中に動かしてはいけない(上限に達していたペアには冪等キーの
--   ledger 行が残らず、チケットを使った後に再付与されてしまう — GROWTH.md §7.1)
--
-- 冪等性: 拡張は if not exists。cron.schedule は同名ジョブがあれば更新するので、
--   この migration を再実行してもジョブは重複しない
--
-- 監視・取りこぼしの再実行: products/lien/scripts/OPS.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 拡張
-- ----------------------------------------------------------------------------
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- ----------------------------------------------------------------------------
-- 2. ジョブ
--    net.http_post(url, body, params, headers, timeout_milliseconds) — pg_net 0.20 の
--    実際の引数(本番で確認済み)。name 渡しなので引数の並びには依存しない。
--    Authorization は実行時に Vault から引く(ジョブの command 文字列に鍵は残らない)
-- ----------------------------------------------------------------------------

-- 毎月1日 00:05 JST: 月次チケット付与。JST の日付が1日でない日は何も呼ばない
select cron.schedule(
  'lien-grant-tickets',
  '5 15 * * *',
  $cron$
  select net.http_post(
    url := 'https://lniheehfbtpfhglinfjm.supabase.co/functions/v1/grant-tickets',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'lien_service_role_key'
      )
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  )
  where extract(day from (now() at time zone 'Asia/Tokyo')) = 1;
  $cron$
);

-- 毎日 00:10 JST: 前日(JST)の確定。再実行しても結果は同じ(冪等)
select cron.schedule(
  'lien-close-day',
  '10 15 * * *',
  $cron$
  select net.http_post(
    url := 'https://lniheehfbtpfhglinfjm.supabase.co/functions/v1/close-day',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'lien_service_role_key'
      )
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $cron$
);
