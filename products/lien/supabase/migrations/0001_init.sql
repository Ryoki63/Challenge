-- ============================================================================
-- Lien migration 0001_init
--
-- 正本:
--   - スキーマ: docs/REQUIREMENTS.md §5(データモデル)
--   - RLS 方針: docs/DESIGN.md §5.2
--   - invites の補足決定(8文字英数 / 72h / 1回限り): docs/DESIGN.md §5.1
--
-- RLS の基本方針(DESIGN §5.2):
--   * 全テーブル RLS 有効化・既定 deny(ポリシーが無い操作はすべて拒否)
--   * クライアント(authenticated ロール。匿名サインインも authenticated)は
--     「自分の行 or 自分が属するペアの行」の SELECT のみ
--   * 書き込みは Edge Function(service_role。BYPASSRLS)経由のみ。
--     例外: users は自分の行のみ UPDATE 可(列レベル GRANT で更新可能列を制限)
--   * 防波堤として GRANT も最小化する(RLS と二重の守り)
--   * ペア解消(= ブロック。REQUIREMENTS §3.2 / §8)の遮断を DB 層でも保証する:
--     - user スコープ(promises / checkins / reactions)と写真(Storage)は
--       「現役(active)ペア」のみ相互閲覧可。解消後・成立前のデータは漏れない
--     - pair スコープ(pairs / streak_days / plants 等)は解消後もメンバーなら
--       閲覧可(アーカイブ閲覧。REQUIREMENTS §6)
--
-- 認証との関係:
--   * public.users.id = auth.users.id = auth.uid()。
--     auth.users への INSERT(匿名サインイン含む)時にトリガーで
--     public.users の骨組み行を自動作成する(Supabase 公式パターン)。
--     ニックネーム等はオンボーディングでクライアントが UPDATE する。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 拡張(gen_random_uuid は pgcrypto。Supabase では既定で有効だが念のため)
-- ----------------------------------------------------------------------------
create extension if not exists pgcrypto;

-- ============================================================================
-- 1. テーブル定義(REQUIREMENTS §5 に忠実。列・PK・FK・UNIQUE・型)
-- ============================================================================

-- users: アプリ利用者プロフィール。id は auth.users と 1:1(= auth.uid())
create table public.users (
  id            uuid primary key references auth.users (id) on delete cascade,
  apple_sub     text unique,                       -- Sign in with Apple の sub(未連携なら null)
  nickname      text not null default ''
                check (char_length(nickname) <= 8), -- REQUIREMENTS §3.1: ニックネーム8字
  avatar_emoji  text not null default '',           -- 絵文字パレットから選択
  timezone      text not null default 'Asia/Tokyo', -- DESIGN §9: TZ 既定 Asia/Tokyo
  remind_at     time default '20:00',               -- REQUIREMENTS §3.1: 既定20:00。null = OFF
  push_token    text,                               -- APNs デバイストークン
  premium_until timestamptz,                        -- RevenueCat Webhook(service_role)のみが更新
  created_at    timestamptz not null default now()
);

-- pairs: 2人1組の関係。プレミアム判定はメンバーの premium_until から導出(plan列は持たない)
create table public.pairs (
  id             uuid primary key default gen_random_uuid(),
  status         text not null default 'active'
                 check (status in ('active', 'dissolved')),
  started_on     date not null,                     -- ペア成立日。これ以降がストリーク判定対象(DESIGN §5.4)
  dissolved_at   timestamptz,                       -- 解消時刻。dissolve Function が status と同時に設定。
                                                    -- RLS の期間スコープ・監査・UI表示に使う
                                                    -- (REQUIREMENTS §5 への追記が必要 → followup)
  ticket_balance int  not null default 0
                 check (ticket_balance >= 0),
                 -- 初期付与(無料2枚)は invite-accept Function の責務。
                 -- ledger との整合を保つため DB 既定値では配らない
  created_at     timestamptz not null default now(),
  -- status と dissolved_at の整合を DB で強制(dissolved ⇔ dissolved_at 非null)
  constraint pairs_dissolved_at_consistency
    check ((status = 'dissolved') = (dissolved_at is not null))
);

