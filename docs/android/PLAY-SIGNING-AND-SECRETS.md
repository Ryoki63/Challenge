# Play App Signing・アップロード鍵・GitHub Secrets

- 対象: Lien Android v1.0（APP-001）/ Issue #124 / 作成: 2026-10-21 JST / 担当: ops-lead
- 目的: **アプリ署名鍵とアップロード鍵を混同せず**、CI から Play の内部テストトラックへ安全にアップロードできる状態にする。
- この文書には**値（パスワード・鍵・JSON・トークン）を書かない**。名前と置き場所だけを書く。
- 関連: 登録手順は [PLAY-CONSOLE-SETUP.md](PLAY-CONSOLE-SETUP.md)、申告は [PLAY-DATA-SAFETY.md](PLAY-DATA-SAFETY.md)。

## 1. 鍵のモデル（最初にこれを理解する）

| 鍵 | 誰が持つか | 用途 | 失ったとき |
|---|---|---|---|
| **アプリ署名鍵**（app signing key） | **Google**（Play App Signing） | Google がストア配信用の APK に署名する。利用者の端末が検証する | Google 側で管理。開発者は触らない |
| **アップロード鍵**（upload key） | **オーナー**（バックアップ）と CI（Secret） | CI が AAB に署名して Play にアップロードする。Google が「本人のアップロード」と確認する | Play App Signing の**アップロード鍵リセット**で差し替えられる。アプリの再公開は不要 |
| サービスアカウント鍵（JSON） | オーナー（Secret） | CI が Play Developer API を呼ぶ | Google Cloud で鍵を削除して作り直す。Play のアプリには影響しない |

- **アプリ署名鍵をリポジトリや CI に置かない。** 新規アプリは Play App Signing に自動登録され、Google がアプリ署名鍵を生成・保管する。
- CI が使うのは**アップロード鍵**だけ。アップロード鍵が漏れても、Google に申請すれば差し替えられる（アプリの署名鍵は変わらない）。
- **アップロード鍵とアプリ署名鍵を同じにしない。** 同じにすると、アップロード鍵の漏えいがアプリ署名鍵の漏えいになる。

## 2. アップロード鍵を作る（人間・1回だけ）

JDK の `keytool` を使う。**リポジトリの中では実行しない**（生成物が Git に入らないよう、ホームの作業用ディレクトリなどで行う）。

```bash
# 例: ホームの作業用ディレクトリで実行する。値は自分で決め、この文書には書かない
mkdir -p "$HOME/lien-keys" && chmod 700 "$HOME/lien-keys"
keytool -genkeypair -v \
  -keystore "$HOME/lien-keys/lien-upload.jks" \
  -alias lien-upload \
  -keyalg RSA -keysize 4096 -validity 10000
```

- `-alias` は `lien-upload` を推奨（CI の `ANDROID_UPLOAD_KEY_ALIAS` と一致させる）。
- パスワードはパスワードマネージャで生成し、**オーナーだけが読める場所**に保管する。
- 生成後、`keytool -list -v -keystore ...` で SHA-256 フィンガープリントを確認できる。フィンガープリントは公開情報だが、**パスワードとセットで共有しない**。

### バックアップ（必須）

- パスワードマネージャ（1Password 等）に **keystore ファイルそのもの**とパスワード・alias を保管する。
- 加えて、暗号化したオフラインバックアップを 1 つ作る（暗号化ディスク / 暗号化 ZIP）。**平文で Drive・Dropbox・GitHub に置かない。**
- バックアップから復元できることを、一度だけ別の場所で確認する。復元できないバックアップはバックアップではない。
- オーナーが変わったときは、鍵の引き継ぎを文書化する（このリポジトリには値を書かない）。

## 3. Play Console にアップロード鍵を登録する

1. Play Console → 対象アプリ → **Protected with Play → Play Store distribution → Play app signing**（画面名は変更されることがある）。
2. **Upload key certificate** の欄で、アップロード鍵の証明書（`.der` または `.pem`）をアップロードする。
   - `keytool -export -rfc -keystore lien-upload.jks -alias lien-upload -file lien-upload.pem` で PEM を作れる。
3. 表示される SHA-256 フィンガープリントを、手元の `keytool -list -v` の値と照合する。
4. 初回の AAB をアップロードすると、Play App Signing の登録が完了する。**初回アップロード後にパッケージ名は変えられない。**

> アプリ署名鍵のフィンガープリントは、Google Maps / OAuth / App Links など外部サービスに登録する必要がある。**アップロード鍵のフィンガープリントを外部サービスに登録しない。** 必要な値は Play Console の「App signing key」欄から取る。

### アップロード鍵を失った・漏えたとき

1. **新しいアップロード鍵を作る**（上の手順。別ファイル・別 alias でよい）。
2. Play Console の **Request upload key reset** に、新しい鍵の証明書（PEM）を出して理由を書く。
3. Google の承認後、GitHub Secrets の `ANDROID_UPLOAD_KEYSTORE_BASE64` / `..._PASSWORD` / `..._ALIAS` / `..._KEY_PASSWORD` を新しい値に更新する。
4. **新しいパッケージ名でアプリを作り直さない。** Play App Signing のリセットで同じアプリを続けられる。
5. 漏えいの疑いがあるときは、リセット完了まで CI の `publish` を止める。Play Console の変更履歴（Users and permissions / Releases）を確認する。

