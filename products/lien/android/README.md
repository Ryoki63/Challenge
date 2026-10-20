# Lien Android — empty native app

Kotlin + Jetpack Compose の最小 Android 足場です。日本語の静的な Lien
プレースホルダーだけを表示します。ネットワーク権限・通信処理・FCM・認証・
ウィジェット・Supabase・RevenueCat は含みません。
`com.example.lien` は開発用の仮 ID で、ストア公開用 ID ではありません。

## 固定バージョン

| 項目 | バージョン |
| --- | --- |
| JDK | Eclipse Temurin 17.0.18+8 |
| Gradle / wrapper | 8.13 |
| Android Gradle Plugin | 8.11.1 |
| Kotlin / Compose compiler plugin | 2.2.20 |
| Compose BOM | 2025.09.01 |
| Activity Compose | 1.11.0 |
| JUnit | 4.13.2 |
| compileSdk / targetSdk / minSdk | 36 / 36 / 26 |
| Android SDK Build Tools | 35.0.0 |

AGP 8.11.1 は Kotlin 2.2.20 の公式な互換範囲内であり、API 36・Gradle 8.13・
JDK 17 に対応します。BOM 管理の Compose ライブラリは BOM の固定バージョンで解決し、
動的バージョンや `+` は使いません。

## ローカル準備

既に利用条件が承認された SDK と JDK 17 を用意してください。このプロジェクトは
SDK のダウンロードやライセンス自動受諾を行いません。新たな利用条件への同意が
必要な場合は、所有者の判断が必要です。Android Studio・エミュレーターはビルドに不要です。

次はリポジトリのルートから実行します。JDK と SDK を `.local/jdk` と `.local/sdk` に
配置済みとし、JDK は `bin/java` のあるディレクトリを指定します。macOS の JDK バンドルでは
`.local/jdk/Contents/Home` に読み替えてください。SDK には `platforms/android-36`、
`build-tools/35.0.0`、既に承認済みの `licenses` が必要です。

```bash
cd products/lien/android
mkdir -p .local/{home,gradle,android-user,cache,tmp}
export JAVA_HOME="$PWD/.local/jdk"
export ANDROID_HOME="$PWD/.local/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export HOME="$PWD/.local/home"
export GRADLE_USER_HOME="$PWD/.local/gradle"
export ANDROID_USER_HOME="$PWD/.local/android-user"
export XDG_CACHE_HOME="$PWD/.local/cache"
export TMPDIR="$PWD/.local/tmp"
export JAVA_TOOL_OPTIONS="-Duser.home=$HOME -Djava.io.tmpdir=$TMPDIR"
export PATH="$JAVA_HOME/bin:$PATH"

./gradlew --no-daemon --console=plain --version
./gradlew --no-daemon --console=plain assembleDebug testDebugUnitTest lintDebug
```

Windows の場合は `gradlew.bat` を使用し、同じ環境変数を設定してください。
Gradle・Maven の公開依存関係の初回取得にはネット接続が必要です。
秘密情報、アカウント、`.env`、公開・本番用資格情報は不要です。
通常の Android debug キーだけが隔離した Android user home に生成されます。
リリース署名・配信・ストア提出は設定していません。

## 検証と出力

- `assembleDebug`: Compose UI を含むアプリをコンパイルし APK を生成。
- `testDebugUnitTest`: 実際の UI が参照する `PlaceholderContent` の日本語3項目を JUnit で検証。
- `lintDebug`: warning もエラーとして扱い、baseline や lint 抑止は使用しません。
- APK: `app/build/outputs/apk/debug/app-debug.apk`
- JUnit XML: `app/build/test-results/testDebugUnitTest/`
- Unit test HTML: `app/build/reports/tests/testDebugUnitTest/index.html`
- Lint: `app/build/reports/lint-results-debug.html` / `.xml`

エミュレーター・実機・Compose instrumentation test は実施対象外です。
JUnit は文字列モデルだけを検証し、画面の描画・日本語フォント・余白・タップ操作を
検証するものではありません。実機表示・製品機能の実装は後続タスクです。

## CI

`.github/workflows/lien-android.yml` は Android ディレクトリと同 workflow の変更だけで
push / pull request 時に起動し、手動起動にも対応します。ubuntu-24.04、commit SHA 固定の
公式 GitHub Actions、JDK 17 を使い、上記の3タスクを実行します。
runner の既載 SDK / 既存ライセンスだけを `.local/sdk` にコピーし、SDK や承認済み
ライセンスが無ければ受諾せずに失敗します。`sdkmanager --licenses` は実行しません。
同時実行グループは `lien-android-*` で iOS とは独立しています。
APK と test / lint レポートを artifact として7日間保存します。

## Wrapper の由来・検証

`gradlew`、`gradlew.bat`、`gradle/wrapper/gradle-wrapper.jar` は Gradle 公式
`gradle/gradle` リポジトリの `v8.13.0` から取得した未改変ファイルです。
JAR は公式 checksum と照合済みで、CI でも同じハッシュを照合します。

```text
Gradle 8.13 bin ZIP SHA-256:
20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78

Gradle 8.13 wrapper JAR SHA-256:
81a82aaea5abcc8ff68b3dfcb58b3c3c429378efd98e7433460610fecd7ae45f
```

配布 ZIP は wrapper の `distributionSha256Sum` でも検証されます。

## 公式資料

- AGP 8.11 / 8.11.1: <https://developer.android.com/build/releases/agp-8-11-0-release-notes>
- Kotlin / AGP / Gradle 互換表: <https://kotlinlang.org/docs/gradle-configure-project.html>
- Compose BOM: <https://developer.android.com/develop/ui/compose/bom>
- BOM 2025.09.01 の正本: <https://dl.google.com/dl/android/maven2/androidx/compose/compose-bom/2025.09.01/compose-bom-2025.09.01.pom>
- Gradle checksums: <https://gradle.org/release-checksums/>
- Wrapper ソース: <https://github.com/gradle/gradle/tree/v8.13.0/gradle/wrapper>
- Ubuntu runner SDK 一覧: <https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md>