-- pair_members: ペア所属。v1 は1ユーザー1ペア(枚数制限は Function 側で検査。
-- 解消済みペアの行も「アーカイブ閲覧」のために残すので、DB 制約では縛らない)
create table public.pair_members (
  pair_id   uuid not null references public.pairs (id) on delete cascade,
  user_id   uuid not null references public.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (pair_id, user_id)
);

-- shares_active_pair_with() / is_pair_member() 系が user_id 起点で引くための索引
create index pair_members_user_id_idx on public.pair_members (user_id);

-- promises: 約束はユーザーに1つ(ペアに属さない。REQUIREMENTS §3.3)
create table public.promises (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users (id) on delete cascade,
  title       text not null check (char_length(title) <= 20), -- REQUIREMENTS §3.3: タイトル20字
  emoji       text not null,
  remind_at   time,
  created_at  timestamptz not null default now(),
  archived_at timestamptz                          -- null = 現役の約束
);

-- 「1人1つ」を DB でも担保: 現役(未アーカイブ)の約束はユーザーごとに1件
create unique index promises_one_active_per_user
  on public.promises (user_id)
  where archived_at is null;

-- checkins: 1日1回。判定は本人のローカル日付(REQUIREMENTS §3.4)
create table public.checkins (
  id         uuid primary key default gen_random_uuid(),
  promise_id uuid not null references public.promises (id),
             -- 約束は削除でなくアーカイブする運用(履歴保護)。
             -- 参照アクションは既定の NO ACTION(文末判定)にする:
             -- RESTRICT だとアカウント削除時の users→promises/checkins の
             -- 同時カスケードが即時判定で失敗するため
  user_id    uuid not null references public.users (id) on delete cascade,
  date_local date not null,
  photo_path text,                                 -- Storage 上のパス 'pairs/<pair_id>/...'
  created_at timestamptz not null default now(),
  constraint checkins_user_date_unique unique (user_id, date_local)
             -- 冪等性の要(DESIGN §5.5)。重複リクエストは Function が 200 を返す
);

create index checkins_promise_id_idx on public.checkins (promise_id);

-- streak_days: 継続日の確定記録。行があれば「その日は継続」(DESIGN §5.4)
create table public.streak_days (
  pair_id    uuid not null references public.pairs (id) on delete cascade,
  date_local date not null,
  kind       text not null check (kind in ('both', 'ticket')),
  primary key (pair_id, date_local)
             -- close-day の再実行は PK 衝突 upsert で冪等(DESIGN §5.4)
);

-- ticket_ledger: お休みチケットの増減台帳(pairs.ticket_balance はこの集計キャッシュ)
create table public.ticket_ledger (
  id         uuid primary key default gen_random_uuid(),
  pair_id    uuid not null references public.pairs (id) on delete cascade,
  delta      int  not null check (delta <> 0),
  reason     text not null check (reason in ('monthly', 'consume', 'declare')),
  date_local date not null,
  created_at timestamptz not null default now()
);

create index ticket_ledger_pair_idx on public.ticket_ledger (pair_id, created_at);

-- nudges: つつき。1日3回制限は Function 内で当日カウント(DESIGN §5.5)
create table public.nudges (
  id         uuid primary key default gen_random_uuid(),
  pair_id    uuid not null references public.pairs (id) on delete cascade,
  from_user  uuid not null references public.users (id) on delete cascade,
  stamp      text not null,                        -- スタンプ種別。語彙は messages.ts(サーバー)が正
  replied    text,                                 -- 定型返事。null = 未返答
  created_at timestamptz not null default now()
);

-- レート制限(from_user × 当日)を引くための索引
create index nudges_pair_from_created_idx on public.nudges (pair_id, from_user, created_at);