## 4. サービスアカウントを作る（人間・1回だけ）

CI が Play Developer API を呼ぶための機械用アカウント。**人間の Google アカウントのパスワードを CI に置かない。**

1. Google Cloud Console で、Play 専用のプロジェクトを作る（例: `lien-play`）。既存の本番プロジェクトと混ぜない。
2. **Google Play Developer API** を有効化する。必要なのは Android Publisher API（`androidpublisher.googleapis.com`）。
3. サービスアカウントを作る（例: `lien-play-ci`）。Cloud IAM のロールは**付けない**（Play の権限は Play Console 側で付ける）。
4. そのサービスアカウントの **JSON 鍵**を作成し、一度だけダウンロードする。**JSON はリポジトリ・Issue・チャットに置かない。**
5. Play Console → **Users and permissions** → **Invite new users** で、サービスアカウントのメールアドレスを招待する。
   - アクセス: **アプリ単位**（Lien のみ）。
   - 権限: **View app information and download bulk reports (read-only)** と **Release apps to testing tracks**。
   - **付けない**: Admin (all permissions)、Release to production、Manage testing tracks（テスター管理は人間が行う）、Manage store presence、Finance。
   - 有効期限を設定できる場合は設定し、期限前に見直す。
6. 招待後、**Users and permissions** にサービスアカウントが表示され、対象アプリの権限が有効になっていることを確認する（サービスアカウントはメールを読めないため、招待メールの承諾は不要）。

> サービスアカウントに Admin を付けると、CI の鍵が漏れたときに本番公開・返金・ユーザー管理まで可能になる。**最小権限を守る。** 本番トラックへのアップロードはこのワークフローでは許可しない（スクリプト側でも拒否する）。

## 5. GitHub Secrets / Variables の名前（値は書かない）

### 5.1 置き場所

- **Environment `play-internal`** を作る（Settings → Environments → New environment）。
  - Required reviewers: オーナー（自分の承認）。
  - Deployment branches: `main` のみ。
  - Secrets は**Environment secrets**として登録する（Repository secrets にしない）。ビルド job からは見えない。
- **Repository variable** `PLAY_PACKAGE_NAME` を置く（Secret ではない）。値は最終的な `applicationId`（推奨: `com.ryoki63.lien`）。**初回アップロード後に変更しない。**

### 5.2 一覧

| 名前 | 種類 | 置き場所 | 用途 | ローテーション |
|---|---|---|---|---|
| `ANDROID_UPLOAD_KEYSTORE_BASE64` | Secret | Environment `play-internal` | アップロード鍵（`.jks`）を base64 にしたもの | 漏えい・紛失時。年1回の確認 |
| `ANDROID_UPLOAD_KEYSTORE_PASSWORD` | Secret | Environment `play-internal` | keystore のパスワード | 同上 |
| `ANDROID_UPLOAD_KEY_ALIAS` | Secret | Environment `play-internal` | 鍵の alias（例: `lien-upload`） | 鍵を作り直したとき |
| `ANDROID_UPLOAD_KEY_PASSWORD` | Secret | Environment `play-internal` | 鍵のパスワード | 同上 |
| `PLAY_SERVICE_ACCOUNT_JSON` | Secret | Environment `play-internal` | サービスアカウントの JSON 鍵（全文） | 90 日ごとを目標、漏えい時は即時 |
| `PLAY_PACKAGE_NAME` | Variable | Repository | 対象アプリの `applicationId` | 変更しない（初回で固定） |

- **値はこのリポジトリのどこにも書かない。** PR・Issue・日報・スクリーンショット・ログにも出さない。
- `gh secret list --env play-internal` は**名前だけ**を表示する。値は表示されない。確認に使ってよい。
- CI のログに `set -x` を入れない。Python スクリプトは token / JSON / パスワードを表示しない。

### 5.3 登録例（値はファイルから読む。コマンド履歴に値を書かない）

```bash
# 例: クリップボード / ファイルから登録する。値そのものをコマンドラインに書かない
gh secret set ANDROID_UPLOAD_KEYSTORE_BASE64 --env play-internal < <(base64 < "$HOME/lien-keys/lien-upload.jks" | tr -d '\n')
gh secret set ANDROID_UPLOAD_KEYSTORE_PASSWORD --env play-internal
gh secret set ANDROID_UPLOAD_KEY_ALIAS --env play-internal
gh secret set ANDROID_UPLOAD_KEY_PASSWORD --env play-internal
gh secret set PLAY_SERVICE_ACCOUNT_JSON --env play-internal < "$HOME/lien-keys/play-service-account.json"

gh variable set PLAY_PACKAGE_NAME --body "com.ryoki63.lien"
```

