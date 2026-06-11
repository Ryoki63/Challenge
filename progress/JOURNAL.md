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

## 2026-06-11 (対話) — #49 再開: 前セッション中断のキャッチアップ
- 状況: ユーザーが前セッションを誤って終了。直前コミット 5eef2f0 は「v2着手」止まりで作業ツリーはクリーン = **v2スプライトの制作物は未コミット(消失)**。#49 は着手コメントのみで再提出前に中断
- キャッチアップ結論: いま自律再開できる実質タスクは #49 のみ(他はG0=#38 / G2トーン選定=#40 の人間ゲート待ち)
- 方針: v0と同じ依存ゼロPython方式(grリッド→zlib/struct でPNG直書き、エージェントが出力を Read で自己視認し改良)で、スタイル候補4方向を v2_drafts/style_{a,b,c,d}/ に再制作。4デザイナーを並列起動し各2回以上改良→アートディレクタが第1案と比較批評→成長カーブ案 → #40 へ再提出
- 着手: 4並列デザイナーエージェント起動

## 2026-06-11 (対話) — #49 style_a「ぷにぷにパステル」着手(デザイナーA)
- 担当: v2スプライト第2案のスタイル候補A。24×32px・顔を植物本体に配置・大きい目+白ハイライト+ほっぺ・パステル・丸シルエット
- 方式: v0の gen_sprites.py(依存ゼロ・zlib/struct でPNG直書き・8倍拡大・コンタクトシート)を踏襲し self-contained な gen.py を新規作成
- キーフレーム6枚: soil / sprout / mid / late / final_normal / final_happy。生成→Read自己視認→2回以上改良の予定

## 2026-06-11 01:53 — chore: 人間承認プロトコル(承認待ち→モバイル通知→再開)を整備
- 着手: ユーザー要望「人間の承認が必要になったらissueにコメント→GitHub Mobile通知→返信を見てタスク再開」の閉ループを作る。
- 前提確認: gh認証=`Ryoki63`(本人)=エージェントも本人として動く → 自己コメント/自己メンションでは通知が出ない。よって別アクター(GitHub Actions bot)からメンションする方式に決定。
- やったこと: (1) ラベル `needs-approval` 作成。(2) `.github/workflows/approval-ping.yml` 追加 — `needs-approval` 付与で github-actions[bot] が `@Ryoki63` メンションコメントを投稿しモバイルへプッシュ。(3) AGENTS.md に「人間承認プロトコル」節を追加(①リクエスト=メンション+隠しマーカー `<!-- lien-agent -->` +ラベル、②bot通知、③ループ冒頭で再開チェック)。(4) LOOP.md に手順0.5(承認待ち再開チェック)を追加し、手順7のブロック処理をプロトコル準拠に更新。
- 判断したこと: 人間とエージェントが同一アカウントで発言するため、両者の区別は隠しマーカーの有無で行う(「bot除く最新コメントがマーカー無し=人間の返信=再開」)。
- 検証: ラベル作成成功・ワークフローYAML構文を確認。bot メンションがGitHub Mobileに実際にプッシュされるかは、テストissueに `needs-approval` を付けてユーザー側で受信確認が必要。
- 結果: 完了(実機プッシュ受信のみ要確認)

## 2026-06-11 02:10 — 植物スプライトv2 style_d「マスコット生き物」制作
- 着手: 第2案スタイル候補の1つ(style_d)を担当。v0は鉢に顔→差し戻し。本体に顔を持たせ生き物キャラ化する。
- 方針: 24×32px・大きい目+白ハイライト+ほっぺ+ちょこんとした手足/葉の耳・丸いシルエット・明るいパレット。キーフレーム6枚(soil/sprout/mid/late/final_normal/final_happy)。
- ラウンド0: 初版生成成功(6枚)。コンタクトシート確認 → v0より大幅改善(本体に顔が乗りマスコット化)。課題: sproutが平たくカエル風/midの目が寄り目/手が見えない/happyとnormalの差が薄い。改良に着手。
- 完了: style_a「ぷにぷにパステル」6キーフレーム(soil/sprout/mid/late/final_normal/final_happy)+8倍コンタクトシート生成。24×32px・依存ゼロPython
- 改良4ラウンド(各回Readで自己視認): R1 顔を植物本体=ミントのぷにブロブに移し顔つきキャラ化 → R2 ボディが鉢に「すわる」よう底をリムに重ね/目を大きくうるうる(白ハイライト2点)に/花を左右対称に整理/胴を成長で拡大(小中大) → R3 全フレームの鉢の底を同じ高さ(row30)にそろえ成長アニメで足元が動かないよう統一/双葉をまるく → R4 crown↔body をつなぐ茎を追加し「冠が浮く」問題を解消、1体のキャラとして統一
- 他ディレクトリ・v0は無改変(git status で v2_drafts/ のみ新規を確認)。git操作はオーケストレータに委譲
- ラウンド1: 顔ヘルパーを大きい目+つや+ほっぺに刷新、happyは開口笑顔に。sproutを縦長まるブロブ+くるん芽に作り直し。手を体外にはみ出させた。
- ラウンド2: 目ハイライトを左右対称に修正(つやめく大きな目)。lateの三つ葉冠と体をふっくら&すっきり整え、顔を中央へ。
- 結果: 完了。6枚すべて丸い+大きい目+ほっぺ+葉の手の一貫したミニ生き物に。final_happyは開口笑顔+きらきらでnormalとの差を明確化。v0(鉢に顔)から愛着面で大幅改善。

