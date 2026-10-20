# Play API upload script

`publish_play.py` は、署名済みの Android App Bundle（AAB）を Google Play の
**内部テストトラック**へアップロードする。Google API クライアントや外部 action を
足さず、Python 標準ライブラリと `openssl` だけで動く。

- サービスアカウントの JSON 鍵で JWT（RS256）を作り、OAuth2 の access token に交換する。
- Play Developer API の `edits` を作り、AAB をアップロードし、`internal` トラックを更新して commit する。
- 失敗時は edit を削除する（中途半端な変更を残さない）。
- `production` / `alpha` / `beta` は**拒否**する。内部テスト専用。
- 秘密（JSON・token・パスワード）は表示しない。

## 使い方

```bash
python3 products/lien/scripts/play/publish_play.py \
  --service-account /path/to/service-account.json \
  --package com.ryoki63.lien \
  --aab app-release-signed.aab \
  --track internal \
  --status completed \
  --release-notes "Lien Android 内部テスト"
```

認証と権限だけを確認する（アップロードしない）:

```bash
python3 products/lien/scripts/play/publish_play.py \
  --service-account /path/to/service-account.json \
  --package com.ryoki63.lien \
  --aab app-release-signed.aab \
  --dry-run
```

`--dry-run` は edit を作成し、既存の bundle 一覧を表示して edit を削除する。
Play の状態は変えない。

## テスト

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s products/lien/scripts/play -p 'test_*.py' -v
```

テストはネットワークを使わない。RS256 の署名はローカルの `openssl` で検証し、
Play API の呼び出し順はモックで確認する。

## 注意

- `versionCode` は AAB のビルド時に決まる。同じ `versionCode` は再アップロードできない。
- アップロード鍵（`.jks`）とサービスアカウント JSON はリポジトリに置かない。
  名前と置き場所は [docs/android/PLAY-SIGNING-AND-SECRETS.md](../../../../docs/android/PLAY-SIGNING-AND-SECRETS.md) を参照。
- 本番公開はこのスクリプトの範囲外。Play Console で人間が行う。
