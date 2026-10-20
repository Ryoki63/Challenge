# Lien(リアン)

2人で約束を1つだけ決めて続ける習慣アプリ。静かでシンプル、罰を使わない。

- 確定仕様: [docs/REQUIREMENTS.md](../../docs/REQUIREMENTS.md)
- 技術設計: [docs/DESIGN.md](../../docs/DESIGN.md)
- 実装計画: [docs/TASKPLAN.md](../../docs/TASKPLAN.md)

## 技術スタック

- iOS: ネイティブ SwiftUI + WidgetKit(iOS 17.0+ / Swift 5.10+、外部依存は supabase-swift のみ)
- バックエンド: Supabase(Postgres + RLS / Edge Functions = deno / TypeScript)
- 課金: RevenueCat(v1.1 で追加)
- プロジェクト生成: XcodeGen(`.xcodeproj` はコミットしない。`ios/project.yml` が正)

## ディレクトリ構成(DESIGN §2)

```
products/lien/
├── ios/
│   ├── project.yml          # XcodeGen 定義(.xcodeproj はコミットしない)
│   ├── Lien/                # アプリ本体ターゲット
│   ├── LienWidget/          # ウィジェット拡張
│   ├── LienNSE/             # Notification Service Extension
│   ├── LienTests/           # 単体テスト
│   └── Config/              # *.xcconfig(Secrets.xcconfig は gitignore)
├── supabase/
│   ├── migrations/          # NNNN_name.sql 連番
│   └── functions/           # Edge Functions(deno)
│       └── _shared/         # streak.ts / tickets.ts / apns.ts / snapshot.ts / messages.ts
├── assets/
│   ├── plant/               # 植物「タネの子」の SVG レイヤー34点+PlantAssets.xcassets+生成スクリプト(tools/)。規則は mapping.md
│   └── icon/
├── web/                     # GitHub Pages に配信する静的サイト(#76)
│   ├── site/                #   配信物(ティザー・法務・招待)。ツールで生成する
│   ├── tools/build_site.py  #   md→html とサイトの組み立て(標準ライブラリのみ)
│   └── invite/              #   招待ページの原本(T11。site/lien/i/ に複製される)
└── marketing/               # ASO文言・スクショ・privacy-policy.md・terms.md
```

## シークレット(一覧は DESIGN §7)

- `ios/Config/Secrets.xcconfig` は **gitignore 対象**(コミット禁止)。雛形は `ios/Config/Secrets.example.xcconfig` をコピーして人間(G0)が実値を設定する。入れてよいのは **anon(publishable)キーだけ**(service_role / `sb_secret_…` は IPA に同梱されて漏れる)
- Edge Function の **`SUPABASE_SERVICE_ROLE_KEY` は Supabase が自動で注入する**(自分では設定しない・リポジトリにも置かない)。このプロジェクトでは default の secret key(`sb_secret_…`)で、legacy の `service_role`(`eyJ…`)ではない。cron(close-day / grant-tickets)の認証には使わず、専用の `LIEN_CRON_SECRET` を使う(`scripts/OPS.md` §6)
- 手動で入れる Function secrets は、APNs の5変数(`APNS_AUTH_KEY` / `APNS_KEY_ID` / `APPLE_TEAM_ID` / `APNS_ENV` / `APNS_TOPIC`)と `LIEN_CRON_SECRET`(任意で `INVITE_WEB_BASE_URL`)。TestFlight 用の署名と接続情報(`ASC_KEY_P8` ほか6件)は GitHub Actions secrets(`ios/README.md` §8.1)
- コードへのキーのハードコードは禁止(AGENTS.md)

## 検証コマンド(DESIGN §8)

| 対象 | 検証コマンド | 動く場所 |
|---|---|---|
| functions 純粋ロジック | `cd products/lien/supabase/functions && deno test` | ローカル(Windowsループ可)/ CI |
| functions 統合 | `supabase functions serve` + curl | Mac(Docker)または G0 後のリモート dev |
| iOS ビルド | `xcodegen generate` → `xcodebuild build CODE_SIGNING_ALLOWED=NO` | GitHub Actions(macos)/ Mac |
| iOS 単体テスト | LienTests(日付処理・スナップショット解釈・キュー) | CI / Mac |
| 実機 E2E | TASKPLAN のチェックリスト | 人間+Mac(G1, M1末, G3) |

## CI(`.github/workflows/`)

| ワークフロー | 起動 | 内容 |
|---|---|---|
| `lien-ci.yml` | 全 push | deno test(Edge Functions)・契約フィクスチャの一致検査・植物アセット(SVG の再生成 diff 検査+verify)・ストアメタデータの検査 |
| `lien-ios.yml` | `products/lien/ios/**` ほか(契約フィクスチャ・植物アセット・アイコン)の変更時 | iOS のビルドとテスト(macOS。Xcode は `ios/.xcode-version` に固定 — `ios/README.md` §1) |
| `lien-release.yml` | 手動 | TestFlight 用の archive・署名・アップロード(`dry_run` は既定で true — `ios/README.md` §8) |
| `lien-deploy.yml` | 手動 | Supabase への migration とデプロイ(`scripts/deploy.sh`) |
| `lien-cron-watch.yml` | 毎朝 00:40 JST ほか | 本番の定期実行(cron)の監視(`scripts/OPS.md`) |
