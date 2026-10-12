-- ============================================================================
-- Lien migration 0004_photo_path_per_user
--
-- 正本:
--   - 写真のパス規約: docs/DESIGN.md §5.2
--   - 背景: docs/REVIEW-2026-10-12.md §2 M6 / 承認: D4(2026-10-12 ユーザー「全部推奨で」)/ issue #52
--
-- 問題:
--   0002 のパス規約 'pairs/<pair_id>/<date_local>/photo.jpg' はペア×日付単位。
--   同じ日に2人が写真を付けると、後の人が前の人の写真を上書きできた
--   (2026-10-12 のスモーク⑧で、パートナーによる同パスへの update が 200 になることを確認)。
--
-- 変更:
--   パスを 'pairs/<pair_id>/<date_local>/<user_id>/photo.jpg' | 'photo_thumb.jpg' に改め、
--   insert / update ポリシーで「パスの user_id 区画 = auth.uid()」を強制する。
--     - 現役(active)ペアのメンバーであること(0002 と同じ)
--     - 他人の user_id 区画へは insert も update もできない
--     - 旧形式 'pairs/<pair_id>/<date_local>/photo.jpg' への新規書き込み・上書きも拒否される
--       (checkin Function が発行するパスは新形式になる。旧形式の写真は読み取りだけ残る)
--   select ポリシー(0001 §6 の photos_select_pair_member)は**変えない**:
--   現役ペアのメンバーは 'pairs/<pair_id>/' 配下を新旧どちらの形式でも読める
--   (既存の旧パスの写真は読めるまま)。ペア解消後は双方とも読めない(0001 の方針のまま)。
--
-- 方針: 追加系のみ。関数を1つ追加し、0002 の2つのポリシーの式を差し替える。
--   テーブル・既存データには触れない。0002 の is_valid_pair_photo_upload は未使用になるが残す
--   (ロールバック時に 0002 のポリシーへ戻せるように。削除しない)。
--
-- 署名付きアップロード(checkin Function が createSignedUploadUrl を発行)との関係:
--   署名URLは Function(service_role)が本人のパスにだけ発行する。下記ポリシーは、
--   クライアントが自分の JWT で storage API を直接叩く経路(他人のパスへの upload / 上書き)を
--   DB 層で塞ぐ防波堤であり、署名URLの実挙動に依存しない。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. パス規約の検査関数(本人の区画のみ)
--    'pairs/<pair_id(uuid)>/<date_local(YYYY-MM-DD)>/<user_id(uuid)>/photo.jpg | photo_thumb.jpg'
--    に厳密一致し、かつ
--      (a) <user_id> が呼び出しユーザー(auth.uid())自身であり、
--      (b) 呼び出しユーザーが <pair_id> の「現役(active)」メンバー
--    のときだけ true。
--    * uuid キャスト前に正規表現で形式検査(0002 と同じ守り)。SQL の and は評価順序を保証しない
--      ため、case で形式検査 → キャストの順を強制する
--    * <user_id> は auth.uid()::text(小文字ハイフン区切り)との完全一致。大文字などは拒否
--    * 未ログイン(auth.uid() が null)は比較が null になり、else の false になる
--    * 日付区画は形式のみ検査する(0002 と同じ。日付の妥当性は checkin Function のガードが担う)
-- ----------------------------------------------------------------------------
create or replace function public.is_valid_own_photo_upload(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when array_length(storage.foldername(p_name), 1) = 4
     and (storage.foldername(p_name))[1] = 'pairs'
     and (storage.foldername(p_name))[2]
           ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and (storage.foldername(p_name))[3] ~ '^\d{4}-\d{2}-\d{2}$'
     and (storage.foldername(p_name))[4] = (select auth.uid())::text
     and storage.filename(p_name) in ('photo.jpg', 'photo_thumb.jpg')
    then public.is_active_pair_member(((storage.foldername(p_name))[2])::uuid)
    else false
  end;
$$;

-- helper の実行権限: クライアント(authenticated)のみ。anon には渡さない(0001 §2 / 0002 と同方針)
revoke execute on function public.is_valid_own_photo_upload(text) from public, anon;
grant  execute on function public.is_valid_own_photo_upload(text) to authenticated, service_role;

comment on function public.is_valid_pair_photo_upload(text) is
  '0004 以降は未使用(ポリシーは is_valid_own_photo_upload を使う)。ロールバック用に残している';

-- ----------------------------------------------------------------------------
-- 2. storage.objects の書き込みポリシーの式を差し替える(名前は 0002 のまま)
-- ----------------------------------------------------------------------------

-- アップロード(新規): 現役ペアのメンバーが、自分の user_id 区画に、規約どおりのファイル名で置く場合のみ
alter policy photos_insert_pair_member on storage.objects
  with check (
    bucket_id = 'photos'
    and public.is_valid_own_photo_upload(name)
  );

-- 差し替え(同日 upsert — DESIGN §5.6): 対象・結果の両方が「自分の区画」に収まる場合のみ
alter policy photos_update_pair_member on storage.objects
  using (
    bucket_id = 'photos'
    and public.is_valid_own_photo_upload(name)
  )
  with check (
    bucket_id = 'photos'
    and public.is_valid_own_photo_upload(name)
  );
