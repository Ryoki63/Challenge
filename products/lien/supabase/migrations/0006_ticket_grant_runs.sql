-- ============================================================================
-- Lien migration 0006_ticket_grant_runs
--
-- 正本:
--   - 月次付与: docs/DESIGN.md §5.3(grant-tickets)/ docs/REQUIREMENTS.md §3.6
--   - 承認: D4(docs/REVIEW-2026-10-12.md §1。追加系の migration)/ issue #60
--
-- 問題:
--   月次チケット付与(grant-tickets)の「今月分は付与済みか」は、これまで
--   ticket_ledger の reason = 'monthly' の行で判定していた。ところが上限に達している
--   ペア(無料で残数 2)は付与額が 0 になり、ledger は delta <> 0 の制約で 0 の行を
--   書けないため、付与済みかどうかが分からない。月の途中に再実行すると、その間に
--   チケットを使ったペアへもう一度付与してしまう(二重付与)。
--
-- 変更(追加系のみ。既存の表・列・ポリシーは変えない):
--   1. ticket_grant_runs — ペア × 月の実行記録。付与額が 0 のときも1行残す。
--      主キー (pair_id, month_start) が冪等キー
--   2. apply_monthly_ticket_grant() — 実行記録・残高・ledger を1トランザクションで書く RPC。
--      記録が既にあれば何もしない('already')。途中で失敗すれば全部巻き戻る
--      (記録だけ残って付与されない、付与されたのに記録が無い、を作らない)
--
-- 権限: どちらも service_role(Edge Function の grant-tickets)専用。クライアント
--   (anon / authenticated)からは読めない・書けない・呼べない。
--   ※ Supabase は public スキーマの新しい関数へ anon / authenticated の EXECUTE を
--     既定で付けるので、REVOKE を明示する(PostgREST の /rpc で外から呼べてしまう)
--
-- 本番への適用: scripts/OPS.md「適用記録」。この migration の後に grant-tickets を再デプロイする
--   (新しい grant-tickets はこの RPC を呼ぶ)。順序を逆にすると 500 になる
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 実行記録
-- ----------------------------------------------------------------------------
create table public.ticket_grant_runs (
  pair_id     uuid not null references public.pairs (id) on delete cascade,
  -- 付与した月の月初(JST の date_local 基準)。月初以外は拒否する
  month_start date not null
              check (month_start = date_trunc('month', month_start)::date),
  -- 実際に増減した枚数(上限到達は 0。無料へのダウングレードで切り詰めたときは負)
  delta       int  not null,
  created_at  timestamptz not null default now(),
  primary key (pair_id, month_start)
);

comment on table public.ticket_grant_runs is
  '月次チケット付与の実行記録(ペア × 月)。付与額が 0(上限到達)でも1行残す = 再実行の冪等キー。service_role 専用';

-- クライアントからは一切触らせない(RLS 有効 + ポリシーなし = 既定 deny、GRANT も剥がす)
alter table public.ticket_grant_runs enable row level security;
revoke all on table public.ticket_grant_runs from anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. 月次付与の適用(実行記録 + 残高 + ledger を1トランザクションで)
--    戻り値: 'granted'(残数を変えて ledger も書いた)/ 'unchanged'(付与額 0。記録だけ)/
--            'already'(今月分は記録済み。何も書かない)
--    p_delta は呼び出し側(grant-tickets/core.ts)が _shared/tickets.ts の算術で決める
--    (無料: min(2, 残数 + 2) への増減 / プレミアム: min(10, 残数 + 5))。
--    残数は p_delta を足す(読んでから書くまでの間に close-day が1枚使っても、その消費を消さない)。
--    残数が負になる p_delta は pairs の CHECK(ticket_balance >= 0)で例外になり、実行記録ごと巻き戻る
-- ----------------------------------------------------------------------------
create or replace function public.apply_monthly_ticket_grant(
  p_pair_id     uuid,
  p_month_start date,
  p_date_local  date,
  p_delta       int
)
returns text
language plpgsql
set search_path = ''
as $$
begin
  if p_month_start <> date_trunc('month', p_month_start)::date then
    raise exception 'p_month_start は月初の日付にしてください: %', p_month_start
      using errcode = '22023';
  end if;
  if p_date_local < p_month_start
     or p_date_local >= (p_month_start + interval '1 month')::date then
    raise exception 'p_date_local は p_month_start と同じ月の日付にしてください: % / %',
      p_date_local, p_month_start
      using errcode = '22023';
  end if;

  -- 実行記録を先に取る。主キー衝突 = 今月分は処理済み(競合した2つの実行のうち遅いほうもここで止まる)
  insert into public.ticket_grant_runs (pair_id, month_start, delta)
  values (p_pair_id, p_month_start, p_delta)
  on conflict (pair_id, month_start) do nothing;

  if not found then
    return 'already';
  end if;

  -- 上限到達(付与額 0)。ledger は delta <> 0 の制約で書けないので、実行記録だけ
  if p_delta = 0 then
    return 'unchanged';
  end if;

  update public.pairs
  set ticket_balance = ticket_balance + p_delta
  where id = p_pair_id;

  insert into public.ticket_ledger (pair_id, delta, reason, date_local)
  values (p_pair_id, p_delta, 'monthly', p_date_local);

  return 'granted';
end;
$$;

comment on function public.apply_monthly_ticket_grant(uuid, date, date, int) is
  '月次チケット付与の適用(実行記録・残高・ledger を1トランザクションで)。戻り値 granted / unchanged / already。service_role 専用(grant-tickets Function)';

revoke all on function public.apply_monthly_ticket_grant(uuid, date, date, int)
  from public, anon, authenticated;
grant execute on function public.apply_monthly_ticket_grant(uuid, date, date, int)
  to service_role;

-- PostgREST のスキーマキャッシュを更新する(新しい RPC をすぐ /rpc で呼べるように)
notify pgrst, 'reload schema';
