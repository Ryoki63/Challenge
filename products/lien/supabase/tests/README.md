# RLS 認可境界テスト（合成データ）

`auth_boundaries.test.ts` は、Lien の Supabase migration が定義する Row Level Security
（RLS）を、ローカルの PGlite（WASM の PostgreSQL）上で実行する試験です。外部の
Supabase・本番 DB・実在の利用者データには接続しません。

## 実行

リポジトリ根から:

```sh
deno test --allow-read --allow-net products/lien/supabase/tests/
```

`--allow-read` は migration の SQL を読むため、`--allow-net` は PGlite を npm から
取得するために必要です。初回は `npm:@electric-sql/pglite@0.5.10` の取得が走ります。

## 何を実物で、何を模擬しているか

| 部分 | 試験での扱い |
|---|---|
| `public.*` のテーブル・RLS ポリシー・helper 関数 | `products/lien/supabase/migrations/0001_init.sql` の実物を適用 |
| 写真の Storage ポリシー | `0002_photo_storage_policies.sql` / `0004_photo_path_per_user.sql` の実物を適用 |
| `auth.users` / `auth.uid()` | 最小モック。`auth.uid()` は `request.jwt.claim.sub` を返す（JWT の `sub` と同じ値）。本番実装が `request.jwt.claims`（JSON）も読む点は差として残る |
| `storage.objects` / `storage.foldername()` / `storage.filename()` | 最小モック。`foldername` は「最後のセグメントを除く配列」で、スラッシュ無しなら空配列を返す本番寄りの実装。先頭スラッシュの扱いなど完全一致ではない |
| `authenticated` / `anon` ロール | 実ロール名を再現。`authenticated` は Storage の CRUD と public の SELECT（users は列限定 UPDATE）を GRANT。`anon` は migration 0001 の REVOKE を再現した「GRANT なし」と、default privileges を模した「GRANT あり」の両方を試す |
| 利用者・約束・履歴・写真 | すべて合成 UUID・合成文字列。実在の利用者・認証情報・本番データは使わない |

### 適用する migration の範囲

| migration | 適用 | 理由 |
|---|---|---|
| `0001_init.sql` | する | 全テーブル・RLS・helper 関数の正本 |
| `0002_photo_storage_policies.sql` | する | 写真の INSERT/UPDATE ポリシー |
| `0003_cron.sql` | しない | `pg_cron` / `pg_net` / Vault が必要。公開テーブルの RLS は変えない |
| `0004_photo_path_per_user.sql` | する | 写真パスの本人区画ルール（本試験の主対象） |
| `0005_push_env.sql` | しない | `users.push_env` の追加と列限定 GRANT のみ。本試験が使う `nickname` の GRANT と users の RLS は変えない |
| `0006_ticket_grant_runs.sql` | しない | 新規のサーバー専用テーブル。クライアント拒否（REVOKE）は本試験で未確認 |
| `0007_cron_secret.sql` | しない | Vault / cron の認証変更。公開テーブルの RLS を変えない |
| `0008_photo_bucket_limits.sql` | しない | バケットのサイズ・MIME 設定。RLS の可視範囲を変えない |

`0003` / `0007` は PGlite に無い拡張・Vault に依存するため、適用すると試験自体が
成立しません。適用しない migration が**既存の RLS を変えない**ことは、各ファイルの
変更内容（列追加・新規サーバーテーブル・cron 設定・バケット設定）で確認しています。
新規テーブル（0006）や追加列（0005）を対象にする試験は本ファイルの範囲外です。

## 受入条件との対応

| 受入条件 | 試験ステップ | 確認内容 |
|---|---|---|
| ① 別ペアのアクセス拒否 | 「別ペアの約束・履歴・リアクション・写真は返らない」 | C から見える `users` / `pairs` / `pair_members` / `promises` / `checkins` / `reactions` / `streak_days` / `ticket_ledger` / `nudges` / `plants` / `invites` / `storage.objects` を全件比較し、AB の行が 1 行も混ざらない |
| ① 未認証のアクセス拒否 | 「未認証ロールは GRANT でも RLS でも拒否される」 | `anon` で 12 の資源を SELECT し、すべて SQLSTATE `42501` で拒否。`anon` の promises INSERT / 写真 INSERT も `42501`。さらに `anon` に SELECT を GRANT した状態でも、anon 向けポリシーが無いため 12/12 が 0 行 |
| ① 削除済み利用者のアクセス拒否 | 「削除済み利用者の stale subject にはデータが返らない」 | `auth.users` を消した後も同じ `sub` で SELECT し、確認した 7 資源（users / pairs / pair_members / promises / checkins / reactions / storage.objects）が空。所属行は cascade で消え、残った写真オブジェクトにも RLS が行を返さない |
| ② 拒否結果だけでなく他者データが返らない | 上記＋「ペア解消後は元相手のデータと写真が返らない」＋「書き込み境界」 | 拒否（SQLSTATE 付き）だけでなく、返る行の集合を期待値と完全一致で比較。解消後は本人分とペアスコープのアーカイブだけが残る。書き込みは他者行の UPDATE が 0 行、INSERT/DELETE が `42501`、`premium_until` の自己更新が `42501`、Storage の他者区画・旧形式パスが `42501`、相手区画の UPDATE が 0 行 |
| ③ 既存テストとの重複回避 | 下記「既存テストとの差分」 | 既存の `functions/**/*_test.ts` は純粋ロジックと fake repo の試験で、migration / RLS を実行しない |
| ④ 環境不足の記録 | 下記「未実施・限界」 | 実施できなかった項目と理由を明記 |

## 既存テストとの差分（重複しない理由）

