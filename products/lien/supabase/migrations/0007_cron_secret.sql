-- ============================================================================
-- Lien migration 0007_cron_secret
--
-- 正本:
--   - cron の設計: docs/GROWTH.md §7.1 / docs/DESIGN.md §5.3・§7
--   - 承認: D4(docs/REVIEW-2026-10-12.md §1。cron の登録・追加系の migration)/ issue #60
--
-- 問題:
--   0003 の cron は、Vault の lien_service_role_key(= Edge Function が見る SUPABASE_SERVICE_ROLE_KEY。
--   DB に何でもできる万能鍵)を Bearer にして close-day / grant-tickets を呼んでいた。万能鍵が
--   Vault と、pg_net のリクエストキュー(net.http_request_queue。ヘッダが入る)を通る。
--
-- 変更: 認証を cron 専用のシークレットに差し替える(ジョブの名前・スケジュール・URL は 0003 のまま)
--   - Vault の lien_cron_secret を Bearer にする。Function 側は Function secrets の LIEN_CRON_SECRET との
--     完全一致で認証する(同じ値を2か所に置く)。close-day / grant-tickets を呼べるだけの鍵で、DB の読み書きには
--     使えない。漏れたときの影響は、過去の日の close-day を通知つきで呼ばれる(リセット通知の再送)ことと、
--     過去の月の付与を先に走らされることまで(未来の日・月は Function が断る)。作り直せば止まる(OPS.md §6)
--   - Function は service role key をもう受け付けない(_shared/cron_http.ts)ので、
--     Vault の lien_service_role_key は不要になる(データの削除は migration にしない。scripts/OPS.md §6)
--
-- 前提(この migration の外で、先に1回だけ行う。値は画面にもリポジトリにも出さない):
--   1. Vault に lien_cron_secret を作る。乱数を DB の中で作るので、SQL にもログにも値が残らない:
--        select vault.create_secret(
--          encode(extensions.gen_random_bytes(32), 'hex'), 'lien_cron_secret',
--          'close-day / grant-tickets を呼ぶ pg_cron 用の専用シークレット(Function secrets の LIEN_CRON_SECRET と同じ値)');
--   2. 同じ値を Function secrets の LIEN_CRON_SECRET に入れる(手順: scripts/OPS.md §6)
--   3. close-day / grant-tickets を再デプロイする(LIEN_CRON_SECRET で認証する版)
--   ※ 順序を守らないと、ジョブが 401 になる(翌朝の監視 workflow が赤になる)。
--     下のガードで、Vault に無いときはこの migration を止める
--
-- 【注意】本番プロジェクト(lniheehfbtpfhglinfjm)の URL を直書きしている:
--   このファイルを別のプロジェクト(staging など)へ適用すると、そのプロジェクトの pg_cron が
--   本番の Function を呼ぶ。シークレットが違うので認証は通らない(401)が、意図した動作ではない。
--   別プロジェクトに適用するときは、先に下の2つの URL を差し替えること。
--   URL がプロジェクト(supabase/config.toml の project_id)と一致することは
--   scripts/ops/cron_static_test.ts が検査する
--
-- net スキーマの権限について(issue #60 の項目5。実測は 2026-10-13):
--   pg_net の関数(net.http_post など)と表(net.http_request_queue・net._http_response)は
--   supabase_admin 所有で、PUBLIC に EXECUTE / SELECT が付いている。postgres(migration を流すロール)は
--   所有者でも supabase_admin のメンバーでもないので、`revoke ... from public, anon, authenticated` は
--   エラーにならず何も変えない(DO ブロック内で実行して確認した)。そのため、この migration には revoke を書かない
--   (効かない文を置くと、塞いだように見えてしまう)。代わりに次で守る:
--   - 公開 API から net に届かないこと: PostgREST の公開スキーマは public, graphql_public だけ、
--     pg_graphql は無効(実測)。監視 workflow(scripts/ops/cron_check.ts)が毎朝この前提を検査する
--   - 万能鍵を net のキューに載せない(この migration の本題)。載るのは cron 専用の秘密だけ
--
-- 冪等性: cron.schedule は同名ジョブがあれば更新するので、再実行してもジョブは重複しない
--
-- 監視・取りこぼしの再実行: products/lien/scripts/OPS.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. ガード: Vault に cron 専用の秘密が無いままジョブを差し替えると、翌朝から 401 になる
-- ----------------------------------------------------------------------------
do $guard$
begin
  if not exists (
    select 1 from vault.decrypted_secrets where name = 'lien_cron_secret'
  ) then
    raise exception
      'Vault に lien_cron_secret がありません。先に作成し、Function secrets の LIEN_CRON_SECRET にも同じ値を入れてください(scripts/OPS.md §6)';
  end if;
end
$guard$;

-- ----------------------------------------------------------------------------
-- 1. ジョブ(0003 から Authorization の秘密だけ lien_cron_secret に変える)
--    net.http_post(url, body, params, headers, timeout_milliseconds) — pg_net 0.20 の実際の引数。
--    Authorization は実行時に Vault から引く(ジョブの command 文字列に秘密は残らない)
-- ----------------------------------------------------------------------------

-- 毎月1日 00:05 JST: 月次チケット付与。JST の日付が1日でない日は何も呼ばない。
-- 毎日起動して JST の1日だけ通す理由: cron 式に「月末の翌日(JST)」を書けないため。
-- 月の途中に呼ばれても、ペア × 月の実行記録(migration 0006)で二重付与はしないが、通常は呼ばない
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
        where name = 'lien_cron_secret'
      )
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  )
  where extract(day from (now() at time zone 'Asia/Tokyo')) = 1;
  $cron$
);

-- 毎日 00:10 JST: 前日(JST)の確定。再実行しても結果は同じ(冪等。リセットの通知だけは再送されるので、
-- 手動の再実行は notify:false — scripts/ops/run-cron-fn.sh)
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
        where name = 'lien_cron_secret'
      )
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $cron$
);
