# macos-check — Xcode が無い Mac で、push の前に「コンパイルできる・テストが緑」を確かめる

ローカルの Mac には Xcode が無く(Command Line Tools だけ)、iOS のビルドとテストは CI(`lien-ios`。macOS ランナーは10倍消費で、1回 10 分前後)でしかできない。
そこで **UIKit・Supabase に依存しない部分を macOS 向けにコンパイルして、LienTests を手元で走らせる**。
数十秒で回るので、push の前に CI で落ちそうな間違い(型の食い違い・テストの期待違い)をほぼ拾える。

> **CI(lien-ios)が正本。** これは下見で、通っても CI の緑の代わりにはならない(iOS の SDK・シミュレータ・本物の XCTest・UIKit を使う部分は見ない)。
> PV(#59)の実装では、これで LienTests の 384 件(CI は除外分を含む 444 件)を手元で緑にしてから push し、CI の初回が緑だった。

## 使い方

```sh
cd products/lien/ios
scripts/macos-check/check.sh                       # build + test + views(全部。約 30 秒)
scripts/macos-check/check.sh test                  # module のビルド + LienTests を全部走らせる
scripts/macos-check/check.sh test PartnerPhotoTests PartnerPhotoNetworkTests   # テストファイル(拡張子なし)を絞る
ONLY='PartnerPhotoModel' scripts/macos-check/check.sh test   # "クラス名.メソッド名" の正規表現で絞る
VERBOSE=1 scripts/macos-check/check.sh test        # PASS の行も出す
scripts/macos-check/check.sh views                 # SwiftUI の View と AppServices+Live の型検査だけ
scripts/macos-check/check.sh widget                # LienWidget(WidgetKit の拡張)の型検査だけ
```

- 終了コード: 0 = すべて通った / 1 = コンパイルエラー・テスト失敗
- 作業ディレクトリは `$TMPDIR/lien-macos-check`(リポジトリの外。`MACOS_CHECK_OUT` で変えられる)
- 必要なもの: Command Line Tools(`xcode-select --install`)と `python3`(3.9 で確認)。bash 3.2(macOS 標準)で動く

## 何を検査するか

| サブコマンド | 内容 |
|---|---|
| `build` | `Lien/` のうち UIKit・Supabase・SwiftUI の View に依存しないファイル(約 40 本。モデル・ViewModel・API クライアント・サービス)を、macOS 向けの static ライブラリ **module `Lien`**(`-enable-testing`)としてコンパイルする |
| `test` | `build` のあと、`LienTests/` のテストを `@testable import Lien` のままコンパイルして走らせる。XCTest は `XCTestShim.swift`(必要な API だけを作り直したもの)で代用する |
| `widget` | LienWidget ターゲット(WidgetKit の拡張。`LienWidgetBundle` / `LienWidgetEntryView`)を、`project.yml` の `LienWidget` の sources(Swift のファイルとフォルダ)のとおりに集めて、macOS の SDK で**型検査だけ**する。ロック画面の accessory 系ファミリー(`accessoryCircular` / `accessoryInline`)は macOS の SDK に無いので、型検査用のコピーでだけ macOS にあるファミリーへ読み替える(API の使い方の検査には影響しない)。`views` が `Lien/Core/Widget/Views/`(ホーム S / M・ロック画面のビュー)を型検査し、`widget` が WidgetKit の接ぎ手を型検査する |
| `views` | View(`HomeView` ほか)と `AppServices+Live.swift` を macOS の SDK で**型検査だけ**する。`Colors.swift`(UIKit の色)は macOS の色に書き換えたコピーで、`SupabaseService` / `PushManager` は `stubs/LiveStubs.swift` の代役で、`fullScreenCover` と(設定画面が使う)`PromiseSetupView` は `stubs/ViewShims.swift` の代役で通す。`-strict-concurrency=complete` を付けるので、Swift の並行性の警告(Xcode 26 / Swift 6.3 で出うるもの)も事前に見える |

## 検査しないもの(`check.sh` の `exclude_from_module` / `EXCLUDE_TESTS`)

- `AppDelegate` / `LienApp` / `RootView` / `SupabaseService` / `PushManager` / `QRCodeGenerator` / Debug の View: UIKit・UserNotifications・supabase-swift・`@main`・iOS 専用 API
- テスト `AppServicesTests` / `ConfigTests`(`AppServices+Live` を使う)・`PlantRenderTests` / `PlantLayersTests` / `HomeRenderChecksTests` / `NotificationSettingsRenderTests` / `WidgetRenderTests`(と、その道具 `WidgetRenderSupport`)・`ShareImageRenderTests`(アセットカタログ・描画・UIKit のウィンドウと色・`XCTAttachment`)・`StoreScreenshotRenderTests`(と、その枠 `StoreScreenshotFrames`。ストア用スクリーンショットの実描画 — issue #80)・`DeviceTokenStoreTests` / `QRCodeGeneratorTests` / `SmokeTests`
- 描画の見た目・実機の挙動・シミュレータ上の UI・NSE のターゲット: CI と実機(T20)で見る。ウィジェットの WidgetKit の接ぎ手は `widget` で型検査できるが、動かしてはいない(実描画の一覧と画素の検査は CI の `WidgetRenderTests`)

新しいファイルが UIKit などに依存するようになって `build` が落ちたら、`check.sh` の除外に足す(理由をコメントに)。
`PushAuthorizing`(`PushManager.swift`)や `SupabaseService` の公開面を変えたら、`stubs/` の代役も同じに直す。

## しくみと落とし穴

- **Command Line Tools の一部の版では、`swiftc` が Foundation を import するだけで `redefinition of module 'SwiftBridging'` で落ちる**
  (`/Library/Developer/CommandLineTools/usr/include/swift` に `module.modulemap` と `bridging.modulemap` が両方ある)。
  `check.sh` は最初に試し、この症状なら古い方の `module.modulemap` を空のファイルに見せる VFS overlay(`-vfsoverlay`)を付けて回避する。
  root で消せば直るが、システムのファイルは触らない
- `gen_runner.py` が、テストファイルから `XCTestCase` のサブクラスと `test…` メソッドを拾って `main.swift`(実行役)を作る。
  `@MainActor` のクラスも `async throws` のメソッドもそのまま呼ぶ。1件の失敗で止まらず、最後に件数と失敗の一覧を出す
- `XCTestShim.swift` は **XCTest の一部**(`XCTAssertEqual` / `True` / `False` / `Nil` / `NotNil` / `GreaterThan` ほか / `XCTUnwrap` / `XCTFail` / `XCTAssertThrowsError`)だけ。
  LienTests が新しい API(`XCTestExpectation` など)を使い始めたらテストのコンパイルが落ちるので、シムに足す
- macOS と iOS の違いに注意: Foundation の挙動は基本同じ(`URL(string:)` が不正な文字を自動でエンコードする、ImageIO が小さい画像を拡大しない、など
  PV のテストで実際に確かめた)だが、SwiftUI の見た目・シミュレータ固有の挙動・本物の XCTest の細部は違いうる。迷ったら CI の結果を信じる
- 手元の Swift(6.1 系)と CI の Xcode 26.6(Swift 6.3)は版が違う。新しい警告は CI で初めて出ることがある
