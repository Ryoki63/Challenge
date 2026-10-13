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
- さらに、Command Line Tools だけの Mac でも、UIKit・Supabase に依存しない部分のコンパイルと LienTests の実行、View の型検査は
  `scripts/macos-check/check.sh` で約 30 秒でできる(push 前の下見。CI が正本。[scripts/macos-check/README.md](scripts/macos-check/README.md))

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

### 8.1 準備(1 回だけ。順序に注意)

1. Apple Developer Program へ加入する(G0)
2. Developer Portal(Certificates, Identifiers & Profiles)→ **Identifiers** で、アプリ本体の App ID(Explicit)`com.ryoki63.lien` を登録する。
   **この登録を先に済ませる**: 次の App Store Connect の「新規アプリ」で選べる Bundle ID は、ここに登録済みのものだけ。
   Capabilities は選ばなくてよい(下の注記のとおり、足りないものはクラウド署名が付ける)
3. App Store Connect → アプリ →「新規アプリ」でレコードを作る(プラットフォーム iOS・名前は仮でよい・Bundle ID は 2. で登録した `com.ryoki63.lien` — G0)
   - **実機に Xcode から直接入れるとき(E2E の経路A — [docs/E2E-M1.md](../../../docs/E2E-M1.md) §1.2)だけ**: Developer Portal → **Devices** に、その実機の UDID を登録する
     (Xcode の自動署名で実機をつなぐと、自動で登録されることもある)。TestFlight へ上げるだけなら UDID の登録は要らない
4. App Store Connect → ユーザとアクセス → 統合 → **App Store Connect API** でキーを発行し、`.p8` をダウンロードする
   (一度しかダウンロードできない)。ロールは **Admin を推奨**(クラウド署名が配布用の証明書を作るため。App Manager で足りるかは初回に確認)
