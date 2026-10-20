# STRUCTURE.md — リポジトリ構成ガイド

このリポジトリの全ファイル・全フォルダの役割をまとめたドキュメント。
役割の定義は `AGENTS.md` の「リポジトリ構成」表と整合させており、本書はその詳細版にあたる。

## このリポジトリは何か

**月3万円の継続収益を生むアプリを作る**個人開発プロジェクト(2026-06開始)。
第1弾プロダクトは **Lien(リアン)** — 2人で約束を1つだけ決めて続ける習慣アプリ。

開発は Claude Code による自律ループ(Ralph パターン)で進める。
「指示書(憲法・手順書)+ タスクキュー + 追記専用ログ + アプリ本体」という構成になっている。

## ルート直下の全体像

```
Challenge/
├── .claude/            # Claude Code の設定とプロジェクトskill
├── .github/            # GitHub Actions ワークフロー(CI)
├── .gitignore          # Git管理から除外するファイルの定義
├── AGENTS.md           # エージェント憲法(最上位の指示書)
├── CLAUDE.md           # Claude Code のエントリポイント
├── LOOP.md             # 自律ループ1回分の実行手順書
├── README.md           # 人間向けの全体説明(仕組み・使い方)
├── docs/               # 企画・仕様・設計・計画ドキュメント
├── marketing/          # 獲得計画・X 投稿・計測設計(ストア文言は products/lien/marketing/)
├── products/           # アプリ本体置き場(1アプリ = 1サブフォルダ)
├── progress/           # 実行履歴・監査ログ
├── ralph.ps1           # ヘッドレスループランナー(外側のループ)
└── tasks/              # ローカルのタスクキューと完了アーカイブ
```

(このほか Git 管理用の `.git/` と、macOS が自動生成する `.DS_Store` が存在するが、リポジトリの内容物ではないため以降は扱わない。`.DS_Store` は `.gitignore` で除外済み。)

## ルート直下のファイル

### AGENTS.md — エージェント憲法

すべてのエージェント(対話セッション・ヘッドレスループ・サブエージェント)が従う**最上位の指示書**。他の指示と矛盾したらこのファイルが優先する。ミッション(月3万円・Lien)、技術原則(シンプル最優先・SwiftUI + Supabase + RevenueCat)、タスク管理ルール(GitHub Issues が正)、GitHub 同期ポリシー(commit = push)、禁止事項、検証ポリシーを定める。

### CLAUDE.md — Claude Code のエントリポイント

Claude Code が毎セッション自動で読み込むファイル。実体は「AGENTS.md を必ず読め」という参照と、Claude Code 固有の補足(skill の使い分け、コミットメッセージ規約)のみ。指示の本体は AGENTS.md 側にある。

### LOOP.md — ループ実行手順書

自律ループ**1回分**(= 1タスク)の実行手順を定義する。タスクの取得 → 実行 → 検証 → 記録 → commit & push → 終了シグナル(`<LOOP_CONTINUE>` / `<LOOP_COMPLETE>` / `<LOOP_BLOCKED>`)の出し方まで。指示の優先順位は `AGENTS.md` > `LOOP.md` > 各タスクの記述。

### README.md — 人間向けの全体説明

このリポジトリの仕組み(Loop Engineering / Ralph パターン)、使い方(タスクの積み方・ループの回し方・結果の確認方法)、プロジェクトskill 一覧、安全装置(ガードレール)をまとめた、人間が最初に読むドキュメント。

### ralph.ps1 — ヘッドレスループランナー

外側のループを担う PowerShell スクリプト。`claude -p "LOOP.mdに従え"` を繰り返し起動し、1起動 = 1タスクで BACKLOG を消化する。`-MaxIterations` で上限回数を指定でき、無限ループを物理的に防止する。

### .gitignore — Git 除外定義

コミットしてはいけないものを定義する。大きく3分類:

- **シークレット**: `.env` / `.env.*`(`.env.example` のみ許可)。APIキー類はファイルにハードコードせず `.env` に置くルール(AGENTS.md 禁止事項)とセット
- **依存・ビルド成果物**: `node_modules/`, `dist/`, `build/`, `.expo/`, `__pycache__/`, `*.pyc`
- **OS・エディタごみ**: `.DS_Store`, `Thumbs.db`

## ルート直下のフォルダ

### .claude/ — Claude Code 設定

| パス | 役割 |
|---|---|
| `settings.json` | 自律実行用の権限許可リスト(許可コマンドの管理、`.env` 読み取り拒否など) |
| `settings.local.json` | 個人環境ローカルの設定上書き |
| `skills/plan/` | `/plan` — 目標を1コミット粒度のタスクに分解して issue 作成 + BACKLOG に積む |
| `skills/status/` | `/status` — 進捗レポート(残タスク・ブロック・同期状態) |
| `skills/sync/` | `/sync` — GitHub と完全同期(コミット漏れ回収 → pull --rebase → push) |

### .github/ — GitHub Actions(CI)

