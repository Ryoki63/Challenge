-- ============================================================================
-- ⚠️⚠️⚠️ 警告 / WARNING ⚠️⚠️⚠️
--
-- このスクリプトは **破壊的** です(DELETE 文を含みます)。
-- 対象は「テスト専用に作成した2名のユーザー」に **厳密に** スコープしていますが、
-- 誤った UUID を渡すと本番の実ユーザーデータを削除してしまいます。
--
--   * 実行前に、渡す2つの UUID が本当にテスト専用アカウント
--     (products/lien/scripts/g1/seed-pair.sh 等で作成した匿名ユーザー)であることを
--     目視で再確認すること。実ユーザー(本物のカップル)の ID を絶対に渡さない
--   * このファイルは T20準備(issue #20)で**作成のみ**された。本番 Supabase
--     (ref: lniheehfbtpfhglinfjm)に対して実行されたことは一度もない
--   * 実行は人間が手元で判断して行う。CI・自律エージェントが自動実行しないこと
--   * 初回は末尾の COMMIT; を ROLLBACK; に変えてドライランし、
--     「検証」セクションの SELECT 結果を確認してから本実行すること
--
-- 位置づけ: products/lien/supabase/migrations/ の NNNN_<name>.sql 命名規則とは
-- 無関係(本番スキーマを変更しない運用スクリプトのため migrations/ には置かない。
-- DESIGN.md §5.1 の番号付け規約と衝突させないための意図的な配置)。
-- ============================================================================

-- ============================================================================
-- 目的
--
-- M1 実機 E2E チェックリスト(docs/E2E-M1.md)を複数回・繰り返し実施すると、
-- テスト用の2ユーザーに checkins / nudges / reactions / invites / pairs /
-- streak_days(ふたりストリーク)/ ticket_ledger / plants が積み重なる。
-- 本スクリプトはそれらを「ペア未成立の初期状態」に戻す。
--
-- 対象(削除する): checkins, nudges, reactions, invites, pairs
--   (pairs を削除すると同じトランザクション内で pair_members / streak_days /
--    ticket_ledger / plants も明示的に削除する — 下記参照)
-- 対象外(残す): users 本体(ニックネーム・アイコン・push_token 等) / promises
--   (再実施のたびにオンボーディングと約束設定をやり直さずに済むようにするため。
--    約束を完全に作り直したい場合は末尾の「任意: 約束も作り直す」セクションを
--    コメントアウトから外して使うこと)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 使い方
--
--   psql "$DATABASE_URL" \
--     -v test_user_a=123e4567-e89b-12d3-a456-426614174000 \
--     -v test_user_b=00000000-0000-0000-0000-000000000002 \
--     -f products/lien/supabase/scripts/e2e_reset.sql
--
-- ⚠️ -v に渡す値は UUID の生の文字列そのもの(ハイフンのみ・引用符を含めない)。
-- ファイル中の :'test_user_a' という記法が SQL 文字列リテラルとして必要な
-- クォート(' ... ')を自動で付け足すため、-v 側で '<uuid>' のように
-- 自分でシングルクォートを含めると二重にクォートされて壊れる。
--
-- test_user_a / test_user_b は **-v で必ず指定する**。指定しない場合、
-- 下の安全確認で未定義を検出して即座に停止する(\quit。何も削除しない)。
-- ----------------------------------------------------------------------------

\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- 安全確認(トランザクション開始より前に実施)。2段階:
--   (a) 両変数が定義されているか(:{?name} は TRUE/FALSE に展開される。
--       psql ドキュメント「SQL Interpolation」記載の標準機能)
--   (b) 定義されていれば、2つの ID が異なり、かつ public.users に
--       実在するか
-- いずれか失敗したら \quit で即座に中断する(無言で0件削除になり
-- 「成功した」と誤解することを防ぐ)。
--
-- 実装上の注意: この確認はあえて PL/pgSQL の DO $$ ... $$ ブロックを使わない。
-- dollar-quote の内側で :'name' 展開が確実に起こるかを本エージェントの
-- 手元では実機確認できなかったため、曖昧さを完全に排除できる
-- 「素の SQL + \gset + \if」の組み合わせのみを使う(dollar-quote を
-- 一切含まないため展開の疑義が無い)。
-- ----------------------------------------------------------------------------
\if :{?test_user_a}
\else
\echo 'ERROR: test_user_a が指定されていません。-v test_user_a=<uuid>(引用符なし)を指定してください。処理を中断します(何も削除していません)'
\quit
\endif

\if :{?test_user_b}
\else
\echo 'ERROR: test_user_b が指定されていません。-v test_user_b=<uuid>(引用符なし)を指定してください。処理を中断します(何も削除していません)'
\quit
\endif

select case
  when :'test_user_a'::uuid is distinct from :'test_user_b'::uuid
   and exists (select 1 from public.users where id = :'test_user_a'::uuid)
   and exists (select 1 from public.users where id = :'test_user_b'::uuid)
  then 'true'
  else 'false'
end as safety_ok
\gset

\if :safety_ok
\else
\echo 'ERROR: 安全確認に失敗しました。test_user_a / test_user_b が「異なる・かつ public.users に実在する」UUID であることを確認してください。処理を中断します(何も削除していません)'
\quit
\endif

begin;

-- ----------------------------------------------------------------------------
-- 対象ペアIDを先に確定して一時テーブルに保持する。
-- (pair_members 行を先に消すと「このユーザーがどのペアにいたか」を後から
--  引けなくなるため、削除を始める前に確定させておく。トランザクション終了時に
--  自動で破棄される = on commit drop)
-- ----------------------------------------------------------------------------
create temporary table _e2e_reset_target_pairs on commit drop as
select distinct pair_id
from public.pair_members
where user_id in (:'test_user_a'::uuid, :'test_user_b'::uuid);

-- ----------------------------------------------------------------------------
-- 削除本体(子テーブル→親テーブルの順。pairs の on delete cascade に依存せず
-- 明示的に書く — 読む人がこのスクリプトだけで影響範囲を把握できるようにする)
-- ----------------------------------------------------------------------------

-- 1) reactions: 対象ユーザーが送ったリアクション、または対象ユーザーの checkin に
--    付いたリアクション(相手が test_user ならどちらの経路でも対象になる)
delete from public.reactions
where from_user in (:'test_user_a'::uuid, :'test_user_b'::uuid)
   or checkin_id in (
     select id from public.checkins
     where user_id in (:'test_user_a'::uuid, :'test_user_b'::uuid)
   );

