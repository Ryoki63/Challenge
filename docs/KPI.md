# Lien — KPI の SQL(v1.0 の計測)

- 作成日: 2026-10-13(issue #69)
- 位置づけ: **D6**(v1.0 は分析 SDK を入れず、DB から SQL で出す。[REQUIREMENTS.md](REQUIREMENTS.md) §7・[TASKPLAN.md](TASKPLAN.md) §9.1)の指標を、そのまま流せる SQL にしたもの。毎週金曜の `/status` で実行して、率と母数を記録する(TASKPLAN §5)
- 定義の出どころ: REQUIREMENTS §7(指標の名前とデータ源)・[GROWTH.md](GROWTH.md) §10(植物の指標と目標)・TASKPLAN §5(月3万円への逆算の KPI)。本書は、これらを実際のテーブルと列に当てはめて検証したものなので、**数え方が食い違ったら本書を正とし**、REQUIREMENTS §7 から指す
- 課金系の KPI(課金開始+1 か月の転換率など。TASKPLAN §5)の基準日は**課金開始日(v1.1。11/12〜13 予定)**。リリース+1 か月の KPI(D30・ペア成立率)の基準は v1.0 の公開日(10/30–31 予定)。目標の数値は変えていない
- 手元の手動実行専用。CI・GitHub Actions には載せない(リポジトリは公開で、Actions のログに件数が残るため。OPS.md §2 の監視と同じ方針)

## 0. 守ること

1. **読み取りだけ**。アプリは計測のために何も送らない(REQUIREMENTS §7)。新しいテーブル・列・関数・migration も要らず、既存のテーブルを集計するだけ。SQL は SELECT だけで、先頭の `set transaction read only;` が、書き込みや DDL が混ざっても Postgres に拒否させる(`db-query.sh`〔Management API〕で、この行のあとの SELECT の結果が返ることと、`show transaction_read_only` が `on` になることを確認済み)
2. **テストデータを除く**。本番にはテストデータが残っている。台帳は [OPS.md](../products/lien/scripts/OPS.md) §8。実ユーザーがまだ 1 人もいないあいだは、除外すると**全部の母数が 0 になるのが正しい**。SQL そのものが動くことを確かめたいときは `include_test` を true にする(§5)
3. **母数(`den`)を見る**。G3 のテスターは 5〜10 ペアなので、1 ペアで率が 10〜20 ポイント動く。率より `num / den` と、ペア別の経過(§5)を読む(GROWTH §10.4: A/B テストはしない。ペアごとの経過を読んで判断する)
4. **公開リポジトリに書かない**。結果の**ペア ID・ユーザー ID・ニックネーム**は、JOURNAL・issue・コミットに書かない。記録するのは指標ごとの `num / den` と率だけ

## 1. 実行のしかた

```bash
set -a; source .env; set +a     # SUPABASE_ACCESS_TOKEN を環境変数に読む(値は表示されない)
# このファイルの最初の sql のコードブロック(§3)を取り出して流す
awk '/^```sql$/{n++; f=(n==1); next} /^```$/{f=0} f' docs/KPI.md > "${TMPDIR:-/tmp}/kpi.sql"
bash products/lien/scripts/ops/db-query.sh -f "${TMPDIR:-/tmp}/kpi.sql" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    print("%-30s %5s / %-5s %-7s %s" % (r["metric"], r["num"], r["den"], r["rate"], r["meaning"]))'
```

- 結果は 1 行 = 1 指標。`as_of` の行は基準日(JST)と、テストデータを含む設定かどうか(`include_test`)
- `rate` = `num / den`(`den` が 0 のときは空)。`median_days` は段階の行だけ
- 一時ファイルはリポジトリに置かない(`.gitignore` に頼らず、`/tmp` などへ)

## 2. 読み方の約束

1. **成熟した分だけ数える**。結果がまだ決まっていないペア・招待・つつきは母数に入れない(入れると、率が実際より低く出る)。条件は各指標の定義(§4)
2. **確定の遅れ**。ふたり達成日は close-day(毎日 00:10 JST)が**昨日までを書く**。今日の分は入らない。cron が止まった日があると、OPS.md §4 で再実行するまでその日が抜けるので、KPI を読む前に `lien-cron-watch` が緑であることを見る(`/status` の「本番 cron」)
3. **消えるデータ**。アカウント削除で users・invites・nudges・checkins・reactions が消える(DESIGN §5.3 delete-account)。ペアは、相手が残れば解消済みのまま残り、誰も居なくなれば pairs・streak_days・plants ごと消える。削除が増えると、過去の母数が減る(特に招待とつつき)
4. **解消したペアは実ペアに含める**(離脱として数える)。同じ 2 人が組み直すと新しい pairs の行(新しい成立日)になり、別のコホートとして数える(植物・ストリークは復活しない — REQUIREMENTS §3.2)
5. **審査員・審査用デモ・開発者自身の端末は実ユーザーではない**。審査用デモ(T30)の相手役と審査員のアカウント、内部 TestFlight で開発者が使うアカウントは、作ったら OPS.md §8 の台帳に足して除く。台帳のユーザーが 1 人でも入っているペアは、**ペアごと**除く
6. **一時的なテストユーザー**。エージェントの本番スモークや通しテスト(OPS.md §10・§12)は、匿名ユーザーを作って終わりに削除する。実行中に KPI を流すと混ざることがある(終われば消える。残ったら OPS.md §8 に足す)
7. **因果ではない**。つつき → チェックインは相関で、つつかれなくても続けた人も含む
8. **SQL では測らないもの**: ダウンロード数は App Store Connect の App Analytics(アプリは何も送らない)/ シェア画像の生成は端末の中で作るので DB に残らない(REQUIREMENTS §7)/ ペイウォール → 体験 → 購読(v1.1)は課金の導入時に RevenueCat の分析で足りるかを決める。**チャネル別の DL(キャンペーンリンク)と、本書の SQL を組み合わせた週次の読み方は [marketing/measurement.md](../products/lien/marketing/measurement.md)**(issue #78)

## 3. SQL(週次レポート)

このファイルの**最初の sql のコードブロック**がこれ(§1 の `awk` はここを取り出す。順序を変えない)。1 本で、下の §4 の全指標が出る。必要な指標だけが欲しいときは、最後の `union all` の枝を消す(使われない CTE は実行されない)。

```sql
set transaction read only;   -- 以降は読み取りだけ。書き込み・DDL が混ざっても Postgres が拒否する
with
params as (
  select (now() at time zone 'Asia/Tokyo')::date as today,   -- 集計の基準日(JST)。ふたり達成日は close-day が昨日までを書く
         false as include_test                              -- true にするとテストデータも数える(SQL の動作確認用。いつもは false)
),
-- テストデータ(OPS.md §8「KPI の SQL から除く」と同じ一覧。台帳が増えたら、そちらと一緒にここへ足す)
test_users(id) as (values
  ('5f5eff69-d8df-4b27-8a01-d7ef07f9a40e'::uuid), ('759bf2ed-bc2f-44fb-a05f-a45dae4f6bb5'),
  ('2145bf47-6603-47fb-8993-cfbbde21b09e'), ('02545907-b191-43ea-aed4-7a59480772c9'),
  ('dd913492-263b-4e5e-8a0e-0c72e2c46897'), ('922ff8a7-72e2-41c8-8bf7-493693b2c4c6'),
  ('934df380-cc5c-440e-8e75-ab9f711866a3'), ('6b579485-8dee-4662-b3b3-9826ed5128cc'),
  ('86687f8b-df69-4a2d-8610-00d52259af9f'), ('3e68ed74-0190-4a70-84f5-cb254c6a9070'), ('2b4667a8-b2bd-4650-b531-d5fb3589912b'),
  ('ce6f1f22-1218-4e6a-9a16-a7007052e1f6'), ('8d56ea14-5cf0-449c-90f0-5c1116a3fe90'),
  ('be4c372d-0f32-4c8f-9183-2ee7b6abe342'), ('e8adc43d-61c3-4ae1-b238-ab505158d483'),
  ('46797561-77a7-4bfe-b588-e9b5a3bae11b'), ('4d2131ea-644f-4850-b1ac-a510b8fcaa0f'),
  ('662e804a-6988-4d2b-9295-e55d53a44f6d'), ('079bfe55-70fd-4f16-b790-359cdb6aa037')
),
real_users as (          -- 実ユーザー = テストユーザー以外
  select u.id, u.created_at
  from public.users u cross join params pr
  where pr.include_test or u.id not in (select id from test_users)
),
real_pairs as (          -- 実ペア = テストユーザーが1人も入っていないペア(解消済みも含む。離脱として数えるため)
  select p.id, p.started_on, p.status
  from public.pairs p cross join params pr
  where pr.include_test
     or not exists (
          select 1 from public.pair_members m
          where m.pair_id = p.id and m.user_id in (select id from test_users))
),
both_days as (           -- 確定したふたり達成日(お休みチケットの日 = kind 'ticket' は含めない)
  select s.pair_id, s.date_local
  from public.streak_days s
  join real_pairs p on p.id = s.pair_id
  where s.kind = 'both'
),

-- ① 両者継続(D1 / D7 / D30): 成立日 d0 の d0+n-2〜d0+n の3日間にふたり達成日が1日以上あるペアの割合。
--    d0+n が確定済み(= 昨日以前)のペアだけを数える
retention as (
  select d.n,
         count(*) filter (where p.id is not null and exists (
           select 1 from both_days b
           where b.pair_id = p.id
             and b.date_local between p.started_on + d.n - 2 and p.started_on + d.n
         )) as num,
         count(p.id) as den
  from (values (1), (7), (30)) as d(n)
  cross join params pr
  left join real_pairs p on p.started_on + d.n + 1 <= pr.today
  group by d.n
),

-- ② ペア成立率: 期限が切れたか使われた招待のうち、受諾された招待(72時間の有効期限が切れるまで結果が決まらないので、決まった招待だけ)
invites_resolved as (
  select count(*) filter (where i.used_at is not null) as num,
         count(*) as den
  from public.invites i cross join params pr
  where (pr.include_test or i.from_user not in (select id from test_users))
    and (i.used_at is not null or i.expires_at <= now())
),
--    補助: 作成から7日以上たったユーザーのうち、7日以内にペアが成立した人(招待を受けた側も数える)
paired_within_7d as (
  select count(*) filter (where exists (
           select 1 from public.pair_members m
           where m.user_id = u.id and m.joined_at <= u.created_at + interval '7 days'
         )) as num,
         count(*) as den
  from real_users u
  where u.created_at <= now() - interval '7 days'
),

-- ③ つつき → 2時間以内のチェックイン: 2時間以上たったつつきのうち、相手(送り手でないペアの所属者)がその後2時間以内にチェックインしたもの
nudges_matured as (
  select n.id,
         exists (
           select 1
           from public.pair_members m
           join public.checkins c on c.user_id = m.user_id
           where m.pair_id = n.pair_id and m.user_id <> n.from_user
             and c.created_at > n.created_at
             and c.created_at <= n.created_at + interval '2 hours'
         ) as converted
  from public.nudges n
  join real_pairs p on p.id = n.pair_id
  where n.created_at <= now() - interval '2 hours'
),
nudge_result as (
  select count(*) filter (where converted) as num, count(*) as den from nudges_matured
),

-- ④ 名前付け率: 最初のふたり達成日(= ふたばに届いた日)から3日以上たったペアのうち、植物に名前が付いたペア
first_both as (
  select b.pair_id, min(b.date_local) as first_date from both_days b group by b.pair_id
),
naming as (
  select count(*) filter (where pl.name is not null and pl.name <> '') as num,
         count(*) as den
  from first_both f
  join public.plants pl on pl.pair_id = f.pair_id
  cross join params pr
  where f.first_date + 3 <= pr.today
),

-- ⑤ 段階到達率: 成立から threshold 日以上たったペア(それより前には届けない)のうち、ふたり達成日が threshold 回以上あるペア。
--    median_days = 成立日から threshold 回目のふたり達成日までの日数の中央値。
--    threshold は snapshot.ts の PLANT_STAGE_THRESHOLDS = [0,1,3,7,14,21,30,45,66,100] と同じ(段階0 = たねは成立の時点)
stages(stage, name, threshold) as (values
  (1, 'ふたば', 1), (2, 'めばえ', 3), (3, 'わかば', 7), (4, 'よりそい', 14), (5, 'つぼみ', 21),
  (6, 'いろづき', 30), (7, 'ほころび', 45), (8, 'ふたりざき', 66), (9, 'みのり', 100)
),
nth_both as (
  select b.pair_id, b.date_local,
         row_number() over (partition by b.pair_id order by b.date_local) as k
  from both_days b
),
reach as (
  select s.stage, s.name, s.threshold,
         count(r.reached_on) as num,
         count(p.id) as den,
         percentile_cont(0.5) within group (order by r.reached_on - p.started_on) as median_days
  from stages s
  cross join params pr
  left join real_pairs p on p.started_on + s.threshold <= pr.today
  left join lateral (
    select n.date_local as reached_on from nth_both n where n.pair_id = p.id and n.k = s.threshold
  ) r on true
  group by s.stage, s.name, s.threshold
),

-- 付録: North Star = 週あたりのふたり達成日数(月曜始まりの直近8週。今週は昨日まで)
weekly as (
  select w.week_start,
         count(b.date_local) as num,
         count(distinct b.pair_id) as den
  from (
    select generate_series(
             date_trunc('week', pr.today::timestamp) - interval '49 days',
             date_trunc('week', pr.today::timestamp),
             interval '7 days')::date as week_start
    from params pr
  ) w
  left join both_days b on b.date_local >= w.week_start and b.date_local < w.week_start + 7
  group by w.week_start
)

-- 結果: 1行 = 1指標。num / den = rate の分子 / 分母(den が小さいうちは率より num / den を読む)
select metric, meaning, num, den,
       round(num::numeric / nullif(den, 0), 3) as rate,
       round(median_days::numeric, 1) as median_days
from (
  select 0 as ord, 'as_of' as metric,
         to_char(today, 'YYYY-MM-DD') || '(JST)' || case when include_test then '・テストデータを含む' else '' end as meaning,
         null::bigint as num, null::bigint as den, null::double precision as median_days
  from params
  union all
  select 100 + n, 'd' || n || '_both',
         '成立から' || n || '日目ごろに、ふたり達成日があったペア', num, den, null
  from retention
  union all
  select 200, 'invite_accepted', '期限が切れたか使われた招待のうち、受諾された招待', num, den, null from invites_resolved
  union all
  select 210, 'paired_within_7d', '作成から7日以上たったユーザーのうち、7日以内にペアが成立した人', num, den, null from paired_within_7d
  union all
  select 220, 'nudge_checkin_2h', '2時間以上たったつつきのうち、相手が2時間以内にチェックインしたもの', num, den, null from nudge_result
  union all
  select 230, 'plant_named', '最初のふたり達成から3日以上たったペアのうち、植物に名前が付いたペア', num, den, null from naming
  union all
  select 300 + stage, 'stage_' || stage || '_' || name,
         name || '(' || threshold || '回)に届いたペア', num, den, median_days
  from reach
  union all
  select 400 + ((select today from params) - week_start) / 7, 'both_days_week:' || week_start,
         'その週のふたり達成日の合計(ペア×日)。den = 達成日のあったペア数', num, den, null
  from weekly
) t
order by ord;
```

## 4. 指標の定義と目標

| KPI | 出力の行(`metric`) | 数えるもの | 母数に入る条件 | 目標(仮) |
|---|---|---|---|---|
| **両者継続**(D1・D7・D30) | `d1_both` `d7_both` `d30_both` | 成立日 d0(`pairs.started_on`)の d0+n−2〜d0+n の 3 日間に、ふたり達成日(`streak_days.kind = 'both'`)が 1 日以上あるペア。1 日休んだだけのペアを離脱と数えないための 3 日の窓(REQUIREMENTS §7)。D1 の窓は d0−1〜d0+1 だが d0−1 には行が無いので、実質 d0〜d0+1 | d0+n が確定済み(昨日以前) = `started_on + n + 1 <= 今日(JST)`。解消済みのペアも入る | **D7: G3 の 1 週間後に 10 ペア中 5 ペア以上**(TASKPLAN §5)= 50% 以上(GROWTH §10.1)/ D30: 25% 以上(リリース + 1 か月) |
| **ペア成立率** | `invite_accepted`(主) | 期限が切れたか使われた招待のうち、使われた(`invites.used_at` あり)招待 = 招待 → ペア成立(REQUIREMENTS §7 の `invite_sent` → `invite_accepted`) | 結果が決まった招待(`used_at` あり、または `expires_at` を過ぎた)。有効期限(72 時間)内で未使用の招待は入らない。招待単位の率なので、1 人が招待を作り直すと母数が増える | 40%(リリース + 1 か月。TASKPLAN §5) |
| | `paired_within_7d`(補助) | 作成から 7 日以上たったユーザーのうち、作成から 7 日以内にペアに入った(`pair_members.joined_at`)人。招待した側と受けた側の両方 = 「アプリを使い始めた人のうち、相手とつながれた人」 | 作成から 7 日以上たったユーザー。users の行はオンボのニックネーム送信で匿名サインインしたときにできる(DESIGN §3.3)ので、オンボの途中で離れた人は入らない | — |
| **つつき → 2 時間以内のチェックイン率** | `nudge_checkin_2h` | つつき(`nudges`)のうち、ペアの相手(送り手以外の所属者)の `checkins.created_at` が、つつきの後 2 時間以内にあるもの。相手が未完のときだけつつけるので(DESIGN §5.3 nudge)、その後のチェックインはつつきの後のものになる | 2 時間以上たったつつき。つつき単位の率(1 日 3 回まで送れる)。取消(checkin-cancel)で行が消えた分は数えない | このアプリの存在価値を示すコア指標(REQUIREMENTS §3.7)。上がっていくこと |
| **名前付け率** | `plant_named` | `plants.name` が入っているペア(plant-name が書く — DESIGN §5.3)。名前を付ける機会は、最初のふたばの演出と、ホームの「名前をつける」ボタン | 最初のふたり達成日(= ふたばに届いた日)から 3 日以上たったペア。名前を付けた時刻は DB に無いので、「何日で付いたか」は出せない | 80%(GROWTH §10.2) |
| **段階到達率** | `stage_1_ふたば` 〜 `stage_9_みのり` | ふたり達成日が threshold 回以上あるペア(お休みチケットの日は数えない — REQUIREMENTS §3.9)と、成立日から threshold 回目のふたり達成日までの日数の中央値(`median_days`) | 成立から threshold 日以上たったペア(それより前には、threshold 回に届けない)。段階 0(たね)は成立の時点で全員が届くので出さない | 目標なし。止まる区間の見つけ方と、閾値を動かす判断は GROWTH §10.4 |
| (付録)**North Star** | `both_days_week:<その週の月曜の日付>` | 週あたりのふたり達成日数。`num` = その週のふたり達成日の合計(ペア × 日)、`den` = 達成日のあったペア数、`rate` = 1 ペアあたりの週の達成日数(最大 7) | 直近 8 週。今週は昨日まで | 増えていくこと(REQUIREMENTS §7) |

- 段階の閾値(`stages`)は snapshot の `PLANT_STAGE_THRESHOLDS = [0,1,3,7,14,21,30,45,66,100]`(DESIGN §5.4)と同じ。閾値を変えるとき(GROWTH §3.6: 下げる方向だけ)は、この SQL の `stages` も一緒に直す
- GROWTH §10.2 の残りの指標(最初のふたば・1 週目のふたり達成の回数・戻ってくる率・あとからやった人の完了率)や、§10.3 の見張る指標(ペアの解消率・つつきの上限まで使った割合)は、必要になったら足す。この SQL の `real_pairs` と `both_days` から書ける

## 5. 動作確認と、ペア別の経過

### 5.1 テストデータの除外(OPS.md §8 との同期)

`test_users` は OPS.md §8「KPI の SQL から除く」の一覧と**同じ**もの。台帳にテストユーザーを足したら、OPS.md と本書の**両方**を直す。食い違いは次で分かる(差が出なければ「一致」と表示される):

```bash
ids() { grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | sort -u; }
first_sql() { awk '/^```sql$/{n++; f=(n==1); next} /^```$/{f=0} f'; }
diff <(awk '/^### KPI の SQL から除く/{f=1} f' products/lien/scripts/OPS.md | first_sql | ids) \
     <(first_sql < docs/KPI.md | ids) && echo "test_users は OPS.md §8 と一致"
```

### 5.2 SQL そのものを確かめる(`include_test`)

実ユーザーがいないあいだは、除外すると全部 0 になって、SQL が正しいか分からない。先頭の `false as include_test` を `true` にして流すと、テストデータも数えて全指標が出る(`as_of` の行に「テストデータを含む」と出る)。数字が合うかは、別の素朴な SQL(`select count(*) from public.nudges …` など)と突き合わせる。**確かめたあとは false に戻す**(テストデータの数字を実績として記録しない)。

### 5.3 ペア別の経過(最後の `select` の代わりに)

G3 は 5〜10 ペアなので、率より個別の経過を読むほうが役に立つ。§3 の `-- 結果:` 以降の `select` を、次に差し替えて流す。**結果にペア ID が出る**ので、JOURNAL・issue には貼らない。

```sql
-- ペア別の経過(最後の select の代わりに使う)
select p.id as pair_id, p.started_on, p.status,
       (select today from params) - p.started_on as days_since_start,
       count(s.date_local) filter (where s.kind = 'both') as both_days,
       count(s.date_local) filter (where s.kind = 'ticket') as ticket_days,
       max(s.date_local) filter (where s.kind = 'both') as last_both_day,
       coalesce(bool_or(pl.name is not null and pl.name <> ''), false) as named
from real_pairs p
left join public.streak_days s on s.pair_id = p.id
left join public.plants pl on pl.pair_id = p.id
group by p.id, p.started_on, p.status
order by p.started_on, p.id;
```

### 5.4 検証の記録(2026-10-13・issue #69)

すべて本番に対して、`set transaction read only` のもとで流した(書き込みなし)。

1. **除外**: OPS.md §8 の台帳が、そのときの本番の users・pairs を過不足なく覆っていた(台帳に無い users も、台帳のユーザーと実ユーザーが混ざったペアも無し)。除外すると、全指標の母数が 0 になった
2. **`include_test`**: true にして全指標が実行できること、招待・つつき・ふたり達成日のあるペア数・名前の付いた植物を、別の素朴な `count(*)` の結果と照らして矛盾しないことを確かめた
3. **合成データ**: 本番のテーブルを同名の CTE(`values` の合成データ)で差し替えて(`public.` を外し、先頭に `users`・`pairs`・`pair_members`・`streak_days`・`checkins`・`nudges`・`invites`・`plants` の CTE を足す。本番には書き込まない)、手で数えた期待値と、`include_test` の false / true の両方で全指標が一致した。境目として確かめたもの: ちょうど成熟する日(D7 は `started_on` が今日 − 8 日のペアを含み、今日 − 7 日を含まない)/ 解消済みのペアが母数に入ること / お休みチケットの日が両者継続にも段階にも数えられないこと / 窓(d0+5〜d0+7)の外のふたり達成日 / 2 時間を超えたつつき・2 時間未満のつつきを母数に入れないこと・送り手自身のチェックインを数えないこと / 有効期限内で未使用の招待を母数に入れないこと / 名前が空文字のペア・最初のふたり達成からちょうど 3 日のペア / 台帳のユーザーのペアが `include_test` で入る・入らないこと / 段階に届くまでの日数の中央値

SQL を変えたときは、3 と同じ方法でやり直す。

## 6. 変更するとき

- 指標を足す・直すときは、REQUIREMENTS §7 の表(指標 → データ源)と本書の §4 を一緒に直す
- テストデータが増えたら OPS.md §8 の表と一覧 → 本書の `test_users`(§5.1 の差分で確かめる)
- 段階の閾値を動かしたら `stages`(§4)
- v1.1 の課金の指標は、課金の導入時に決める(REQUIREMENTS §7 の「収益」の行)