5. GitHub のリポジトリ → Settings → Secrets and variables → Actions に登録する(一覧は [DESIGN §7.2](../../../docs/DESIGN.md)):

   | secret | 値 |
   |---|---|
   | `ASC_KEY_P8` | `.p8` ファイルの中身(`-----BEGIN PRIVATE KEY-----` から)。base64 にしたものでも可 |
   | `ASC_KEY_ID` | そのキーの Key ID |
   | `ASC_ISSUER_ID` | Issuer ID |
   | `APPLE_TEAM_ID` | Apple Developer の Team ID(10 桁の英数字) |
   | `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
   | `SUPABASE_ANON_KEY` | anon(publishable)キー。**service_role / secret キーは入れない** |

   アプリ本体以外の App ID(`com.ryoki63.lien.widget` / `.nse`)・App Group(`group.com.ryoki63.lien.shared`)・Push Notifications は、
   クラウド署名(`-allowProvisioningUpdates`)が自動で登録・付与する。App Group の自動付与に失敗したときだけ、
   Developer Portal で App ID に手動で付与して再実行する

### 8.2 実行

```sh
gh workflow run lien-release.yml --repo Ryoki63/Challenge -f dry_run=true    # まず無署名 archive と検査だけ
gh workflow run lien-release.yml --repo Ryoki63/Challenge -f dry_run=false   # 署名して TestFlight へ
gh workflow run lien-release.yml --repo Ryoki63/Challenge -f dry_run=false -f internal_only=true   # G4・Pages 公開の前に、内部 TestFlight だけに使うとき
```

- `dry_run=false` で secrets が 1 つでも足りないと、最初のステップで**足りない名前を出して止まる**
- `dry_run=false` では、**運営者の連絡先と法務ページが揃っていないと止まる**(`scripts/check_release_inputs.py`): `SupportLinks.contactEmail` が空でない・
  利用規約とプライバシーポリシーの公開先(`SupportLinks.termsURL` / `privacyURL`)が HTTP 200。審査員と利用者が連絡できる・規約を読めることが前提のため
  (G4 #42 の連絡先の確定と、Pages 公開 — TASKPLAN §9.2 — が済むまでは止まる)。
  **G4・Pages 公開の前に、内部 TestFlight だけに使うビルド(T28a の最初のアップロードなど)を上げるときは `-f internal_only=true` を付ける**
  (止めずに注意として step summary に残る。そのビルドは外部テスト・審査に使わない)。dry-run は常に止めずに結果を表示する
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
| `check_release_inputs.py` | リリース前に、運営者の連絡先(`SupportLinks.contactEmail`)と法務ページの公開(HTTP 200)を確かめる(§8.2) |
| `scan_required_reason_apis.py` | 出来上がったバイナリの必須理由 API の棚卸し |
| `export_attachments.py` | xcresult のテスト添付(植物の実描画の一覧画像)を、読みやすい名前の PNG として取り出す(§10) |
| `macos-check/check.sh` | Xcode 無しの Mac で、Foundation 系のコードの macOS ビルド・LienTests の実行・View の型検査をする push 前の下見(§1。[README](scripts/macos-check/README.md)) |
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

## 11. 植物の体験: ゲージ・段階アップの演出・名前付けほか(issue #57)

成長ルール v2(docs/GROWTH.md §4〜§5)の、アプリ側の体験。サーバーの snapshot の新キー3つ(`plantGrownDays` / `plantStageFloor` / `plantNextStageAt`。**省略可** — 無いとゲージを出さない)から、アプリは閾値表を持たずに進み具合を作る。

| 何 | どこ |
|---|---|
| 進み具合(区間の中の位置)・のぞきを出す判定(区間7回以上の後半 = 11・18・26・38・56・83回から) | `Core/PlantProgress.swift`(ウィジェットとソース共有) |
| ゲージの文・VoiceOver の読み上げ文(GROWTH §5.1・§5.4) | `Core/GrowthGauge.swift`(文言は `Strings.Plant`) |
| 段階アップの演出を「1回だけ」出す記録(pairId ごと。新バージョン初回は静かに初期化・取り消しのあとの再到達では出さない。**「見せた」と記録するのは前面で表示したとき** — `markCelebrated`)・相手の名前の知らせ・おかえり・ひとこと・リアクションを送った日の「もう見せたか」。旧ペアの記録(相手が付けた名前)は掃除する | `Core/PlantMemory.swift`(端末の UserDefaults。サインアウト・削除で `reset()`) |
| 名前の入力の検査(NFC・Unicode コードポイントで 1〜8字・ZWJ だけ許す書式文字)と、plant-name の Live / スタブ(first の 409 は**自分が送った名前と同じなら成功・違えば相手の名前を採用**) | `Core/PlantNaming.swift`・`Core/Api/PlantNameAPIClient.swift` |
| 今日のひとこと(吹き出し)の選び方(状況 + 段階の候補から日付で1つ) | `Core/PlantWhisper.swift` |
| 体験の状態(全画面の演出・名前の知らせ・ひとこと)/ 名前フォームの状態 | `Features/Plant/PlantExperienceModel.swift`・`PlantNamingModel.swift` |
| 画面: ホームの植物まわり・吹き出し / 全画面の演出(ホームの上のオーバーレイ。シートにしない = ほかの表示と重なっても待てる。植物の行・ハートのボタンは別ファイル)/ 名前のフォームとシート | `Features/Plant/PlantHeroView.swift`・`WhisperBubbleView.swift`・`PlantCelebrationView.swift`・`PlantCelebrationPlantsView.swift`・`PlantCelebrationHeartView.swift`・`PlantNameFormView.swift`・`PlantNameSheet.swift` |

- 葉の下の約束の絵文字(左 = 自分・右 = 相手)と、小さな揺れ(プレートは揺らさない)は `PlantCharacterView` の中。揺れるかは描いている状態から決める(`PlantCharacterState.sways`)
- テスト: `GrowthGaugeTests`(ゲージ・のぞき・VoiceOver・揺れ)/ `StageCelebrationTests`(演出の記録・名前の知らせ・おかえり・ひとこと)/ `PlantNamingTests`(入力の検査・Live・スタブ・フォーム)/ `PlantHomeTests`(HomeViewModel とのつなぎ)/ `PlantWhisperTests` / `ContractFixtureTests`(新キーの値と plant-name の応答)/ `PairSnapshotTests`(新キー無し・往復)/ `PlantExperiencePolishTests`(仕上げ: 下の箇条書き)
- 実描画: `PlantRenderTests` が `plant_08`〜`plant_11`(ホームの植物まわり・全画面の演出。ライト/ダーク)も `plant-render-sheets` に書く。
  ホームの植物まわりには、文字を大きくした行(xxxLarge・accessibility3)もある
- **仕上げ(PB #57 の Opus レビューの改善提案。2026-10-13)**
  - 段階アップの「見せた」の記録は、snapshot を観測した時点でなく、前面で実際に表示した時点(`PlantExperienceModel.presentationDidAppear` ← `HomeView` が scenePhase が active のとき呼ぶ)。
    サイレント push で起こされたプロセスがバックグラウンドで観測して終了しても、演出を一度も見せずに失わない。閉じたときも記録する
  - 演出を出している間にペアが解消された・別のペアになったら、その演出(と、ひとこと)は下げる
  - 「(相手)にハートを送る」は、その日すでにリアクションを送っていたら出さない(サーバーの react は2回目以降を付け替えにして通知を送り直さないため。`HomeViewModel.canSendHeart`)
  - 相手が初めて名前を付けたときの知らせは「名前が『みどり』になったよ」(変えたときは「かわったよ」)。旧ペアの名前は、ペアが変わった・ソロに戻ったときに端末から消す
  - 今日のひとこと: VoiceOver のアクション「タネの子のひとこと」(ペア成立中)と、出すたびの読み上げ(`plantWhisperLifetime`)。吹き出しの上の余白は、文字の大きさに連れて広げる(`WhisperBubbleMetrics`。2行の吹き出しがホームの ScrollView の上端に食い込まない)。
    実機の VoiceOver・大きい文字での見え方は T20 で確認する
- 相手の今日の写真(PV #59)の仕上げ: 全画面で原寸が取れなかったらスピナーを止める(`PartnerPhotoModel.Viewer.Original`)/ 15 分たって取り直すとき、オフラインでも出している写真は消さない
  (行の読み取り・トークンの更新の通信失敗を `PartnerPhotoError.network` にそろえる)/ 読めなかった日は 3 分間取り直さない(通信の失敗は覚えない)/ 縦長の写真でも、枠と角丸とタップ範囲が写真そのもの(`PartnerPhotoCardLayout`)。
  画素での確認は `HomeRenderChecksTests`(CI のみ。見た目は artifact の `photo_01_partner_photo_cards.png`・`bubble_*.png`)。実機での見た目(縦長の写真の角丸・オフラインでの取り直し)は T20 で確認する
- 手元の下見(`scripts/macos-check/check.sh test <ファイル名...>`)で絞って走らせるとき、`PunishmentFreeLint`(`StringsReviewTests`)・`MockSnapshotClient`(`SnapshotSynchronizerTests`)などほかのテストファイルの部品を使うテストは、それらのファイル名も並べる

## 12. ローカル通知: リマインドとストリーク危機(issue #16)

v1.0 の端末のローカル通知は 2 つだけ(REQUIREMENTS §3.12)。配送の主体は**端末**で、サーバーの cron も新しい関数も migration も使わない。サーバーから届く通知(相手のチェックイン・つつく・リアクションなど)とは別。
**節目(7/30/100日)の通知は出さない**(アプリ内のお祝いは T22)。サーバー側の通知設定(種別ごとの ON/OFF)は v1.1(D3)なので、相手名義の通知の ON/OFF は iOS の設定アプリ(通知の設定画面に案内がある)。

| 通知 | いつ | 出さない・取り消す条件 |
|---|---|---|
| リマインド | 約束の `remind_at`(毎日・端末のローカル時刻) | その日、自分が完了している。オフ(`remind_at` が無い)。約束が無い |
| ストリーク危機 | 夜 9 時(21:00)。ペアのストリーク(続いている日数 1 以上)があり、その日まだふたりそろっていないとき | ふたりそろった。ペアが無い。設定でオフ。夜 9 時を過ぎた |

| 何 | どこ |
|---|---|
| 予約の中身を決める純粋関数 `ReminderScheduler.desiredRequests(prefs:snapshot:now:calendar:)`(取り消し条件・日付またぎ・タイムゾーン・夏時間・文言の出し分け) | `Core/Notifications/ReminderScheduler+Plan.swift` |
| 予約の合わせ込み(`sync()`。足りないものを足し、要らないものを消し、同じ内容には触れない / 同時に走るのは 1 本 / 配信済みの古い通知を外す / 時刻を知らないときはサーバーの約束から読む) | `Core/Notifications/ReminderScheduler.swift` |
| 通知センターの抽象と、予約 1 件の値(`PlannedNotification`)/ 本実装(UNUserNotificationCenter。変換は静的な関数でテストできる) | `NotificationScheduling.swift` / `UserNotificationCenterScheduler.swift` |
| 識別子(`lien.local.reminder.<日付>` / `lien.local.streak-risk.<日付>`)と「今日の分をもう出さなくてよい」の規則 — **アプリの同期と NSE で共通**(`LienNSE` とソース共有) | `LocalNotificationID.swift` |
| 設定(リマインドの時刻・ストリーク危機の ON/OFF)とその保存(App Group の `notification_prefs.json`。サインアウト・削除で消える) | `NotificationPreferences.swift`・`AppGroupStore.swift` |
| 設定画面(設定 → 通知)と状態 | `Features/Settings/NotificationSettingsView.swift`・`NotificationSettingsViewModel.swift` |
| 文言 | `Strings.LocalNotification`(通知)・`Strings.NotificationSettings`(画面) |

設計のポイント:

- **リマインドの時刻は約束の `remind_at` が正**(約束設定の画面と同じ値)。通知の設定画面で変えると、約束を更新する(promise-set。タイトルと絵文字は読んだままを送る)ので、保存はサーバーに届いてから端末の予約に反映する。サーバーの約束が読めない間は変えられない。端末は予約のために最後に知った値を覚える(`NotificationPreferences.reminder`)。まだ知らない間(この版へ更新した直後など)は、予約せずにサーバーの約束から読み(同期の中では待たない)、読めたら予約する。ストリーク危機は端末ローカルの設定
- **毎日くり返す通知(`repeats: true`)は使わない**。「今日だけ出さない」ができない(消すと明日以降も止まる)ので、日付ごとの 1 回きりの通知を**先の 14 日ぶん**予約し、状態を知るたびに作り直す(起動・前面復帰・サーバーとの同期・自分のチェックインと取り消し・約束の保存・ペアの成立と解消・サインアウト)。14 日アプリを開かなかった人には、その先は届かない(静かに終わる)。保留中の通知の上限 64 には、最大 15 件(リマインド 14 + ストリーク危機 1)で収まる
- **ストリーク危機は「記録が続いていると分かる日」にしか予約しない**: 今日(まだふたりそろっていなければ)。今日すでにふたりそろっていれば**明日の夜 9 時**の分(アプリを開けない日でも、つなげたい日の夜に届く)。同期できないまま日をまたいだときは、昨日ふたりそろっていた場合だけ今日の分を残す。それ以外は予約しない(途切れたかもしれない記録について通知しない)
- 日付はすべて**端末のローカル日**(グレゴリオ暦に固定。和暦・仏暦の端末でも年がずれない)。予約は壁時計(予約した時点のタイムゾーン)で持ち、タイムゾーンが変わったら次の同期で付け替える。snapshot の `todayMeDone` / `todayPartnerDone` は snapshot を作った日の完了なので、snapshot が今日のものでないとき(同期できないまま日をまたいだ)は、昨日の完了を今日の完了と取り違えない
- 文言は通知の名義がアプリ(title は「Lien」)で、罰なし(責めない・脅さない)。リマインドは日付で 3 つの言い回しを回す(1 つ目が REQUIREMENTS §3.12 の例)。ストリーク危機は「どちらも / 相手は済み / 自分は済み(「つつく」を案内)」で出し分ける。ストリーク危機の文言は、GROWTH §6.6 の表(案 A =「あと3時間。ふたりの23日が懸かってる」/ 案 B =「あと3時間。そろうと24日目」)を見て決めた: A は損失をちらつかせる強さがあり、B は罰なしの原則に近いがストリーク保険(課金の柱。REQUIREMENTS §10)の訴えが弱まる。そこで、保険の訴えの核(ふたりの記録の日数と「あと3時間」)は残し、「懸かってる」を「守ろう」(お休みチケットが「守る」ものと同じ言葉の、前向きな呼びかけ)にした →「あと3時間。ふたりの23日を、いっしょに守ろう🌱」。Strings.swift の lint(`StringsReviewTests`)の対象

### 取り消せなかったとき(NSE)— 実機の確認は T20

ふたりそろったことが分かったら、今日の夜 9 時の通知を取り消す。分かる経路は 2 つ: ① アプリが同期したとき(`sync()`)/ ② 相手のチェックインの push を NSE が受けたとき(`NotificationService` が `LocalNotificationCancellation` の規則で、今日の分の予約を `removePendingNotificationRequests`、届いたものを `removeDeliveredNotifications` で取り消す。取り消しがシステムに届いてから通知を出す)。

**②(NSE が本体のアプリの予約を消せるか)は、実機でしか確かめられず、まだ確かめていない。** Apple の文書には、拡張から本体の予約を消せるとも消せないとも書かれていない(2026-10-13 に調べた)。手がかりは、開発者フォーラムの報告([thread 684226](https://developer.apple.com/forums/thread/684226))で、NSE の `getPendingNotificationRequests` が本体の予約を返す前提で解決していること(Apple の回答は無い)。なので「たぶん消せる」と見て作り、消せなかったときのふるまいは決めてあり、テストで固定している(`ReminderSchedulerLearningTests.testWhenTheNSECannotCancel…` / `LocalNotificationRulesTests`):

1. 夜 9 時の通知は、ふたりそろっていても予約が残るので、そのまま届く。文言は、そのとき読んでも困らない言い方(「いっしょに守ろう」。記録を失う・脅す言い方はしない)
2. アプリが前面にいる間に届いたものは、出さずに捨てる(`AppDelegate.willPresent` → `shouldSuppress`)
3. 次にアプリを開いたとき(同期)、今日の分を消し、通知センターに届いてしまった分も外す
4. 最悪でも「ふたりそろった日の夜 9 時に、読んで困らない通知が 1 回届く」だけで、記録(ストリーク)には影響しない

### 確認できていること・できていないこと

- **CI(シミュレータ・macOS)で確認済み**: 予約の中身の計算(`ReminderPlanTests`。日付またぎ・タイムゾーン・夏時間・取り消し条件・NSE との規則の一致)/ 予約の合わせ込み(偽の通知センター)/ 設定の保存 / 設定画面の状態 / 各所からの呼び出し(`LocalNotificationWiringTests`)/ カレンダートリガーが、指定した暦・タイムゾーンどおりの瞬間を指すこと(`UserNotificationCenterSchedulerTests` が `nextTriggerDate()` で確認。iOS のシミュレータでも通る)
- **実機でしか確認できない(T20)**: 通知が実際に時刻どおり届くこと(ロック画面・バナー・音)/ OS の許可のダイアログ / **NSE が本体の予約を消せるか** / 端末のタイムゾーンを変えたときの挙動 / 機内モードでの挙動

### T20 の確認項目(実機・TestFlight)

1. **リマインドが届く**: 設定 → 通知 → リマインドの時刻を数分後にして「保存する」→ ホーム画面を閉じて待つ → 届く(ロック画面・バナー。本文に約束の名前と絵文字)
2. **済んでいれば出ない / 取り消しで戻る**: 上の時刻の前にチェックインする → 届かない。「取り消す」→ 時刻になると届く
3. **ストリーク危機(夜 9 時)**: ペア成立・ストリーク 1 日以上・ふたりとも未完の状態で、21:00 に届く(待てなければ、設定 → 一般 → 日付と時刻の「自動設定」を切って 20:58 に進める)。自分だけ済んでいる / 相手だけ済んでいる / どちらも未完で、本文が出し分けられている
4. **NSE の取り消し(未確認の項目)**: 夜 9 時の前に、相手がチェックインして**ふたりそろう** → 自分のアプリは開かずに 21:00 を迎える。**届かなければ NSE が消せている**。届いたら消せていない(上の 1〜4 のふるまいになっているか確かめ、この節と `NotificationService.swift` の冒頭に結果を書く)
5. **サインアウト・アカウントの削除のあと**は、どちらの通知も届かない
6. 機内モードでアプリを開き直しても、予約は消えない(日をまたいだ翌朝の、夜 9 時の分を含む)/ タイムゾーンを変えると、次にアプリを開いたとき壁時計で付け替わる
7. 通知の許可を「あとで」にしたまま設定 → 通知でリマインドかストリーク危機をオンにすると、許可のダイアログが出る。拒否されている端末では、設定画面に案内が出る
