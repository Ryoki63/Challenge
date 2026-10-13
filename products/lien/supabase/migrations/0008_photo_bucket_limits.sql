-- ============================================================================
-- Lien migration 0008_photo_bucket_limits
--
-- 正本:
--   - 写真の Storage: docs/DESIGN.md §5.2(写真のパスと書き込みの条件)/ §5.6(アップロード経路)
--   - 背景: issue #68(写真の実体の扱い)/ 承認: D4(2026-10-12 ユーザー「全部推奨で」。追加系の migration)
--
-- 問題:
--   photos バケットには、ファイルサイズの上限も許可する MIME タイプも設定されていなかった
--   (file_size_limit = null・allowed_mime_types = null)。署名付きアップロード URL を持つ人(ペアのメンバー)は、
--   巨大なファイルや JPEG 以外の任意のファイルを、自分の区画に置けた。置けるのは自分の区画だけだが、
--   無制限のアップロードは、保存量・相手の端末のメモリ・NSE の通知の予算(サムネ)を荒らせる。
--
-- 変更:
--   file_size_limit    = 6 MiB = 6291456 バイト
--   allowed_mime_types = {image/jpeg}
--
-- 値の根拠(アプリの上限と整合させる):
--   * 6 MiB: アプリが作る原寸は長辺 2048px・JPEG 品質 0.85(PhotoProcessor)で、実際は数百 KB〜数 MB。
--     アプリが受け取る原寸の上限は 6 MiB(PartnerPhotoLimits.original)で、これを超えるファイルは相手のアプリが
--     表示できない(tooLarge → 植物だけに戻る)。置けても意味がないので、バケットの上限をそこにそろえる。
--     サムネ(photo_thumb.jpg)の実際の大きさは 200KB 以下(PhotoProcessor.thumbMaxBytes。NSE の予算)で、アプリが
--     受け取る上限は 512KB(PartnerPhotoLimits.thumbnail)。ただしバケットの上限は 1 つしか持てず、ファイル名ごとには
--     分けられないので、サムネにも 6 MiB がかかる。サムネの小ささは、クライアント側の縮小と、受け取り側の打ち切り
--     (512KB)が担う。署名付きアップロードは RLS を通らない(Function が本人の区画にだけ URL を発行する)ので、
--     ポリシーでファイルごとの大きさを縛る道もない
--   * image/jpeg: 原寸もサムネも JPEG(PhotoProcessor は UTType.jpeg で書き出す)。アップロードの Content-Type も
--     image/jpeg(CheckinAPIClient.uploadPhoto)。パスの拡張子も .jpg だけ(0004 の is_valid_own_photo_upload)
--
-- 方針: 追加系のみ(バケットの 2 列の更新)。既存のオブジェクトには触れない(上限を超える既存のオブジェクトは残る。
--   制限はこれからのアップロードに効く)。べき等(何度流しても同じ結果)。バケットが無ければ例外にして止める
--   (0001 §6 が未適用の環境に、黙って何もしないまま「適用済み」と記録しない)。
--   storage.buckets の所有者は supabase_storage_admin だが、postgres ロールから更新できる(0001 の insert と同じ)。
-- ============================================================================

do $$
begin
  update storage.buckets
     set file_size_limit    = 6291456,
         allowed_mime_types = array['image/jpeg']
   where id = 'photos';
  if not found then
    raise exception 'photos バケットが無い(0001_init.sql の §6 が未適用?)';
  end if;
end
$$;