-- 2) nudges: 対象ユーザーが送った、または対象ユーザーが属していたペアのもの
delete from public.nudges
where from_user in (:'test_user_a'::uuid, :'test_user_b'::uuid)
   or pair_id in (select pair_id from _e2e_reset_target_pairs);

-- 3) checkins(本人のローカル日付で1日1回。REQUIREMENTS §3.4)
delete from public.checkins
where user_id in (:'test_user_a'::uuid, :'test_user_b'::uuid);

-- 4) invites(送った側のみ記録される。受諾側を記録する列は無い — migration 0001)
delete from public.invites
where from_user in (:'test_user_a'::uuid, :'test_user_b'::uuid);

-- 5) ふたりストリーク(streak_days)・お休みチケット台帳(ticket_ledger)・
--    植物(plants)— いずれもペア単位(pair_id が主キー/一部)
delete from public.streak_days
where pair_id in (select pair_id from _e2e_reset_target_pairs);

delete from public.ticket_ledger
where pair_id in (select pair_id from _e2e_reset_target_pairs);

delete from public.plants
where pair_id in (select pair_id from _e2e_reset_target_pairs);

-- 6) pair_members → pairs(最後。これで対象ユーザーはどのペアにも属さない
--    「ソロ状態」= REQUIREMENTS §3.2「招待待ちでも使える」の初期状態に戻る)
delete from public.pair_members
where pair_id in (select pair_id from _e2e_reset_target_pairs);

delete from public.pairs
where id in (select pair_id from _e2e_reset_target_pairs);

-- ----------------------------------------------------------------------------
-- 任意: 約束(promises)も作り直したい場合
--
-- 既定では promises は残す(再実施のたびに §3.3 の約束設定をやり直さずに済む
-- ようにするため。約束の編集はいつでも可能でストリークに影響しない設計 — §3.3)。
-- 「約束作成フロー自体」もチェックリスト項目④で毎回検証したい場合のみ、
-- 以下のコメントアウトを外して「現役の約束をアーカイブ」する
-- (migration 0001 の unique index promises_one_active_per_user は
--  archived_at is null の行のみを対象にするため、アーカイブすれば新規作成できる。
--  履歴として行自体は残すため DELETE ではなく UPDATE にしている)
-- ----------------------------------------------------------------------------
-- update public.promises
-- set archived_at = now()
-- where user_id in (:'test_user_a'::uuid, :'test_user_b'::uuid)
--   and archived_at is null;

-- ----------------------------------------------------------------------------
-- 検証: すべて 0 件になっているはず(COMMIT 前に目視確認すること)
-- ----------------------------------------------------------------------------
select
  (select count(*) from public.checkins
    where user_id in (:'test_user_a'::uuid, :'test_user_b'::uuid))      as remaining_checkins,
  (select count(*) from public.nudges
    where from_user in (:'test_user_a'::uuid, :'test_user_b'::uuid))    as remaining_nudges_sent,
  (select count(*) from public.reactions
    where from_user in (:'test_user_a'::uuid, :'test_user_b'::uuid))    as remaining_reactions_sent,
  (select count(*) from public.invites
    where from_user in (:'test_user_a'::uuid, :'test_user_b'::uuid))    as remaining_invites,
  (select count(*) from public.pair_members
    where user_id in (:'test_user_a'::uuid, :'test_user_b'::uuid))      as remaining_pair_memberships,
  (select count(*) from public.pairs
    where id in (select pair_id from _e2e_reset_target_pairs))          as remaining_pairs;

-- ----------------------------------------------------------------------------
-- 上の検証結果が全て 0 であることを確認してから commit する。
-- 不安であれば一度だけ下を rollback; に変えてドライランすること。
-- ----------------------------------------------------------------------------
commit;
