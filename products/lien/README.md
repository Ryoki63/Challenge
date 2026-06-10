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
│   ├── project.yml          # XcodeGen 定義(.xcodeproj はコミットしない)※T06 で追加
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
│   ├── plant/               # ドット絵スプライト(原寸PNG)
│   └── icon/
├── web/invite/              # 招待用静的ページ(GitHub Pages)
└── marketing/               # ASO文言・スクショ・privacy-policy.md・terms.md
```

## シークレット(DESIGN §7)

- `ios/Config/Secrets.xcconfig` は **gitignore 対象**(コミット禁止)。雛形は `ios/Config/Secrets.example.xcconfig` をコピーして人間(G0)が実値を設定する
- `SERVICE_ROLE_KEY` / APNs キー等は Supabase 側の環境変数・secrets で管理し、リポジトリには置かない
- コードへのキーのハードコードは禁止(AGENTS.md)

## 検証コマンド(DESIGN §8)

| 対象 | 検証コマンド | 動く場所 |
|---|---|---|
| functions 純粋ロジック | `cd products/lien/supabase/functions && deno test` | ローカル(Windowsループ可)/ CI |
| functions 統合 | `supabase functions serve` + curl | Mac(Docker)または G0 後のリモート dev |
| iOS ビルド | `xcodegen generate` → `xcodebuild build CODE_SIGNING_ALLOWED=NO` | GitHub Actions(macos)/ Mac |
| iOS 単体テスト | LienTests(日付処理・スナップショット解釈・キュー) | CI / Mac |
| 実機 E2E | TASKPLAN のチェックリスト | 人間+Mac(G1, M1末, G3) |

## CI

- `.github/workflows/lien-ci.yml` — deno test ジョブ(ubuntu-latest、全 push で起動)
- iOS ビルドジョブは T06 で別ワークフローとして追加予定(`products/lien/ios/**` 変更時のみ起動・8分以内)