| パス | 役割 |
|---|---|
| `workflows/lien-ci.yml` | Lien の CI ワークフロー。全 push と手動実行(workflow_dispatch)で起動し、ubuntu ランナーで `products/lien/supabase/functions` の `deno test` を実行する(`docs/DESIGN.md` §8 の方針)。iOS ビルドジョブは TASKPLAN の T06 で別ワークフロー(`products/lien/ios/**` 変更時のみ起動)として追加予定 |

### docs/ — 企画・仕様・設計・計画

Lien のドキュメント群。**矛盾したら REQUIREMENTS → DESIGN → CONCEPT の順に優先**する。

| ファイル | 役割 |
|---|---|
| `CONCEPT.md` | 企画書。海外事例のエビデンス・市場タイミング・プロダクト設計の決定事項(罰を使わない設計 = §5 など)。「なぜ作るか」 |
| `REQUIREMENTS.md` | **確定仕様**。機能・非機能要件・データモデル。仕様の最終的な拠り所。「何を作るか」 |
| `DESIGN.md` | 技術設計書(コーディングエージェント向け)。アーキテクチャ、`products/lien/` のディレクトリ構成(§2)、iOS/Supabase 設計、コーディング規約。「どう作るか」 |
| `TASKPLAN.md` | 実装計画。タスクの順序・並列性・人間ゲート(G0〜G6)。「どの順で作るか」 |
| `GROWTH.md` | 植物(タネの子)の成長ルール。10段階の閾値・毎日の見え方・演出・名前付け・検証の指標(承認済み。REQUIREMENTS §3.9 の設計根拠) |
| `KPI.md` | KPI の SQL(D6: 分析 SDK を入れず DB から出す)。両者継続・ペア成立率・つつき→チェックイン率・名前付け率・段階到達率。毎週金曜の `/status` で手元から実行する(読み取りのみ。テストデータは OPS.md §8 の台帳で除外) |
| `REVIEW-2026-10-12.md` | 4か月の中断から再開した時点の、残タスクの洗い出しと方針レビュー。決定パッケージ D1〜D6(§1)・日程(§3)・進捗(§7) |
| `E2E-M1.md` | M1(ペア成立→約束→チェックイン→ストリーク→つつく→通知)の実機 E2E チェックリストとランブック(T20) |
| `STRUCTURE.md` | 本書。リポジトリ構成ガイド |

### marketing/ — 獲得計画・投稿・計測

公開前後の獲得(マーケティング)の計画と記録。**ストアの文言・スクショ・法務文書は `products/lien/marketing/`**にあり、こちらは「いつ・どのチャネルで・何を根拠に出すか」を扱う。置き場が 2 つに分かれるのは、前者がアプリの提出物(ASC に投入する値)で、後者が継続的に更新する運用文書のため。

| ファイル | 役割 |
|---|---|
| `plan.md` | 公開前後 30 日の獲得計画(週次の投稿カレンダー・チャネル・予算・各週の指標と分母)。Issue #74(MK1)。**数値の定義は `docs/KPI.md`、日程は `docs/TASKPLAN.md` §9.2 が正** |

### products/ — アプリ本体

**1アプリ = 1サブフォルダ**。案内の `README.md` と、第1弾の **`products/lien/`**(TASKPLAN の T01 で作成した雛形)が入っている。

`docs/DESIGN.md` §2 に基づく `products/lien/` の構成:

```
products/lien/
├── ios/          # SwiftUI アプリ(XcodeGen)。本体 / ウィジェット / NSE / テスト / xcconfig
├── supabase/     # migrations(連番SQL)と Edge Functions(deno)
├── assets/       # 植物のイラスト(SVG レイヤー)・アイコン
├── web/invite/   # 招待用静的ページ(GitHub Pages)
└── marketing/    # ASO文言・スクショ・プライバシーポリシー・利用規約
```

### progress/ — 実行履歴・監査ログ

| ファイル | 役割 |
|---|---|
| `JOURNAL.md` | ループ各イテレーションの実行記録。**追記専用**で、過去分の編集・削除は禁止。人間が放置ループを監査するための一次資料 |

### tasks/ — ローカルのタスクキュー

| ファイル | 役割 |
|---|---|
| `BACKLOG.md` | タスクキュー。1行1タスク(`- [ ]` 形式)で、ループが上から順に処理する |
| `DONE.md` | 完了タスクのアーカイブ。**追記専用**(新しいものが下)。過去分の編集禁止 |

**重要: タスクの正式な一覧・状態は GitHub Issues**(`https://github.com/Ryoki63/Challenge/issues`)であり、`tasks/BACKLOG.md` はローカル補助キューにすぎない。issue と乖離した場合は **issue を優先**する。新タスクは `gh issue create` で issue を作ってから BACKLOG に書く。着手・完了・ブロックは issue へのコメントで記録し、`human-gate` ラベル付き issue はエージェントが close しない。

## 状態の持ち方(まとめ)

エージェントは毎回まっさらな状態で起動するが、状態は以下が覚えている
(The agent forgets, the repo doesn't):

- **これから・進行中**: GitHub Issues(正)+ `tasks/BACKLOG.md`(補助)
- **終わったこと**: `tasks/DONE.md` + `progress/JOURNAL.md` + git 履歴(1タスク = 1コミット = 即 push)
- **決まっていること**: `AGENTS.md`(ルール)と `docs/`(仕様・設計)