- `products/lien/supabase/functions/**/*_test.ts` の 27 ファイルは、Edge Function の
  純粋ロジックを fake repo / fake pusher で試験している。SQL の migration や RLS は実行しない
  （`grep -rn "auth.uid\|storage.objects\|policy" --include='*_test.ts'` のヒットは
  `privacy-policy` の語を含むコメントだけ）。
- `delete-account/core_test.ts` は削除順序・冪等性・写真パスの生成を fake repo で確認するが、
  DB の RLS が stale JWT を遮断するかは確認しない。
- `tasks/DONE.md` の T02 に「PGlite 実 DB 検証 50/50」の記録があるが、その試験コードは
  リポジトリに残っていない（`grep -rn PGlite` で当該テスト以外にヒットしない）。
  本ファイルは、その一回限りの検証を再実行可能な回帰試験として残すもので、既存テストの
  重複追加ではない。
- 既存の RLS を主題にしたテストは、本ファイル追加前は 0 件。

## 変異テスト（テストが常に緑でないことの確認）

migration の一時コピーを次の 3 通り壊し、いずれもテストが失敗することを確認しています。

| 変異 | 検出したステップ |
|---|---|
| `promises` の RLS を無効化 | 別ペア（C に全員の約束が見える） |
| 写真の SELECT ポリシーを `bucket_id` だけに拡大 | 別ペア（C に全ペアの写真が見える） |
| `shares_active_pair_with` から `status = 'active'` を外す | ペア解消後（B に A の約束が見える） |

## 未実施・限界（環境不足を含む）

| 未実施の項目 | 理由 | 代替・次の確認 |
|---|---|---|
| Supabase Storage API の署名付き URL 発行・アップロード | ローカルに Supabase Storage / Docker を立てていない。本試験は `storage.objects` の RLS（INSERT/UPDATE/DELETE を含む）のみ | 実 Storage の署名発行は G0 後の dev 環境で確認（`products/lien/scripts/OPS.md` の手順） |
| GoTrue の JWT 期限切れ・リフレッシュ・失効 | Auth サービスを起動しない。削除済み利用者は「`auth.users` 削除後も同じ `sub` の JWT が残る」状況を GUC で模擬 | 実 JWT の期限切れは Auth の仕様。本試験では、auth.users 削除による所属行の cascade 削除と、残存写真に対する RLS の両方で行が返らないことを確認 |
| マネージド Supabase の PostgreSQL バージョン・拡張・default privileges | PGlite（PostgreSQL 18）で実行。`pgcrypto` は使わず `gen_random_uuid()` で代替。`anon` の GRANT あり/なしは両方試すが、実プロジェクトの default privileges そのものではない | 本番の migration 適用時に `supabase db lint` / dev 環境で再確認 |
| `service_role`（BYPASSRLS）の動作 | クライアント境界の試験ではないため | Edge Function の統合試験（`supabase functions serve`）で確認 |
| 公開関数（RPC）の実行権限 | `grant execute` 済みの security definer 関数をクライアントが直接呼ぶ経路は未試験 | 必要なら関数ごとの拒否試験を追加 |
| `0006_ticket_grant_runs` のクライアント拒否 | 新規のサーバー専用テーブルで、本試験の対象外。REVOKE の回帰は未確認 | 必要なら `anon` / `authenticated` の SELECT 拒否を追加 |
| iOS アプリ・実機・ネットワーク越しの動作 | 本試験は DB 層のみ | 実機 E2E は #105 の手順、審査提出は #115 |
| 同時実行・トランザクション分離 | 単一接続の逐次実行。1 つの `Deno.test` 内で状態を変えながら 6 ステップ進むため、前段の失敗は後段に波及し得る | 必要ならテストごとに DB を作り直す分離版を追加 |
| 削除済み利用者の写真実体の削除 | `delete-account` Function を実行しない。本番は「ペア解消 → 写真削除 → auth 削除」だが、stale JWT の RLS を確かめるため、この試験では auth を先に消して写真を残す（本番順序とは異なる） | `delete-account/core_test.ts` が削除順序を、本試験が RLS を担当 |

## 既知の欠陥 #151（この試験の合格扱いにしない）

`reactions_select_pair` は `from_user` だけで可視範囲を決めている。このため、現役ペアの
相手が過去に別ペアのチェックインへ送ったリアクション行は、`checkin_id` と `stamp` を含めて
読める（別ペアのチェックイン本体は読めない）。

- 欠陥: [Ryoki63/Challenge#151](https://github.com/Ryoki63/Challenge/issues/151)
- クライアント経路: `products/lien/ios/Lien`（テストを除く）で直接 PostgREST を呼ぶ箇所は
  `users`・`promises`（`Core/SupabaseService.swift`）、`pairs`・`checkins`・`streak_days`
  （`Core/Repositories/HistoryRepository.swift`）、`checkins`（`Core/Api/NudgeReactAPIClient.swift`）。
  `reactions` の直接 SELECT は確認範囲では見つからない。ただし任意の JWT で PostgREST を
  叩けるため、悪意あるクライアントでは再現可能。非ブロッカーの根拠は「チェックイン本文・
  写真・約束が漏れない」ことに置く（画面経路の有無には置かない）。
- 再現: `auth_boundaries.test.ts` の `既知の欠陥 #151` ステップ（`ignore: true`）。
  `ignore` を外すと現在は `actual=[{checkin_id, from_user, stamp}] expected=[]` で失敗する。
- 修正後: このステップの `ignore` を外し、回帰テストとして有効化する。
- 本試験の主系列はこの行を混ぜずに受入条件 ①〜④ を判定し、この所見は Consilium #256 の
  証跡で再現手順付きの欠陥として分離する。
