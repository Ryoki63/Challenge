# JOURNAL — 実行履歴(こまめ追記 / 古い分は要約)

ループや対話セッションが「やったこと・判断・検証・結果」をここに **こまめに追記** します(ユーザーが常時ウォッチ)。
新しい記録は末尾へ追記し、直近の詳細エントリは編集しません。古いエントリは肥大化防止のため `## アーカイブ要約` に1〜数行へ畳みます(要約は事実を縮めるだけ。捏造・改ざんはしません)。
記録ルールの詳細は AGENTS.md「JOURNAL こまめ更新ポリシー / 古い記録のローテーション」を参照。

---

## アーカイブ要約

古い詳細エントリを圧縮したもの(新しい順)。

- **2026-06-10** — demo: `docs/STRUCTURE.md` 作成(ルート直下の全ファイル/フォルダの役割を日本語でまとめ)。issue #45 完了。
  - 未対応フォローアップ: `.claude/settings.local.json` が `.gitignore` に未登録 → 除外するか別途検討。
- **2026-06-10** — demo: `hello/hello.py` 作成("Hello from the loop!" を出力し、ループ動作を確認)。※ `hello/` ディレクトリはその後削除済み。

---

## 2026-06-10 23:34 — T01: products/lien/ 雛形作成 (issue #1)
- やったこと: DESIGN §2 準拠の products/lien/ ディレクトリ構成(ios/ supabase/ assets/ web/invite/ marketing/)、README、.gitignore、Secrets.example.xcconfig、CI骨格 .github/workflows/lien-ci.yml(deno test ジョブ)を作成。マルチエージェント並列実行(Wave 1)の1タスクとして実施。
- 判断したこと: ios/project.yml は TASKPLAN で T06 スコープのため T01 では作らない(README に注記)。iOSビルドCIも T06 が別ファイルで追加する。
- 検証: ローカル deno test 緑(1 passed)。独立検証エージェントが DESIGN §2 との構成一致・gitignore 動作・YAML構文を確認。CI緑は push 後に gh run で確認。
- 結果: 完了(issue #1 はCI緑確認後にclose)

## 2026-06-11 00:03 — chore: JOURNAL こまめ更新ポリシー追加 + 古い記録の整理
- 着手: ユーザー要望「JOURNAL をこまめに更新 + 古いものはマージ/要約/削除」を運用ルールに反映する。
- やったこと: AGENTS.md に「JOURNAL こまめ更新ポリシー(着手→節目→締め)」と「古い記録のローテーション(`## アーカイブ要約` へ畳む)」を追加。LOOP.md を着手時にJOURNAL見出しを書き始める手順へ更新(手順2〜5・フォーマット節)。CLAUDE.md に常時ウォッチ向けの補足を追加。禁止事項を「捏造・改ざん禁止(要約は手順に従えば可)」へ整合。本JOURNALの古いデモ2件を `## アーカイブ要約` に圧縮(.gitignore 未対応フォローアップは保持)。
- 判断したこと: アーカイブは別ファイルに分けず、同一ファイル先頭の要約セクションで運用(原則1「シンプル最優先」)。成果物が消えている hello デモは最小要約に圧縮。
- 検証: 4ファイルの相互参照(AGENTS↔LOOP↔CLAUDE)とJOURNALの新構成を目視確認。矛盾していた「追記専用・改変禁止」と新ローテーション規定を整合済み。
- 結果: 完了

## 2026-06-11 00:54 — 【節目】Wave 2 マルチエージェント並列実行: 8タスク中7タスク実装完了
- 体制: ユーザー指示によりGitHub issue駆動・4レーン並列(バックエンド ∥ iOS ∥ アセット ∥ マーケ)のWorkflowで実行中。各タスク = 着手コメント→実装→独立検証エージェント→NGなら修正1回→実施結果コメント。git操作はオーケストレータが直列管理(競合防止)
- 完了済み(Wave 1): #1 T01 雛形(CI deno-test緑、close済み)/ #45 STRUCTURE.md(close済み)
- 実装完了・検証済み(Wave 2、commit待ち): #2 migration 0001(独立検証でprivacy hole 2件指摘→修正済み)/ #3 streak.ts+tickets.ts(31テスト緑)/ #4 checkin/snapshot/apns.ts(モック注入)/ #6 ios project.yml+3ターゲット+lien-ios.yml CI / #7 PairSnapshot+AppGroupStore+静的ウィジェット+NSE骨格+LienTests / #9 植物ドット絵13枚+AssetCatalog取込+8倍プレビュー(G2 #40へ提出予定)/ #25 プライバシーポリシー+利用規約+HTML(G4ひな形)
- 実行中: #5 invite-create/invite-accept/close-day/grant-tickets(バックエンドレーン最終タスク)
- 補足: ghトークンにworkflowスコープが無くCI workflowのpushが一度拒否→ユーザーがデバイスフロー承認で解決(00:45頃)
- 次: #5完了→タスク単位commit+push→CI(deno+iOSビルド)緑確認→各issueをclose→G2提出コメント→フォローアップissue作成

## 2026-06-11 01:16 — 【締め】Wave 2 完了: M0の[W]タスク全消化+前倒し2件、CI全緑
- 結果: 8/8タスクが独立検証パス(修正ラウンド必要は#2のみ)。タスク単位で8コミットをmainにpush
- CI: lien-ci(deno 132テスト+スプライト検証)success / lien-ios(xcodegen→ビルド+シミュレータテスト、macos-15)success — ローカルXcodeなしで初回緑
- close済みissue: #2 #3 #4 #5 #6 #7 #9 #25(完了コメント付き)。Wave 1の#1 #45と合わせ計10件完了
- G2提出: #40 に植物スプライト13枚のコンタクトシート+既知の制限(fidget未作成等)をコメント。トーン選定は人間判断待ち
- 特筆: #2は独立検証エージェントがPGlite(実PostgreSQL 16.4)上でmigration全文を実行し、RLS・権限昇格遮断を50項目で実証検証。privacy hole 2件を発見→修正
- 残る[W]の実行可能タスク: #26(T26 アイコン+スクショ素材、T09依存→解消済み)のみ。M1(T10〜)はT08=G0待ち
- 主要フォローアップ(issue化する): checkin-cancel function未実装(DESIGN §5.3) / REQUIREMENTS §5へ実装スキーマの追記同期 / 写真アップロード経路の設計決定 / streak_resetイベント永続化+push type正式化
- M0の残り: #8(T08 Supabaseデプロイ+実機G1計測)= G0(#38)の人間対応待ちが律速

## 2026-06-11 01:45 — 【節目】Wave 3完了+ユーザー判断3件反映+G2差し戻し対応開始
- Wave 3(3/3検証パス・CI緑・close済み): #26 アイコン3案+スクショSVG+ASO文言案 / #46 checkin-cancel(deno test 142緑)/ #47 REQUIREMENTS §5同期+DESIGN §4 streak_reset追加
- ユーザー判断の反映: #48 写真経路=署名付きアップロードURL方式で承認→DESIGN §5.6 追記・close / #47 仕様ギャップ3問とも推奨案で確定(declare返金なし・streak_reset永続化なし・解消後photo_path現状維持)→DESIGN §5.7 追記・close
- G2(#40)差し戻し: 第1案は「可愛くない・愛着が湧かない」。フィードバック(多段階化・最終形態バリエーション・短中長期の成長カーブ)を#40に記録し、#49を起票
- #49 実行中: スタイル候補4方向(ぷにぷにパステル/レトロたまごっち/ゆるかわくすみ/マスコット生き物)を並列制作。各デザイナーが生成画像を自己視認→2回以上改良→アートディレクターが第1案と比較批評する体制。成長カーブ再設計案も並行
- G0前倒し: Supabase CLI 2.105.0 導入(Docker無しのためローカルスタック不可)。ユーザーの残作業=supabase login(5分)とApple Developer加入を#38に明記
- 注意事項(#26): アイコンは旧スプライトのパレット由来。v2トーン確定後に gen_icon.py のパレット追従が必要