-- reactions: 相手のチェックインへのスタンプ。1チェックインにつき1人1つ(REQUIREMENTS §3.8)
create table public.reactions (
  id         uuid primary key default gen_random_uuid(),
  checkin_id uuid not null references public.checkins (id) on delete cascade,
  from_user  uuid not null references public.users (id) on delete cascade,
  stamp      text not null,                        -- ❤️🔥👏😂🥹💪。語彙の検証は Function 側
  created_at timestamptz not null default now(),
  constraint reactions_one_per_user_per_checkin unique (checkin_id, from_user)
);

-- plants: ペアに1鉢。成長段階 0..5(種→芽→双葉→若葉→つぼみ→開花)
create table public.plants (
  pair_id    uuid primary key references public.pairs (id) on delete cascade,
  species    text not null,
  name       text,                                 -- 植物の名前(2人で命名)
  grown_days int  not null default 0 check (grown_days >= 0), -- ふたり達成の累計日数
  stage      int  not null default 0 check (stage between 0 and 5)
);

-- invites: 招待トークン。8文字英数・72時間・1回限り(DESIGN §5.1)
--   * token 生成(紛らわしい 0/O/1/l を除いた英数8字)は invite-create Function の責務
--   * 72h: expires_at = 発行時刻 + interval '72 hours' を Function が設定
--   * 1回限り: 受諾時に used_at を打刻し、used_at が non-null なら再利用不可(Function が検査)
create table public.invites (
  token      text primary key check (token ~ '^[A-Za-z0-9]{8}$'),
  from_user  uuid not null references public.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz                           -- null = 未使用
);

create index invites_from_user_idx on public.invites (from_user);

-- ============================================================================
-- 2. helper 関数
-- ============================================================================

-- is_pair_member: 呼び出しユーザー(auth.uid())が指定ペアのメンバーか。
-- security definer により pair_members の RLS を介さず判定できる
-- (pair_members 自身のポリシーから呼んでも無限再帰しない)。
-- 解消済み(dissolved)ペアもメンバーなら true。これはアーカイブ閲覧
-- (REQUIREMENTS §6「アーカイブ閲覧のみ」= ペア・植物・ストリーク系)を担う
-- pair_id スコープのテーブル(pairs / pair_members / streak_days /
-- ticket_ledger / nudges / plants)専用。
-- ※ 写真(Storage)には使わない(解消時「共有写真は相互に非表示」§3.2)
--   → is_active_pair_member を使う
create or replace function public.is_pair_member(p_pair_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.pair_members pm
    where pm.pair_id = p_pair_id
      and pm.user_id = auth.uid()
  );
$$;

-- is_active_pair_member: 呼び出しユーザーが指定ペアの「現役(active)」メンバーか。
-- 解消済みペアでは false。解消時に双方向で遮断すべきリソース
-- (Storage の共有写真。REQUIREMENTS §3.2「共有写真は相互に非表示」)に使う
create or replace function public.is_active_pair_member(p_pair_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.pair_members pm
    join public.pairs p on p.id = pm.pair_id
    where pm.pair_id = p_pair_id
      and pm.user_id = auth.uid()
      and p.status = 'active'
  );
$$;

