-- ============================================================================
-- Lien migration 0002_photo_storage_policies
--
-- 正本:
--   - 写真アップロード経路(署名付きアップロードURL方式): docs/DESIGN.md §5.6(issue #48 決定)
--   - パス規約: photos バケット内 'pairs/<pair_id>/<date_local>/photo.jpg' /
--     'photo_thumb.jpg'(原寸とサムネの2オブジェクト。サムネは NSE 用 200KB 上限)
--   - バケット定義と select ポリシー(防波堤)は 0001_init.sql §6 で作成済み
--
-- このマイグレーションの役割(DESIGN §5.6「必要な storage ポリシー追記は migration 0002」):
--   * 0001 では「アップロード経路が未決」だったため insert/update を既定 deny にしていた。
--     #48 で署名付きアップロードURL方式に決定したので、書き込みポリシーをここで追加する
--   * 主経路: checkin Function(service_role)が createSignedUploadUrl を発行し、
--     クライアントが署名トークン付きでアップロードする。service_role は RLS をバイパス
--     するため、署名URLの発行自体にポリシーは不要
--   * 下記の insert/update ポリシーは防波堤(0001 §6 の select と同じ考え方):
--     Storage API が署名付きアップロードをユーザーコンテキストで RLS 評価する実装でも
--     「現役ペアのメンバーが、自分のペアのフォルダに、規約どおりのファイル名で」
--     以外のアップロードは DB 層で必ず拒否される。逆に RLS が評価されない実装でも
--     本ポリシーが許可範囲を広げることはない(署名URLの実挙動の最終確認は G0 後 — issue #14)
--   * update ポリシーは同日の写真差し替え(upsert — DESIGN §5.6 / REQUIREMENTS §3.4
--     「その日1枚」の貼り直し)に必要
--   * delete はクライアントに許さない(既定 deny のまま。チェックイン取消時も写真実体の
--     掃除はサーバー側の将来課題とし、署名URLを発行しない限り見えない — DESIGN §5.7-3 と同方針)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. パス規約の検査関数
--    'pairs/<pair_id(uuid)>/<date_local(YYYY-MM-DD)>/photo.jpg | photo_thumb.jpg'
--    に厳密一致し、かつ呼び出しユーザーがその pair の「現役(active)」メンバーで
--    あるときのみ true。
--    * uuid キャスト前に正規表現で形式検査(0001 §6 の select ポリシーと同じ守り)。
--      SQL の and は評価順序を保証しないため、case で形式検査 → キャストの順を強制する
--    * 日付セグメントは形式のみ検査する(「今日」かどうかはサーバー時計とユーザーTZの
--      ずれがあるため DB では縛らない。日付の妥当性は checkin Function 側のガードが担う)
--    * is_active_pair_member(0001 §2)を使う = ペア解消後は双方とも書けない
-- ----------------------------------------------------------------------------
create or replace function public.is_valid_pair_photo_upload(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when array_length(storage.foldername(p_name), 1) = 3
     and (storage.foldername(p_name))[1] = 'pairs'
     and (storage.foldername(p_name))[2]
           ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and (storage.foldername(p_name))[3] ~ '^\d{4}-\d{2}-\d{2}$'
     and storage.filename(p_name) in ('photo.jpg', 'photo_thumb.jpg')
    then public.is_active_pair_member(((storage.foldername(p_name))[2])::uuid)
    else false
  end;
$$;

-- helper の実行権限: クライアント(authenticated)のみ。anon には渡さない(0001 §2 と同方針)
revoke execute on function public.is_valid_pair_photo_upload(text) from public, anon;
grant  execute on function public.is_valid_pair_photo_upload(text) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. storage.objects の書き込みポリシー
-- ----------------------------------------------------------------------------

-- アップロード(新規): 現役ペアのメンバーが自分のペアのフォルダに規約どおりの
-- ファイル名で置く場合のみ
create policy photos_insert_pair_member on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'photos'
    and public.is_valid_pair_photo_upload(name)
  );

-- 差し替え(同日 upsert — DESIGN §5.6): 対象・結果の両方が規約に収まる場合のみ
create policy photos_update_pair_member on storage.objects
  for update to authenticated
  using (
    bucket_id = 'photos'
    and public.is_valid_pair_photo_upload(name)
  )
  with check (
    bucket_id = 'photos'
    and public.is_valid_pair_photo_upload(name)
  );