## 2026-06-11 (対話) — 【節目】#49 v2スプライト4スタイル完成+成長カーブ案+#40再提出
- 体制(再掲整理): 上の交錯した着手ログ(64-86)は4並列デザイナーの同時追記によるもの。実態は style_a/b/c/d を各デザイナーが並列制作し、各自が出力PNGを Read で自己視認→2回以上改良した
- 成果物(全て products/lien/assets/plant/v2_drafts/ 配下、24×32px・依存ゼロPython・各6キーフレーム+8倍コンタクトシート1264×288):
  - style_a ぷにぷにパステル(自己評価8/10)/ style_b レトロたまごっち(9/10)/ style_c ゆるかわくすみ(8.5/10)/ style_d マスコット生き物(9/10)
  - growth-curve-proposal.md: 6段階60日→**10段階・対数カーブ(最大280日≈9ヶ月)**へ。短期は数日ごと・後半は数十〜数百日。最終形態=色3種+1周年レアの4バリエ(罰なし原則で育て方分岐は不採用)。v1.1の別品種課金と棲み分け。閾値は配列1本で調整可
- オーケストレータQC: 4枚すべて私(対話セッション)が Read で目視確認。全案とも「顔が植物本体・大きい目+ほっぺ・丸シルエット」を満たしv0から明確改善。比較講評: a=最も万人向けにやわらか / b=視認性最強・小サイズで崩れない / c=最も「静かな世界観」に合う大人可愛い(やや低コントラスト) / d=最も擬人化が強くミニ生き物感
- アートディレクタ的結論(参考意見): ウィジェット主役=極小表示で崩れない b、または世界観適合の c を軸に推す。ただし最終はユーザーのトーン選定(#40)
- 検証: 全style gen.py が python3 で再実行可能・6枚+シート生成を確認。v0(assets/plant/png 等)とCI対象は無改変(git status で v2_drafts/ 新規のみ)
- 次: commit+push → #40 に4画像+成長カーブ要約を再提出 → needs-approval でユーザーへ通知 → トーン選定待ち。選定後フェーズ2(全コマ制作+REQUIREMENTS §3.9改定)は別issue

## 2026-06-11 (対話) — 残タスク実行計画の策定+各issueへ進め方を記載
- 着手: ユーザー指示「残りのタスクも進めていきたい。進め方をissueに書き込んでおいて」
- 方針: TASKPLAN/DESIGN/現コードを基に、open中の実装タスク全件の進め方(依存・着手可否・手順・検証)を並列分析 → 依存グラフの整合検証 → Wave割り当て → 各issueにコメント+全体計画を記録 → BACKLOG をWave順に更新
- 実行: Workflowで26タスクを並列分析(各エージェントがTASKPLAN/DESIGN/実コードを読込)→ 敵対検証2本(依存グラフ照合・実コード整合)が18件の補正を指摘 → チーフプランナーがWave 4〜11に統合。計29エージェント
- 結果:
  - **全体計画issue #50 作成**(Wave表・クリティカルパス・人間ゲートTODO・レーン/共有資源オーナー表)
  - **26 issue すべてに進め方コメント投稿**(Wave/レーン/依存/着手可否/手順/検証/リスク+敵対検証の補正)
  - **方針転換: モックファースト** — G0待ちで停滞せず、T10〜T24をプロトコル抽象+モック注入で前倒し(CI緑まで完結)。実Supabase結線はT08後に一括、T20実機E2Eで検証。TASKPLAN §7 に改定ノート追記
  - **BACKLOG.md にWave 4キュー20件**を3レーン(ios-serial直列16 / infra並列 / docs・marketing並列)で積載
  - 重要発見(T08分析): iOSにremote notification登録コードが皆無=このままではG1計測が物理的に不可能 → 「T08準備②pushトークンハーネス」をWave 4に挿入して解消
  - クリティカルパス: G0(#38) → T08 → T20 → T27 → T28(Beta審査1〜2日) → G3。**G0の1日遅れがそのままG3遅れ**(Pairy終了06-30前の配布が目標)
- 検証: 敵対検証18件の指摘(migration連番の衝突、messages.ts文言オーナー重複、PlantSprite二重作成リスク等)をWave割当・オーナー表に反映済み
- 結果: 完了(commit+push後、Wave 4実行はユーザーのGOまたは次ループで着手)

## 2026-06-11 (対話) — G0部分解放: Supabaseプロジェクト作成 → T08バックエンド前倒し
- 着手: ユーザーがSupabaseサインイン+プロジェクト作成完了(ref: lniheehfbtpfhglinfjm)。Apple Developer加入はまだ
- 方針: いま可能になった範囲を即消化 — CLI認証確認 → config.toml作成+link → migration適用 → functions 7本デプロイ → 匿名サインイン有効化 → curlスモークテスト(APNs secretsはApple Developer待ちのため後回し、pushスキップ動作を確認)
- 判明: CLIは未認証(ダッシュボードサインインのみ)。非TTYで `supabase login` 不可 → ユーザーにターミナル実行 or トークンを.envへ、を依頼(#8コメント)
- 実施: その間にT08準備①(トークン不要分)をエージェント委譲 → config.toml(verify_jwt=false×7)+deploy.sh+lien-deploy.yml+G1ハーネス(seed/measure/RUNBOOK)+.env.example を作成・検証・commit+push(20eacd5)
- 発見: promises書込はservice_roleのみ=G1 seedにSERVICE_ROLE_KEY経路必須 / checkinは同日冪等→計測はcheckin→cancel→checkin方式 / 匿名サインイン=POST /auth/v1/signup 空data

## 2026-06-11 (対話) — G2第2回差し戻し「まだキモい」→ ヒアリング → v3制作+T10並行着手
- 差し戻し: v2の4案とも「まだキモい」。対話でヒアリング実施
- ユーザー回答: 最寄り案=**B レトロたまごっち** / キモい主犯=**全部**(顔・ドットの粗さ・形・色)/ 製法=**高解像度ドット絵**
- v3方針: 48×64px級・Bの太輪郭路線を踏襲・**手描きグリッド廃止→プロシージャル描画**(幾何計算→パレット量子化→輪郭抽出→セルシェード)で対称性と造形品質を計算で保証。v3_drafts/style_{e,f,g} の3バリエを並列制作(各デザイナー自己視認3回以上改良)
- 並行: Wave 4 レーンA先頭の T10(匿名認証+オンボ3画面)もエージェント着手(ios/のみ・アセットと無競合。検証はCI)
- 節目: v3 style_e(クラシックたまごっちHD 8/10)・style_f(モダンレトロ 8.5/10)完成→私の目視QCでも両案v2から劇的改善(fが最有力)。style_gは初回タイムアウト→再起動して制作中
- 節目: T10実装完了(supabase-swift SPM/オンボ3画面/テスト13件)→ commit 50eb461 → **lien-ios CI 初回緑** → #10 close(実Supabase疎通はT08持ち越しを明記)
- 続行: レーンA直列の次=T08準備②(AppDelegate+pushトークンDEBUG表示+aps-environment entitlement)に着手
- 節目: T08準備②完了(commit 633125e・lien-ios CI緑)。G1計測の前提=実機トークン取得UIが整った
- 節目: style_g(ちびもちマスコット 8/10)完成・目視QC合格 → commit+push
- 締め: **#40へv3の3案(E/F/G)を再々提出**+needs-approvalラベル再発火(モバイル通知)。成長カーブ案は前回提示のまま有効と明記。トーン選定待ち
- 本日のWave 4進捗: T10完了(#10 close・CI初回緑)/ T08準備①②完了(#8は開いたまま)/ 次=T11(招待UI+web/invite)はトーン選定と独立に進行可

## 2026-06-11 (対話) — T08実行: Supabaseトークン投入→デプロイ+スモークテスト / T11並行着手
- 着手: ユーザーが .env にアクセストークンを投入(「はいよ!」)。CLI認証確認→link→migrate→functions 7本デプロイ→匿名サインイン有効化→スモークテストへ
- 並行: T11(招待UI+web/invite)をエージェント着手(レーンA直列の順番どおりT10完了後)
- 実施: CLI認証OK(projects list成功)→ link成功 → migration適用は**Management API /database/query 経由**(ローカルCLIのfunctions deploy系はGoバイナリ欠落・DBパスワード未取得のため)。全11テーブル+RLS12ポリシー+migration履歴記録を確認
- 実施: functions 7本は **lien-deploy.yml(CI)経由でデプロイ成功**(SUPABASE_ACCESS_TOKEN をrepo secretsに登録)。Anonymous sign-ins をManagement APIで有効化。APIキーは .env.keys(gitignore対象)に保存
- 検証: **スモークテスト全緑** — seed-pair.sh(匿名×2→ペア成立→約束seed)→ checkin 200(todayMeDone: true)→ snapshot 200(ペア・植物状態正常)。APNs はsecrets未投入のためスキップ(設計どおり)
- 結果: **T08のエージェント側作業は完了**。#8の残り=Apple Developer加入→APNs secrets→実機G1計測(人間)。#38の残りはApple Developer加入のみ。Cloudflare対策(UA必須)とCLI Goバイナリ欠落の知見をissueに記録
- 節目: **T11完了**(commit 6eafd27・lien-ios CI初回緑)→ #11 close。招待3導線+DeepLink+web/invite静的ページ。残作業=実HTTP結線(T08後)とPages配備(G3前)を#11に記録
- 続行: レーンA次=T12(約束設定UI+functions promise-set)に着手。promise-setはスモークでservice_role直書きしていた約束作成の正式API化でもある
- 節目: **T12完了**(commit 8427dec・deno 153件緑・iOS CI緑・ともに初回パス)→ #12 close。**promise-set を本番デプロイ**(live 8本)。続けてT13(ホーム画面)へ — トーン未定のためv0スプライトをプレースホルダ使用(G2確定後に差替)

## 2026-06-11 (サブエージェント) — T08準備①: デプロイ自動化+G1計測ハーネス (#8/#50 レーンB)
- 着手: config.toml / deploy.sh / lien-deploy.yml / g1ハーネス(seed-pair.sh, measure.sh, RUNBOOK.md) / .env.example を整備する(実行はしない。git操作はオーケストレータ)
- 事前確認済み: 7関数すべて自己認証(checkin/cancel/snapshot/invite系=adminClient.auth.getUser、close-day/grant-tickets=SERVICE_ROLE_KEY完全一致)→ 全関数 verify_jwt=false が正しい。apns.ts env名= APNS_AUTH_KEY/APNS_KEY_ID/APPLE_TEAM_ID/APNS_ENV/APNS_TOPIC、未設定時はpushスキップ+warn(全index.tsで確認)
- 成果物: ①supabase/config.toml(project_id=lniheehfbtpfhglinfjm+7関数verify_jwt=false) ②scripts/deploy.sh(冪等: 前提チェック→link→db push→7本deploy、DRY_RUN対応) ③.github/workflows/lien-deploy.yml(workflow_dispatch専用・CLI 2.105.0固定) ④scripts/g1/seed-pair.sh(匿名×2→invite-create/accept→push_token PATCH→promises seed) ⑤scripts/g1/measure.sh(checkin→目視Enter→cancelの10回ループ+p50/p90+JOURNALスニペット) ⑥scripts/g1/RUNBOOK.md(G0残作業〜G1の人間手順・所要時間付き) ⑦.env.example
- 設計判断: (a)匿名サインイン=POST /auth/v1/signup に email/phone なし {"data":{}}(auth-js signInAnonymously実装をWebFetchで確認) (b)checkinは同日冪等でpush再発火しない→計測は checkin→cancel→checkin 方式(cancelのサイレントpushは配送保証なし→ラウンド間にBのアプリを開いて自己修復) (c)promisesはservice_roleのみ書込可(migration 0001確認)→seedにSERVICE_ROLE_KEY経路を追加(無いとcheckinが409 no_promise)
- 検証: bash -n 3本OK / config.toml=deno @std/toml でパース+内容assert / lien-deploy.yml=deno @std/yaml でパース+dispatch専用assert / deploy.sh DRY_RUN実走(CLI 2.105.0検出・トークン未投入の停止メッセージ正常) / 集計・JSONヘルパをpython3.9で単体実行 / 既存CI干渉なし(lien-ios=ios/**のみ、lien-deployは手動専用、.gitignoreは.env除外済みで変更不要)
- 注意点: ローカルmacの supabase コマンドはshimのみで supabase-go 実体欠落 → ローカルdeployは要再インストール(CIは setup-cli で問題なし)
- 結果: 完了(git操作なし。コミットはオーケストレータ)