-- shares_active_pair_with: 呼び出しユーザーが指定ユーザーと「現役(active)」の
-- 同一ペアに属しているか(本人指定なら常に true)。
-- pair_id 列を持たない user スコープのテーブル(promises / checkins / reactions)用。
--
-- 設計意図(privacy hole 対策):
--   * pairs.status = 'active' を必須にする。解消(= ブロック。REQUIREMENTS §8)後は
--     元相手の行が一切読めなくなり、解消後に作られる新しいデータも漏れない。
--     「自分のチェックイン履歴は残る」(§3.2)は本人分岐(p_user_id = auth.uid())で保たれ、
--     アーカイブ閲覧(§6)はペア・植物・ストリーク系(is_pair_member 側)で足りる
--   * p_date_local(任意)で期間スコープ。指定時は pairs.started_on <= p_date_local の
--     ペアのみ許可 = 新しい相手がペア成立前の過去履歴(前ペア時代のチェックイン等)を
--     遡って読めない。成立当日の分は見える(started_on 当日からストリーク判定対象。DESIGN §5.4)
-- ※ DESIGN §5.2 の is_pair_member に加えて本マイグレーションで導入した補助関数
create or replace function public.shares_active_pair_with(
  p_user_id    uuid,
  p_date_local date default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id = auth.uid()
      or exists (
           select 1
           from public.pair_members me
           join public.pair_members them on them.pair_id = me.pair_id
           join public.pairs p on p.id = me.pair_id
           where me.user_id = auth.uid()
             and them.user_id = p_user_id
             and p.status = 'active'
             and (p_date_local is null or p.started_on <= p_date_local)
         );
$$;

-- helper の実行権限: クライアント(authenticated)のみ。anon には渡さない
revoke execute on function public.is_pair_member(uuid)               from public, anon;
revoke execute on function public.is_active_pair_member(uuid)        from public, anon;
revoke execute on function public.shares_active_pair_with(uuid, date) from public, anon;
grant  execute on function public.is_pair_member(uuid)               to authenticated, service_role;
grant  execute on function public.is_active_pair_member(uuid)        to authenticated, service_role;
grant  execute on function public.shares_active_pair_with(uuid, date) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- auth.users → public.users の自動プロフィール作成トリガー(Supabase 公式パターン)
-- 匿名サインイン時点で骨組み行を作り、ニックネーム等はクライアントが UPDATE する。
-- これにより「クライアントは users に INSERT しない」(書き込みは Function/トリガーのみ)を保てる
-- ----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.users (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================================
-- 3. RLS 有効化(全テーブル。ポリシーが無い操作は既定 deny)
-- ============================================================================
alter table public.users         enable row level security;
alter table public.pairs         enable row level security;
alter table public.pair_members  enable row level security;
alter table public.promises      enable row level security;
alter table public.checkins      enable row level security;
alter table public.streak_days   enable row level security;
alter table public.ticket_ledger enable row level security;
alter table public.nudges        enable row level security;
alter table public.reactions     enable row level security;
alter table public.plants        enable row level security;
alter table public.invites       enable row level security;

-- ============================================================================
-- 4. GRANT の最小化(防波堤の2枚目。RLS と独立にテーブル権限でも縛る)
--    Supabase の既定では anon / authenticated に ALL が付与されるため明示的に剥がす。
--    service_role は BYPASSRLS + 全権限のまま(Edge Function 用)
-- ============================================================================
revoke all on table
  public.users, public.pairs, public.pair_members, public.promises,
  public.checkins, public.streak_days, public.ticket_ledger,
  public.nudges, public.reactions, public.plants, public.invites
from anon, authenticated;

-- クライアントに許すのは SELECT のみ(行の絞り込みは下のポリシーが行う)
grant select on table
  public.users, public.pairs, public.pair_members, public.promises,
  public.checkins, public.streak_days, public.ticket_ledger,
  public.nudges, public.reactions, public.plants, public.invites
to authenticated;

-- 例外: users は自分の行のみ UPDATE 可(DESIGN §5.2)。
-- 列レベル GRANT で更新できる列をプロフィール系に限定する。
-- premium_until(RevenueCat Webhook が更新)・apple_sub・created_at は
-- クライアントから変更不可
grant update (nickname, avatar_emoji, timezone, remind_at, push_token)
  on table public.users to authenticated;

-- ============================================================================
-- 5. RLS ポリシー(DESIGN §5.2)
--    書き込み(insert/update/delete)ポリシーは users.update を除いて一切作らない
--    = クライアントの書き込みは既定 deny。書き込みは service_role(RLSバイパス)のみ
-- ============================================================================

-- users: 自分の行のみ select / update(相手のプロフィールは snapshot Function 経由で受け取る)
create policy users_select_self on public.users
  for select to authenticated
  using (id = (select auth.uid()));

create policy users_update_self on public.users
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- pairs: メンバーのみ select。書き込みは Function のみ
create policy pairs_select_member on public.pairs
  for select to authenticated
  using (public.is_pair_member(id));

-- pair_members: 自分が属するペアの行(=自分と相方の2行)のみ select。
-- is_pair_member が security definer なので自テーブル参照でも再帰しない
create policy pair_members_select_member on public.pair_members
  for select to authenticated
  using (public.is_pair_member(pair_id));

-- promises: 自分の約束+「現役ペア」相手の約束を select 可
-- (REQUIREMENTS §3.3「相手の約束はホームに常時表示」)。編集は Function のみ。
-- ペア解消後は元相手の約束(現役タイトル含む)は読めない(§3.2 / §8 ブロック)
create policy promises_select_pair on public.promises
  for select to authenticated
  using (public.shares_active_pair_with(user_id));

-- checkins: 自分の行はすべて(§3.2「自分のチェックイン履歴は残る」)、
-- 相手の行は「現役ペア」かつ date_local がペア成立日(started_on)以降のもののみ select。
--   * 解消後: 元相手のチェックイン(解消後の新規分も含む)は一切読めない
--   * 新ペア: 相手のペア成立前の過去履歴(前ペア時代のメタデータ)は読めない
-- 書き込みは checkin Function のみ
create policy checkins_select_pair on public.checkins
  for select to authenticated
  using (public.shares_active_pair_with(user_id, date_local));

-- streak_days: メンバーのみ select。書き込みは close-day Function のみ
create policy streak_days_select_member on public.streak_days
  for select to authenticated
  using (public.is_pair_member(pair_id));

-- ticket_ledger: メンバーのみ select。書き込みは Function(grant-tickets / close-day)のみ
create policy ticket_ledger_select_member on public.ticket_ledger
  for select to authenticated
  using (public.is_pair_member(pair_id));

-- nudges: メンバーのみ select。書き込みは nudge Function のみ(1日3回制限も Function)
create policy nudges_select_member on public.nudges
  for select to authenticated
  using (public.is_pair_member(pair_id));

-- reactions: 送り手が自分 or 「現役ペア」相手の行のみ select。書き込みは react Function のみ。
-- 解消後は元相手が送ったリアクションは読めない(チェックイン本体と同じ遮断方針)
create policy reactions_select_pair on public.reactions
  for select to authenticated
  using (public.shares_active_pair_with(from_user));

-- plants: メンバーのみ select。成長更新は Function のみ
create policy plants_select_member on public.plants
  for select to authenticated
  using (public.is_pair_member(pair_id));

-- invites: 自分が発行したものだけ select 可(発行済みリンクの再表示用)。
-- token での参加検証は invite-accept Function(service_role)が行うため、
-- 他人のトークンはクライアントから一切見えない(列挙・横取り防止)
create policy invites_select_own on public.invites
  for select to authenticated
  using (from_user = (select auth.uid()));

-- ============================================================================
-- 6. Storage: チェックイン写真バケット(DESIGN §5.2)
--    パス規約: photos バケット内 'pairs/<pair_id>/...'
--    配布の主経路は Function が発行する署名付きURL。下記の select ポリシーは
--    「ペアメンバー以外は署名なしで絶対に読めない」ことを DB 層でも保証する防波堤。
--    アップロード経路(署名付きアップロードURL or Function 経由)は T04/T05 で決定するため、
--    クライアントへの insert/update/delete ポリシーはここでは作らない(既定 deny)
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('photos', 'photos', false)
on conflict (id) do nothing;

-- 読み取り: パスの第1セグメントが 'pairs'、第2セグメントが自分の属する
-- 「現役(active)」pair_id の UUID であるオブジェクトのみ。
-- is_active_pair_member を使うことで、ペア解消後は双方とも当該ペアの写真を
-- 読めなくなる(REQUIREMENTS §3.2「共有写真は相互に非表示」を DB 層で保証。
-- アーカイブ閲覧 §6 の対象はペア・植物・ストリーク系であり写真は含まない)。
-- uuid キャスト前に正規表現で形式を検査し、不正パスでのキャストエラーを防ぐ
create policy photos_select_pair_member on storage.objects
  for select to authenticated
  using (
    bucket_id = 'photos'
    and (storage.foldername(name))[1] = 'pairs'
    and (storage.foldername(name))[2]
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and public.is_active_pair_member(((storage.foldername(name))[2])::uuid)
  );
