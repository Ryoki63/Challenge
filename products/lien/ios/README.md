# Lien iOS(ビルド・設定・リリース)

アプリ本体(SwiftUI)・ウィジェット(WidgetKit)・NSE(Notification Service Extension)。`.xcodeproj` はコミットせず、
`project.yml` から XcodeGen が作る(設計の正本は [docs/DESIGN.md](../../../docs/DESIGN.md) §3)。
このファイルは **TestFlight に上げるための設定と手順**(T28準備 / issue #28)をまとめたもの。

## 1. ツールチェーン(Xcode 26 / iOS 26 SDK に固定)

- 2026-04-28 以降、App Store Connect へのアップロードは **Xcode 26 / iOS 26 SDK 以上**でビルドしたものだけが受け付けられる
- 使う Xcode は **[`.xcode-version`](.xcode-version) の 1 か所**に書く(いまは `26.6`)。`lien-ios`(テスト)と `lien-release`(archive)が同じ版を使う
  - どちらも `runs-on: macos-26`。`scripts/select-xcode.sh` が `/Applications/Xcode_<版>.app` に切り替え、iOS SDK が 26 以上であることを検査する
  - ランナーにある版は [actions/runner-images の macos-26-arm64-Readme.md](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) で確かめる
    (2026-10 時点: 26.0.1〜26.6。macos-15 は 26.3 まで)。版を変えるときは `.xcode-version` だけを直す
  - テストのシミュレータは `iPhone 17`(macos-26 のイメージには iPhone 16 が無い)
- ローカルに Xcode が無い環境でも、構文確認は `swiftc -parse`、リリース用スクリプトの単体テストは
  `python3 -m unittest discover -s scripts -p 'test_*.py'` でできる。ビルド・テストの検証は CI(lien-ios)で行う

```sh
cd products/lien/ios
xcodegen generate
scripts/pin-packages.sh          # Package.resolved を戻して解決(ずれていたら止まる)
xcodebuild test -project Lien.xcodeproj -scheme Lien \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO
```

## 2. Supabase 接続情報(SUPABASE_URL / SUPABASE_ANON_KEY)の入れ方

値は **Info.plist** に入り、`Config.swift` が読む。入れ方は場面ごとに違う:

| 場面 | 入れ方 | 接続情報が無いと |
|---|---|---|
| ローカル Debug(Xcode で実行) | `Config/Secrets.example.xcconfig` を `Config/Secrets.xcconfig` にコピーして実値を書く(gitignore 済み) | **Stub 構成**で動く(ネットワークを使わない。開発・CI 用) |
| ローカル Release / Archive | 同上(`Secrets.xcconfig` が必須) | **起動時に明示エラーで止まる**(`fatalError`。クラッシュログに対処が出る) |
| lien-ios(CI。テスト) | 入れない(Debug) | Stub 構成でテストが通る |
| lien-release(TestFlight 用 archive) | GitHub Secrets の `SUPABASE_URL` / `SUPABASE_ANON_KEY` から `scripts/supabase_config.py write-xcconfig` が `Secrets.xcconfig` を生成(終了時に削除) | 下の「archive の検査」で**アップロード前に失敗**する |

- **Release では黙って Stub に落とさない**(`Config.MissingPolicy`: Debug = `.fallBackToStub` / Release = `.fatal`)。
  接続情報の無いビルドを TestFlight に出すと、誰の端末でもペアになれず原因も分からないため
- `Config.load` は、空文字・雛形のまま(`YOUR-PROJECT-REF` / `YOUR_SUPABASE_ANON_KEY`)・変数が展開されずに残った値(`$(SUPABASE_URL)`)も「未設定」として扱う
- xcconfig では `//` がコメントになるため、URL は `https:/$()/…` と書く(`write-xcconfig` が自動で変換する)
- **入れてよいのは anon(publishable)キーだけ**。service_role / `sb_secret_…` キーは IPA に同梱されて漏れる。
  `supabase_config.py` は形式を検証し、これらを見つけたら dry-run でも必ず失敗にする
- 実機・Xcode から署名して動かすときのチーム(`DEVELOPMENT_TEAM`)も `Secrets.xcconfig` に書ける(XcodeGen が毎回プロジェクトを作り直すので、Xcode の画面で選んだチームは消える)

## 3. 版とビルド番号

- `MARKETING_VERSION`(ストアに出る版)= `Config/Base.xcconfig`。**v1.0 の初回提出は `1.0.0`**。`x.y.z` 形式(`ReleaseReadinessTests` が検査)
- `CURRENT_PROJECT_VERSION`(ビルド番号)= ローカルは `1`。TestFlight に上げるビルドは `lien-release` が **`github.run_number`** で上書きする
  (同じ版の中で単調増加が必要。`lien-release.yml` のファイル名を変えると run_number が 1 に戻るので変えない)
- ウィジェットと NSE も同じ版・同じビルド番号(Info.plist が `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` を参照)

## 4. Swift パッケージの固定

- `project.yml` の supabase-swift は **`exactVersion`**(いま `2.55.3`)。推移依存(swift-crypto など)も含めた解決結果を
  [`Package.resolved`](Package.resolved) にコミットしてある
- `.xcodeproj` は毎回作り直されるので、`scripts/pin-packages.sh` が `xcodegen generate` の直後にこのファイルを戻して解決する。
  以降の `xcodebuild` は `-onlyUsePackageVersionsFromResolvedFile` で固定を使う
- **版を上げるとき**: `project.yml` の `exactVersion` を変えて push する → `pin-packages.sh` が「Package.resolved が食い違っています」と
  **新しい内容を出力して止まる** → その内容を `Package.resolved` に貼ってコミットする(ローカルに Xcode があれば
  `xcodegen generate && xcodebuild -resolvePackageDependencies -project Lien.xcodeproj -scheme Lien` の後、
  `Lien.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` をコピーしてもよい)

## 5. push_env(APNs の環境)

- `users.push_env`(sandbox / production)は**署名の `aps-environment`** で決める(`Lien/Core/APNsEnvironment.swift`)。
  以前の「DEBUG = sandbox」判定は、Xcode から Release 構成を development 署名で入れた端末を production と取り違えた
- 判定: シミュレータ → sandbox / `embedded.mobileprovision` が無い(TestFlight・App Store)→ production /
  あればその `Entitlements["aps-environment"]`(`production` のとき production、それ以外は sandbox)
- エンタイトルメントのソース(`Lien/Lien.entitlements`)は `aps-environment = development`。配布(TestFlight・App Store)の書き出し時に
  Xcode の自動署名が `production` に差し替える。サーバーは `users.push_env` を見てトークンごとに APNs のエンドポイントを選ぶ(DESIGN §4.1)

## 6. プライバシーマニフェスト(PrivacyInfo.xcprivacy)

- アプリ・ウィジェット・NSE の各フォルダに 1 つずつ(`Lien/` `LienWidget/` `LienNSE/`)。`project.yml` の sources に含まれ、リソースとして同梱される
- **トラッキングなし**(`NSPrivacyTracking = false`)。**分析 SDK なし**(D6)なので、収集データの用途は「アプリの機能」だけ
- **必須理由 API の棚卸し**(2026-10-13、Xcode 26.6 の Release archive で実測)
  - 自前のコード: `UserDefaults`(`PushTokenSync` の送信記録。アプリ自身だけが読む = 理由 `CA92.1`)だけ。ファイルのタイムスタンプ・起動時刻・ディスク容量・キーボードは使っていない
  - ウィジェット・NSE: App Group のファイルを読み書きするだけ。使っている必須理由 API なし
  - 依存パッケージ: supabase-swift 2.55.3 は自前の PrivacyInfo.xcprivacy を持たない。バイナリには `FileManager.attributesOfItem` の参照がある
    (ファイルのメタデータ。C の `stat` 系・`mach_absolute_time` などのシンボルは**無い**)。Apple の静的解析が拾う可能性に備えて、
    アプリのマニフェストに `FileTimestamp` / `C617.1`(アプリのコンテナ内のファイルのメタデータ)を宣言してある。
    swift-crypto は自前のマニフェストを持つ(必須理由 API の宣言なし)。supabase-swift が自前のマニフェストを持つ版になったら見直す
  - `LienTests/PrivacyManifestTests` が Swift ソースを走査し、**使っているのに宣言が無い API** を CI で検出する(コードを足したときの宣言忘れを止める)
  - 依存パッケージの分は、`lien-release` の dry-run が**出来上がったバイナリ**を `scripts/scan_required_reason_apis.py` で棚卸しして
    step summary に表を出す。**C の関数そのもの(`_stat` など)を使っているのに宣言が無ければ失敗**にする(文字列だけの検出は表に出すだけ)
- 収集データの宣言(ニックネーム・写真・約束や記録・匿名ユーザー ID・プッシュトークン)は `review-notes.md` §2.1 の草案どおり。
  App Store Connect の「アプリのプライバシー」の回答と突き合わせた最終確認は T30

## 7. アプリアイコン

- 正本は [`../assets/icon/icon_1024.png`](../assets/icon/icon_1024.png)(**v4「タネの子」・空色**。D1)。
  `Lien/Assets.xcassets/AppIcon.appiconset/icon_1024.png` はそのコピーで、`ReleaseReadinessTests` が一致を検査する
- 1024×1024 の単一サイズ・**アルファチャンネルなし**(PNG カラータイプ 2。App Store の要件)。角丸は付けない(Apple が適用する)
- 差し替えるときは両方を同じ画像にする。`project.yml` の `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` が参照する

## 8. TestFlight へのアップロード(G0 のあとに人間がやること)

`lien-release`(`.github/workflows/lien-release.yml`)が archive・署名・アップロードまで行う。**手動起動のみ**。

### 8.1 準備(1 回だけ)

1. Apple Developer Program への加入、App Store Connect でアプリのレコード作成(Bundle ID = `com.ryoki63.lien`。名前は仮でよい — G0)
2. App Store Connect → ユーザとアクセス → 統合 → **App Store Connect API** でキーを発行し、`.p8` をダウンロードする
   (一度しかダウンロードできない)。ロールは **Admin を推奨**(クラウド署名が配布用の証明書を作るため。App Manager で足りるかは初回に確認)
3. GitHub のリポジトリ → Settings → Secrets and variables → Actions に登録する:

   | secret | 値 |
   |---|---|
   | `ASC_KEY_P8` | `.p8` ファイルの中身(`-----BEGIN PRIVATE KEY-----` から)。base64 にしたものでも可 |
   | `ASC_KEY_ID` | そのキーの Key ID |
   | `ASC_ISSUER_ID` | Issuer ID |
   | `APPLE_TEAM_ID` | Apple Developer の Team ID(10 桁の英数字) |
   | `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
   | `SUPABASE_ANON_KEY` | anon(publishable)キー。**service_role / secret キーは入れない** |

   App ID(`com.ryoki63.lien` / `.widget` / `.nse`)・App Group(`group.com.ryoki63.lien.shared`)・Push Notifications は、
   クラウド署名(`-allowProvisioningUpdates`)が自動で登録する。App Group の自動付与に失敗したときだけ、
   Developer Portal で App ID に手動で付与して再実行する

### 8.2 実行

```sh
gh workflow run lien-release.yml --repo Ryoki63/Challenge -f dry_run=true    # まず無署名 archive と検査だけ
gh workflow run lien-release.yml --repo Ryoki63/Challenge -f dry_run=false   # 署名して TestFlight へ
```

- `dry_run=false` で secrets が 1 つでも足りないと、最初のステップで**足りない名前を出して止まる**
- archive のあと `scripts/verify_archive.py` が次を**アップロード前に**検査し、1 つでも NG なら止まる:
  Bundle ID(3 バンドル)・版とビルド番号の一致・最低 OS 17.0・iOS 26 SDK・AppIcon・PrivacyInfo.xcprivacy が 3 バンドルに入っていること・
  **Info.plist に Supabase の URL と anon キーが入っていること**(service_role / secret キーなら拒否)
- 成功したら App Store Connect の TestFlight にビルド(版 `1.0.0`・ビルド番号 = run_number)が出る。「処理完了」を待ってから、
  内部テスターに追加して実機に入れる(`ITSAppUsesNonExemptEncryption = false` 設定済みなので輸出コンプライアンスの質問は出ない)
- TestFlight は production の APNs。アプリは `users.push_env = production` を自動で保存し、サーバーはトークンごとに環境を選ぶ(§5)

## 9. スクリプト一覧(`scripts/`)

| ファイル | 役割 |
|---|---|
| `select-xcode.sh` | `.xcode-version` の Xcode に切り替え、iOS 26 SDK 以上を検査 |
| `pin-packages.sh` / `package_resolved.py` | `Package.resolved` を `.xcodeproj` に戻して解決し、ずれを検出 |
| `supabase_config.py` | 接続情報の検証・`Secrets.xcconfig` の生成・Info.plist の検査 |
| `release.sh` | `xcodebuild archive` / `-exportArchive`(`RELEASE_PRINT_ONLY=1` でコマンドの表示のみ) |
| `verify_archive.py` | `.xcarchive` のアップロード前検査 |
| `scan_required_reason_apis.py` | 出来上がったバイナリの必須理由 API の棚卸し |
| `export_attachments.py` | xcresult のテスト添付(植物の実描画の一覧画像)を、読みやすい名前の PNG として取り出す(§10) |
| `test_*.py` | 上記の単体テスト(`python3 -m unittest discover -s scripts -p 'test_*.py'`。lien-ios でも毎回実行) |

## 10. 植物の描画と、実描画の一覧画像(issue #56)

- 植物「タネの子」は **SVG レイヤー34点の重ね合わせ**。絵の正本は [`../assets/plant/`](../assets/plant/mapping.md)(`svg/` と `PlantAssets.xcassets`。重ね順・状態対応・のぞきの位置は `mapping.md`)
  - `Lien/Core/DesignSystem/PlantLayers.swift` — 状態 → 重ねるレイヤーの並び(純粋関数)。snapshot からの状態の導出(GROWTH.md §4.1)もここ
  - `Lien/Core/DesignSystem/PlantCharacterView.swift` — ZStack で重ねる。右の葉・右の花は左右反転、花の塗りはコード側で着色、ダークは背面プレート
  - ウィジェット(LienWidget)も同じ2ファイルと同じカタログを使う(S ウィジェットは試作 — 本実装は T17a)
- テスト: `PlantLayersTests`(重ね順の規則・`assets/plant/layer_stacks.json` との一致・導出の表・34レイヤーが空白でなく描けること・着色)/ `PlantRenderTests`(一覧画像)
- **実描画の一覧画像**: lien-ios の artifact `plant-render-sheets`(`PlantRenderTests` が `ios/build/plant-render/` に書く。ライト/ダーク × 全段階 × 今日の状態・40/60/80pt・表情・のぞき・花の色)。
  同じ画像を xcresult の添付からも取り出して `plant-render-sheets-xcresult` に、xcresult 自体を `xcresult` に残す(テストが失敗しても残る)
  - 取り出し: `gh run download <run-id> --repo Ryoki63/Challenge -n plant-render-sheets`
  - 承認ゲート(GROWTH.md §9.5)は、この画像と下書きのプレビュー(`../assets/plant/v4_drafts/preview_*.png`)を見比べて行う