- `gh secret set` の対話入力は画面に値を表示しない。ファイルからの入力は、そのファイルを後で削除する。
- base64 は macOS の `base64` でも GNU の `base64` でも動く（`tr -d '\n'` で改行を除く）。
- **サービスアカウント JSON を `PLAY_SERVICE_ACCOUNT_JSON` に入れるとき、JSON の改行はそのままでよい**（GitHub Secrets は複数行を扱える）。

## 6. CI の動き（`.github/workflows/lien-play.yml`）

```text
[build job]  secrets なし
  ./gradlew assembleDebug testDebugUnitTest lintDebug bundleRelease
  → 未署名の app-release.aab を artifact に保存

[publish job]  Environment play-internal（オーナー承認） + Secrets
  artifact を取得
  keystore を一時ディレクトリに復元（0600）
  jarsigner で AAB にアップロード鍵の署名を付ける
  Play Developer API: edit 作成 → bundle upload → internal track 更新 → commit
  失敗時は edit を削除（未コミットの変更を残さない）
```

- **ビルド job は Secrets を持たない。** 署名とアップロードは `publish` job だけ。
- `publish` は手動実行（`workflow_dispatch`）で、`publish=true` を明示したときだけ動く。`push` ではアップロードしない。
- トラックは `internal` のみ。`production` / `alpha` / `beta` はスクリプトが拒否する。本番公開は人間が Play Console で行う。
- `publish=false`（既定）はビルド・テストだけ。Secrets が無くても動く。
- **同じ versionCode は再アップロードできない。** Android の `versionCode` を CI の実行ごとに上げる必要がある。雛形側の対応（`-PversionCode` または `LIEN_VERSION_CODE` を読む）は #121 / #145 の残課題。未対応のまま 2 回目を実行すると Play API が拒否する（ワークフローは失敗し、edit は削除する）。

## 7. 検証（値を出さない）

```bash
# keystore の alias と証明書（パスワードを聞かれる。出力に値は出ない）
keytool -list -v -keystore "$HOME/lien-keys/lien-upload.jks" -alias lien-upload

# AAB の署名検証（署名者証明書は公開情報）
jarsigner -verify -verbose -certs app-release.aab

# Secrets の名前だけ確認（値は出ない）
gh secret list --env play-internal
gh variable list | grep PLAY_PACKAGE_NAME

# リポジトリに鍵・JSON が混入していないか（ファイル名だけ）
git ls-files | grep -E '\.(jks|keystore)$|keystore\.properties|play-service-account.*\.json' || echo "no key files tracked"
```

- `keytool` / `jarsigner` は JDK が必要。CI では `actions/setup-java` の Temurin 17 を使う。
- AAB の署名検証で「jar verified」と出ればよい。証明書のフィンガープリントが Play Console のアップロード鍵と一致することを確認する。

## 8. インシデント時の手順（MTTR を短くする）

| 事象 | 一次対応 | 復旧 | 再発防止 |
|---|---|---|---|
| アップロード鍵の漏えい疑い | CI の `publish` を停止。Play Console のアップロード鍵をリセット | 新しい鍵を生成 → 証明書を提出 → Secrets 更新 → 内部テストで 1 回アップロード | 鍵の置き場所を 1 か所に限定。四半期ごとにアクセス確認 |
| サービスアカウント鍵の漏えい疑い | Google Cloud で該当鍵を削除。Play Console のユーザー一覧を確認 | 新しい JSON 鍵を作成 → Secret 更新 → `publish=false` で認証確認 → `publish=true` | 90 日ごとの鍵ローテーション。Admin を付けない |
| Play API が 401 / 403 | サービスアカウントの招待・権限・API 有効化を確認 | 権限を「Release apps to testing tracks」に戻す。JSON を再発行 | 変更履歴を確認し、権限変更を記録 |
| `versionCode already used` | ビルドの versionCode を確認 | versionCode を上げて再実行 | CI で実行番号を versionCode に反映する（#121 / #145） |
| AAB の署名が違う | `jarsigner -verify` と Play Console の証明書を照合 | 正しいアップロード鍵で再署名 | Secrets の取り違えをチェックリスト化 |

- インシデントの記録には**顧客の個人情報・鍵・トークンを書かない**。時刻（Asia/Tokyo）・影響（内部テストのみ / 本番なし）・原因・復旧・再発防止だけを書く。
- 本番公開・ストア申請・課金・契約は、この文書の範囲外。必要なら判断カードと人間の承認を先に取る。

## 9. 根拠（2026-10-21 に確認）

- Play App Signing の鍵モデル・アップロード鍵リセット: [Use Play App Signing](https://support.google.com/googleplay/android-developer/answer/9842756?hl=en)
- サービスアカウントの作成と Play Console への招待: [Getting Started | Google Play Developer API](https://developers.google.com/android-publisher/getting_started)
- Play Console の権限（Release apps to testing tracks）: [Add developer account users and manage permissions](https://support.google.com/googleplay/android-developer/answer/9844686?hl=en)
- Android Publisher API の edit / bundle upload / track: [Edits](https://developers.google.com/android-publisher/edits) / [edits.bundles.upload](https://developers.google.com/android-publisher/api-ref/rest/v3/edits.bundles/upload) / [APKs and Tracks](https://developers.google.com/android-publisher/tracks)
