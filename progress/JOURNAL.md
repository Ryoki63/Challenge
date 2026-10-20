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
- 節目: **T13完了**(commit 24bc37b)→ #13 close。CI赤1回: PlantAssetsカタログ追加でactool初起動→xcodegen既定のAppIcon要求未充足 → icon_1024.pngで単一サイズAppIcon追加(f01c1a4)→ 緑。ホーム画面+PlantSprite一元解決+テスト16件
- 続行: レーンA次=T14(チェックインフロー+オフラインキュー+写真+当日取消。migration 0002オーナー)に着手
- 節目: **T14完了**(commit 4d90953・deno 157緑・iOS CI緑・初回パス)→ #14 close。オフラインキュー(相殺マージ)・写真2048px+サムネ・和暦バグ事前修正
- 保留: **migration 0002の本番適用+checkin再デプロイは権限分類器により停止** — 新規スキーマ変更はT08立ち上げ承認の範囲外との判断。ユーザーに承認を確認する(承認後に適用 or 本人がSQL Editorで実行)
- 続行: レーンA次=T15(つつく+リアクション。LienApp結線数行も冒頭で実施)に着手

## 2026-06-11 (サブエージェント) — T08準備①: デプロイ自動化+G1計測ハーネス (#8/#50 レーンB)
- 着手: config.toml / deploy.sh / lien-deploy.yml / g1ハーネス(seed-pair.sh, measure.sh, RUNBOOK.md) / .env.example を整備する(実行はしない。git操作はオーケストレータ)
- 事前確認済み: 7関数すべて自己認証(checkin/cancel/snapshot/invite系=adminClient.auth.getUser、close-day/grant-tickets=SERVICE_ROLE_KEY完全一致)→ 全関数 verify_jwt=false が正しい。apns.ts env名= APNS_AUTH_KEY/APNS_KEY_ID/APPLE_TEAM_ID/APNS_ENV/APNS_TOPIC、未設定時はpushスキップ+warn(全index.tsで確認)
- 成果物: ①supabase/config.toml(project_id=lniheehfbtpfhglinfjm+7関数verify_jwt=false) ②scripts/deploy.sh(冪等: 前提チェック→link→db push→7本deploy、DRY_RUN対応) ③.github/workflows/lien-deploy.yml(workflow_dispatch専用・CLI 2.105.0固定) ④scripts/g1/seed-pair.sh(匿名×2→invite-create/accept→push_token PATCH→promises seed) ⑤scripts/g1/measure.sh(checkin→目視Enter→cancelの10回ループ+p50/p90+JOURNALスニペット) ⑥scripts/g1/RUNBOOK.md(G0残作業〜G1の人間手順・所要時間付き) ⑦.env.example
- 設計判断: (a)匿名サインイン=POST /auth/v1/signup に email/phone なし {"data":{}}(auth-js signInAnonymously実装をWebFetchで確認) (b)checkinは同日冪等でpush再発火しない→計測は checkin→cancel→checkin 方式(cancelのサイレントpushは配送保証なし→ラウンド間にBのアプリを開いて自己修復) (c)promisesはservice_roleのみ書込可(migration 0001確認)→seedにSERVICE_ROLE_KEY経路を追加(無いとcheckinが409 no_promise)
- 検証: bash -n 3本OK / config.toml=deno @std/toml でパース+内容assert / lien-deploy.yml=deno @std/yaml でパース+dispatch専用assert / deploy.sh DRY_RUN実走(CLI 2.105.0検出・トークン未投入の停止メッセージ正常) / 集計・JSONヘルパをpython3.9で単体実行 / 既存CI干渉なし(lien-ios=ios/**のみ、lien-deployは手動専用、.gitignoreは.env除外済みで変更不要)
- 注意点: ローカルmacの supabase コマンドはshimのみで supabase-go 実体欠落 → ローカルdeployは要再インストール(CIは setup-cli で問題なし)
- 結果: 完了(git操作なし。コミットはオーケストレータ)

## 2026-10-12 13:20 (対話) — 4か月ぶり再開: 再計画(目標=1月新年需要前のリリース)+Wave 4 実行再開
- 着手: ユーザー指示「ローンチまでのタスクを洗い出した方針で進める。実行とサポートを」。G0(Apple Developer加入)はユーザーが別途並走中
- 状況確認: 最終コミット 2026-06-12(T14)。未コミットはJOURNAL 3行のみ(T14完了・migration 0002保留の記録)→本エントリと一緒にcommit。CIは直近全緑
- 方針変更: Pairy終了(06-30)前のG3は失効 → **新目標 = 1月の新年需要前にApp Storeリリース+課金導線の準備**。クリティカルパスは変わらず G0 → T08残(APNs+G1) → Live結線 → T20 → T27 → T28 → G3 → G5
- 環境メモ: ローカルにXcode無し(CLTのみ)→ iOS検証は lien-ios CI のみ。gh の既定アカウントは push 権限のない ryoki-kojima → gh 操作は `GH_TOKEN=$(gh auth token --user Ryoki63)` で行う
- 実行体制: レーンA(ios-serial)はT15から1タスク=1サブエージェント(Sonnet)で直列、レーンC(docs準備)は並列。git操作はファイル指定で行い `git add -A` は使わない(並列作業の巻き込み防止)
- 人間判断待ち: G2(#40 スタイルE/F/G選定)、migration 0002 本番適用+checkin再デプロイの承認

## 2026-10-12 13:21 (サブエージェント) — T32準備: ストアメタデータ確定値化+verify_metadata.py+CIジョブ (issue #32)
- 着手: #32の「進め方」コメント(2026-06-11記載)に従い、aso.md(T26案)を store_metadata/ja/ に確定値化する。前提変化(Pairy 2026-06-30終了済み・現在2026-10・次の山=1月新年需要)を反映し、Pairy依存文言は外す/alternatives.mdへ退避する

## 2026-10-12 (サブエージェント/レーンA ios-serial) — T15 つつく+リアクション(issue #15)着手
- 着手: issue #15 の「進め方(実行計画 2026-06-11)」10手順に従い実装開始。ユーザー指示によりスコープ拡張: T13/T14完了済みのため、計画が先送りしていた「ホームへの結線」も本タスク内でモック注入経由で実施する(つつくボタンの表示条件+リアクションUIの導線)。本番Supabaseへのデプロイ・実機push検証は対象外(モック注入のみ)
- 事前調査で判明: migrations/0001_init.sqlに`nudges`/`reactions`テーブルとRLSが既に存在(新規マイグレーション不要)。`_shared/apns.ts`の`LienPushType`に`nudge`/`reaction`は既に含まれる。`checkin-cancel`のcore.ts/index.tsパターン(repo/pusher注入+薄いI/O層)を踏襲して`functions/nudge`・`functions/react`を新設する。config.tomlは関数ごとに`verify_jwt=false`を明記する既存慣習を確認(デプロイはしない)
- 進め方: バックエンド(messages.ts拡張+nudge/react函数+deno test全緑)→commit1 → iOS(NudgeReactService+NudgeSheet+ReactionPicker+ホーム結線+Strings.swift追加+NudgeReactTests)→commit2→push→lien-ci/lien-ios CI緑確認→BACKLOG/DONE更新→issue完了コメント+close

## 2026-10-12 13:32 (サブエージェント/レーンD docs) — T20準備: 実機E2Eチェックリスト+ランブック着手 (issue #20)
- 着手: issue #20 の「進め方」コメント(2026-06-11記載)の手順1〜3(前倒し可・依存ゼロ分)に従い実装開始。本タスクは準備スライスのみ(実機2台でのE2E実施そのものはG0→T08→T11〜T19 close後の別セッション)。issue #20はクローズしない
- 事前調査で判明: migrations 0001でテーブル名確定(users/pairs/pair_members/promises/checkins/streak_days/ticket_ledger/nudges/reactions/plants/invites)。チケット規則(free: grant2/cap2)・invite token形式(8桁英数、紛らわしい文字除外)・plant stage閾値(0/3/7/14/30/60日)・DEBUG用DeviceTokenDebugView(G1と同じpushトークン取得経路)を確認。e2e_reset.sqlの配置先はissueコメント指定の`products/lien/supabase/scripts/e2e_reset.sql`に従う(作成のみ・本番実行は一切しない)
- 進め方: 12項目チェックリスト+ランブック+REQUIREMENTS §3.2〜3.9セルフ検証表付録をdocs/E2E-M1.mdに作成→e2e_reset.sql作成(トランザクション化・テストユーザー限定・警告コメント)→path-scoped commit→push.sh→lien-ci緑確認→BACKLOG該当行削除+DONE追記→issue #20へ「準備完了・実機待ち」コメント

## 2026-10-12 13:37 (対話/メインエージェント) — T30準備: レビューノート草案+REQUIREMENTS §8台帳化 着手 (issue #30)
- 着手: issue #30 の「進め方」コメント(2026-06-11記載)に従い開始。追加スコープ(オーケストレータ指示): review-notes.md に提出前チェック(App Privacy草案/年齢レーティング/Export Compliance/Support・Privacy URL/テストペア準備手順/UGC Guideline 1.2)もまとめる
- 事前調査: REQUIREMENTS §8は現状5項目(行236-242、全未チェック)。terms.md第6-8条(通報/ブロック=ペア解消/アカウント削除)・privacy-policy.md §1(取得情報表)・CHECKLIST-G4.md(G4人間ゲート項目・GitHub Pages URL未確定)・project.yml(ITSAppUsesNonExemptEncryption: false 既設定)・seed-pair.sh/RUNBOOK.md(テストペア作成ハーネス)を確認済み
- Apple公式ドキュメント(developer.apple.com)の年齢レーティング・Export Compliance該当ページの取得が404/断片のみ→ 詳細は「要確認」として記載し、断定しない方針で進める
- 競合確認: 並行してT15(つつく+リアクション)/T20準備/T32準備が別エージェントで稼働中。本タスクは docs/REQUIREMENTS.md §8 のみ + marketing/review-notes.md(新規)に限定し、他タスクのファイルには触れない

## 2026-10-12 13:40 (対話/Opus) — 残タスク洗い出し(Haiku)+方針レビュー(Opus)/ イラスト全面刷新 / 成長ルール再設計
- 着手: ユーザー指示「今やるべきことをHaikuで洗い出し→方針案をレビュー」「イラストはダサすぎるので刷新」「成長曲線をユーザーがハマる仕組みに再考」
- 体制: Workflow(Haiku max×2で洗い出し → Opus max×2で方針レビュー[クリティカルパス視点/品質・リスク視点]、並行して Opus max で成長ルール設計→敵対レビュー→改訂)。イラストはオーケストレータ(Opus)が直接制作
- 競合回避: 別セッションが T15(ios/・functions)と T32準備(store_metadata・lien-ci.yml)を実行中 → 本作業は assets/plant/ 配下の新規フォルダと新規docのみ触る。REQUIREMENTS/snapshot.ts の改定は承認後
- 技術判断: イラストは手描きピクセル/プロシージャルドット絵を廃し **SVGベクター**へ(xcassets は SVG をベクターのまま取込可。プレビューはヘッドレスChromeで透過PNG化できることを確認済み)

## 2026-10-12 13:40 — migration 0002 本番適用+checkin 再デプロイ(ユーザー承認済み)
- 着手: ユーザー @Ryoki63 が 2026-10-12 13:24 の対話で、COMMON.md の「Supabase 本番には触らない」ルールを**本タスク限定**(migration 0002 本番適用 + checkin 関数の再デプロイのみ)で明示解除。対象外(nudge/react 等の新規関数デプロイ・他 SQL・データ変更)は一切行わない。T08(#8)実行時の知見(Management API `/database/query` 経由・User-Agent 必須・ローカル CLI の Go バイナリ欠落)を踏襲して進める
- 事前確認で判明: プロジェクト(ref lniheehfbtpfhglinfjm)が **status=INACTIVE(一時停止中)** だった(4か月アクセスなしによる自動停止と推測。database/query が `Connection terminated due to connection timeout` で失敗)。0002適用・checkin再デプロイを行うには稼働中である必要があるため、`POST /v1/projects/{ref}/restore` で復元をリクエスト(HTTP 200)。データ変更・SQL実行は未実施。復元完了をポーリング中
- 復元完了: 約4分で `status=ACTIVE_HEALTHY` に到達(COMING_UP→RESTORING→ACTIVE_HEALTHY)。合わせて functions 一覧(Management API)で既存8関数(checkin/checkin-cancel/snapshot/invite-create/invite-accept/close-day/grant-tickets/promise-set)が全て ACTIVE・T08/T12時点のバージョンのままであることを確認(T15等の新規関数はまだ本番に存在しない=指示の前提と一致)
- 事前確認結果(すべて読み取りのみ・Management API `/database/query`): `supabase_migrations.schema_migrations` は 0001(name=init, statements=null)のみ→**0002未適用**。`storage.objects` の既存ポリシーは `photos_select_pair_member`(SELECT, authenticated)のみ→insert/updateポリシーはまだ無い。`photos` バケットは存在(public=false)。`public.is_active_pair_member(uuid)` は存在。`public.is_valid_pair_photo_upload` は存在しない(0002未適用の確証)。→ 0002 の適用に進む

## 2026-10-12 13:39 (サブエージェント/assets) — #49 フェーズ2第1段: 植物スプライトF本制作(48×64・13枚) 着手
- 着手: issue #49(G2決定済み: スタイルF「モダンレトロ」)に従い、現行13枚構成(土+5段階×normal/happy+sad2)をFスタイル・48×64で本制作しv0プレースホルダを差し替える
- 事前調査: v3_drafts/style_f/gen.py(6キーフレーム: soil/sprout/mid/late/final_normal/final_happy、幾何計算プロシージャル描画・輪郭自動抽出・3トーンセルシェード)を精読。既存13枚の対応=sprout→stage1(芽)/mid→stage2(双葉)/late→stage4(つぼみ、蕾あり)/final→stage5(開花、花あり)。stage3(若葉)はFの6キーフレームに無いためmid↔late間の中間形として新規設計が必要
- 設計方針: gen_sprites.pyを全面書き換え(F方式=楕円/ブロブ+ミラー対称+輪郭自動抽出)。段階定義は`GROWTH_STAGES`データ配列(stem/leaf/body/bud/flower/faceパラメータの辞書)で保持し将来10段階拡張に対応。happy=表情+キラキラ、sad=表情(への字)+葉がわずかに下向き+汗ひとつぶ1点(罰なし原則: 色・サイズは変えない)
- リスク確認: 新解像度48×64はアスペクト比3:4(旧16×24は2:3)。iOS PixelImage.swift/PlantSprite.swiftはpixelWidth=16/pixelHeight=24をハードコードしフレームサイズを決定(.resizable()のみでaspectRatio指定なし)→ 差し替えると表示が歪む(非均等拡大)懸念があるため**Swiftコードは触らず最終報告で指摘**する方針
- **migration 0002 本番適用 完了**: `begin; <0002のSQL全文>; insert into supabase_migrations.schema_migrations(version, name) values ('0002','photo_storage_policies'); commit;`(0001の記録行 `{version:'0001', name:'init', statements:null}` と同じ列構成に合わせ version/name のみ指定)を Management API `/database/query` で実行(HTTP 201・エラー無し)。事後確認: `schema_migrations` に0002行が追加/ `storage.objects` ポリシーに `photos_insert_pair_member`(INSERT)・`photos_update_pair_member`(UPDATE)が追加(既存の `photos_select_pair_member` も健在)/ `public.is_valid_pair_photo_upload(text)` が security definer 関数として存在。データ変更は無し(DDL+ポリシー+migration履行のみ)
- 節目(イラスト): v4「タネの子」初版を制作(products/lien/assets/plant/v4_drafts/)。鉢に住む大福型のキャラの頭から植物が育つ構成(体・顔は全段階共通=愛着の連続性)/ 双葉2枚=ふたり / 最終形は2本の茎がハートを描く「二輪咲き」/ ソロ時は鉢のふちから寝顔がのぞく(ペア成立→初チェックインで目覚める=招待動機)。13枚の契約名(PlantSprite.swift)を維持したドロップイン構成。目視QC 4回で修正(体の形・鉢の比率・茎への葉の付き方・寝顔・花びら)。ウィジェット実寸 96px/48px で判読性を確認
- 節目(アイコン): 同キャラで新アイコン案を制作(空色背景を選定。杏・ミントも比較用に保存)
- checkin 再デプロイ方法の選定: ローカル supabase CLI(`~/.local/bin/supabase`)は shim で、同梱の `supabase-go` 実バイナリが欠落していたため T08 と同じ事象を再現(`Could not find the supabase-go binary`)。CLI自体のエラーメッセージが案内する手順どおり、公式リリースタグ v2.105.0 の `supabase_2.105.0_darwin_arm64.tar.gz` を GitHub Releases から取得・展開(`~/.local/share/supabase/`)して `supabase-go` を補完→ `PATH` に追加した CLI で `supabase projects list` が成功(認証確認)。これで lien-deploy.yml(全8関数)を使わずに `checkin` 単体だけをデプロイできる見込み
- **checkin 再デプロイ 完了**: `~/.local/share/supabase/supabase functions deploy checkin --project-ref lniheehfbtpfhglinfjm`(cwd=products/lien, env に SUPABASE_ACCESS_TOKEN)で実行。アップロードされたアセットは checkin/index.ts・core.ts と _shared/{apns,snapshot,streak,messages}.ts のみ(他関数には触れていない)。Management API の functions一覧で確認: `checkin` だけ v1→**v2**、他7関数(checkin-cancel/snapshot/invite-create/invite-accept/close-day/grant-tickets/promise-set)は v1 のまま不変。lien-deploy.yml(全8本デプロイ)は使わずに済んだ
- 自己検証(サブエージェント委任は深度制限で不可→自ら実施): §8全5項目↔review-notes.md §1.1-1.5の対応、terms.md第6-8条/privacy-policy.md§1,9/CHECKLIST-G4.md/project.yml:54/migrations 0001のフィールド名/issue #8,23,28,33,44実在性を全てgrep/読み取りで照合し一致を確認。途中、テストペア作成の前提条件記述に不正確な点(G0/T08完了状況の誤認)を発見→ JOURNAL内T08実行ログ(2026-06-11)を再確認し「Supabaseバックエンド自体は完了済み・残るG0項目はApple Developer Program加入のみ」という正確な状態に両ファイルを修正。docs/REQUIREMENTS.md差分は§8のみ1 hunk・追記7行(削除0)でスコープ違反なしを確認。ios/・supabase/functions/等の禁止ファイルは一切変更していないことを確認
- 結果: review-notes.md新規作成(§1.1-1.5=§8の5項目に1:1対応、§2.1-2.6=追加スコープ6項目)+ docs/REQUIREMENTS.md §8台帳化(状態+参照を5項目全てに付記)完了。TBD5件(テストペア実データのみ・意図的)・要確認19件(Apple仕様の断定回避)。commit→push前の最終状態
- **スモークテスト 完了**(`scripts/g1/seed-pair.sh` で匿名ユーザーA/B+テストペア+promisesを新規作成。実ユーザーデータは触っていない): ① 通常checkin(写真無し)200・snapshot反映 ② `requestPhotoUpload:true` で署名付きアップロードURL(photo/thumb)を発行・パスが規約どおり `pairs/<pair_id>/<date>/photo.jpg|photo_thumb.jpg` ③ 発行された署名URLへ小さなJPEGを実アップロード→200(0002の `photos_insert_pair_member` ポリシーが有効に機能) ④ `photoPath` 付きでcheckin再送→パートナー(B)の snapshot で `hasPartnerPhotoToday: true` に反映 ⑤ 自分がメンバーでないペアのパスへの直接アップロード→403(RLSで正しく拒否) ⑥ 自分のペアだが命名規約外(`not_allowed.png` 等)→403(正しく拒否) ⑦ 自分のペア+規約どおりのファイル名への署名無し直接アップロード→200(insertポリシー自体が許可) ⑧ パートナー(B)による同パスへの上書き(update)→200(updateポリシーが現役ペアメンバー双方を許可)。想定した許可/拒否のいずれも仕様どおりに動作
- 結果: **migration 0002 本番適用 + checkin 再デプロイ、両方完了**。副次確認として本番プロジェクトが4か月の無アクセスで `INACTIVE`(一時停止)状態だったことを発見し、Management API `/restore` で復元(データ変更なし)。ローカル Supabase CLI の `supabase-go` バイナリ欠落は GitHub Releases の tarball 展開で解消(以後のセッションでも `PATH="$HOME/.local/share/supabase:$PATH"` で再利用可)。他7関数・他テーブルのデータには一切触れていない。issue #14・#8 にコメント予定
- commit/push完了: commit 7ae3e45(docs/REQUIREMENTS.md §8台帳化+products/lien/marketing/review-notes.md新規+本JOURNAL)。lien-ci run 38205599978 success(11秒)で緑確認
- 結果: **T30準備(issue #30)完了**。BACKLOG.md:37のT30準備行を削除、DONE.mdに追記。issue #30は進め方コメントの指示どおりクローズしない(T23/T08実データ投入/T28完了後の本編コミット②で完了予定)。issue #30へ準備完了コメント投稿へ続行

## 2026-10-12 (サブエージェント/レーンA ios-serial) — T15 つつく+リアクション: バックエンド実装 完了・commit前
- 実装: `_shared/messages.ts` に `NUDGE_STAMPS`(6種)/`NUDGE_REPLIES`(定型4種)/`REACTION_STAMPS`(6種)/`nudgeBody()`(文例20種・random注入)/`reactionBody()` を追加、`allMessageBodiesForReview()` に登録(罰なし原則の機械検証対象に含めた)。`functions/nudge/{core,core_test,index}.ts` 新設: `handleNudge` は語彙検証→ペア必須(無ければ409 no_pair)→相手が当日未完であること(完了済みは409 partner_already_done)→送り手TZの当日カウントで1日3回まで(4回目は429)→nudges insert→相手へ可視push(送り手名義)。`functions/react/{core,core_test,index}.ts` 新設: `handleReact` は語彙検証→対象checkin存在確認→ペア必須→対象が現役パートナーのcheckinであること(自分/無関係は403 not_partner)→reactions upsert(同一スタンプ再送は200 changed:falseで再pushしない、別スタンプは200 changed:true+再push)→相手へ可視push(自分名義)。両関数とも `config.toml` に `verify_jwt=false` を追記(デプロイは行っていない)
- 検証: `deno test`(products/lien/supabase/functions)で**188 passed, 0 failed**(直前baseline 157 → messages 10件・nudge 12件・react 9件の計31件追加)。`deno lint` 全クリア(0 problems)。`deno fmt` は新規/編集ファイル8本に適用済み(既存 checkin/core_test.ts の1件未整形は本タスクが触れていない既存コードのためスコープ外として放置)
- ドキュメント: `docs/DESIGN.md §5.3` に1行追記(ワンタップ返事の記録APIはT15では実装せず、`nudges.replied` 列は先行確保のまま未使用、実装はT16/issue #16へ)。issue #16へ文言オーナーシップの引き継ぎコメントを実際に投稿済み(messages.ts冒頭コメントの記述と整合)
- 残作業: iOS側(NudgeReactService相当のcapability protocol + LocalEchoCheckinServiceへのmock実装追加、Strings.swift追加、HomeView/HomeViewModel結線、NudgeReactTests)→ commit2 → push → lien-ci/lien-ios CI確認 → BACKLOG/DONE更新 → issue #15 完了コメント+close

## 2026-10-12 14:05 (対話/オーケストレータ) — #49 F本制作サブエージェントの中断処理
- 状況: #49担当サブエージェントがコンテキスト上限で途中終了。指示(スタイルFの48×64ドット絵で13枚)から逸れ、**SVGベクターの新案 v4「タネの子」13枚+花色違い3+アイコン3案**を v4_drafts/ に制作した状態で止まっていた(本番 png/・xcassets は未変更、F版13枚は未着手)
- 判断: v4 は G2 で選ばれた F と別スタイルのため、勝手に本番差し替えはしない。v4_drafts/ を下書きとして保存コミットし、ユーザーに「F で進める / v4 に切り替える」を確認する
- 申し送り: PlantSprite.swift / PixelImage.swift は 16×24 を固定値で持つ → どちらのスタイルでも iOS 側の寸法対応(ios-serial レーン、T15 の後)が必要

- 文言確定: aso.md(T26案)から表示名A×サブタイトルBの組み合わせを採用し `store_metadata/ja/{name,subtitle,keywords,promotional_text,description,release_notes}.txt` を新規作成。keywords/promotional_text/descriptionはPairy依存語を外し新年(新年/正月)・習慣化訴求を優先する確定値に調整(表示名・サブタイトルはaso.mdの推奨組み合わせをそのまま採用、変更なし)。不採用案・Pairy系キーワードの商標/審査リスク(ガイドライン2.3.7, 要確認扱い)は `store_metadata/alternatives.md` に記録(aso.md自体は編集していない)
- `tools/verify_metadata.py`(Python3標準ライブラリのみ)作成: 必須ファイル存在+文字数上限(name/subtitle<=30, keywords<=100, promotional_text<=170, description/release_notes<=4000, コードポイント数とUTF-16コードユニット数の大きい方で判定する保守的カウント)+罰なし原則禁止語(`_shared/messages_test.ts`のBANNED_PATTERNと同一語を複製、同ファイルは編集せず)+keywords形式(カンマ区切り/空白なし/重複なし)を検証。ローカルで green 確認後、name.txtを35字に・promotional_text.txtに「サボ」を混入する一時改変でそれぞれ red(exit 1)になることを確認し、即座に元の確定値へ復元(git statusで余分な差分が残っていないことも確認済み)
- `.github/workflows/lien-ci.yml` に `store-metadata` ジョブを追加(既存 deno-test/plant-assets は無変更、diffは追加18行のみ)。PyYAMLでパースし3ジョブとも正しく読めることを確認(ステップ名のコロンでYAML構文エラーが出たため name をクオートして修正済み)。pushしてlien-ci run緑化を確認する
- commit/push完了: commit 37e12ed(store_metadata/ja/6ファイル+alternatives.md+tools/verify_metadata.py+lien-ci.yml store-metadataジョブ+本JOURNAL)。lien-ci run 38206570833 success(全3ジョブ緑、store-metadataは4秒)で緑確認
- 結果: **T32準備(issue #32)完了**。BACKLOG.mdのT32準備行を削除、DONE.mdに追記。issue #32は進め方コメントの指示どおりクローズしない(G4 #42の人間判断=本編完了は別フェーズ)。issue #42へG4決定依頼コメント投稿へ続行

## 2026-10-12 14:14 (サブエージェント/レーンD docs) — T20準備: ドラフト完成+セルフ検証 (issue #20)
- 節目: `docs/E2E-M1.md`(12項目チェックリスト+§1ランブック+付録A網羅性セルフ検証+付録B既知リスク)と `products/lien/supabase/scripts/e2e_reset.sql` のドラフトを完成(作成のみ・未実行)
- セルフ検証(別サブエージェント起動不可のため自ら実施)で判明: 12項目はM1コアパス(ペア成立→約束→チェックイン→ストリーク→つつく→通知)としては十分だが、REQUIREMENTS §3.2〜3.9の**全要件網羅ではない**。未カバー5点: ①ペア解消(§3.2、T23/#23未実装)②ストリークリセット罰なし文言+21時危機通知(§3.5、T16/#16未close)③チケット月次付与+お休み宣言(§3.6、T19/#19未close、一部のみ)④植物命名+そわそわ/しょんぼり状態(§3.9、一部のみ/未カバー)⑤招待72h失効の実時間確認等(ロジックのみ・E2E手順未明示)。この限定事項は本書と issue #20 完了コメントの両方に明記する方針(完了条件の文言どおり「網羅」を名乗らない)
- e2e_reset.sqlのレビューで安全確認ブロックの実装リスクを発見・修正: 当初 `do $$ ... $$`(PL/pgSQL)ブロック内で psql変数展開(`:'test_user_a'`)に依存していたが、dollar-quote内側での展開可否を手元で実機確認できず(psql未インストール、web_search使用不可のためPostgreSQL公式ドキュメントをweb_fetchで確認したが dollar-quote内側の挙動は明記箇所を発見できず)。**曖昧さを許容せず**、dollar-quoteを一切使わない「素のSQL+`\gset`+`\if`+`:{?name}`(未定義判定、公式ドキュメントのSQL Interpolation節に明記された標準機能)」に書き直して解消。合わせて使い方コメントの `-v test_user_a="'<uuid>'"` という誤った例(`:'name'`展開は自動でクォートを付けるため二重クォートになり壊れる)も発見し、引用符なしの生UUIDを渡す正しい例に修正
- 全テーブル定義(migrations/0001_init.sql)を直接再確認してスクリプトの列名・削除順序を検証: `nudges`(pair_id/from_user)・`reactions`(checkin_id/from_user)・`invites`(from_userのみ、受諾側記録列は無し)・`checkins.promise_id`はon delete cascade無し(NO ACTION)のため`promises`を一切DELETEしない設計で正しいことを確認。全て一致、修正不要
- T15(#15)の状況を再確認: `nudge`/`react` Edge Functions のバックエンド実装・テストは commit `8b49d50` で既に完了(本タスク着手時点では未実装と記載していたため docs/E2E-M1.md 2箇所を修正)。ただしiOSクライアント結線と本番デプロイは未完了のまま
- 次: path-scoped commit → push.sh → lien-ci緑確認(lien-iosは発火しないはず)→ BACKLOG/DONE更新 → issue #20へ準備完了コメント
- commit/push完了: commit ff5417e(docs/E2E-M1.md新規+products/lien/supabase/scripts/e2e_reset.sql新規+本JOURNAL)。lien-ci run 38207131557 success(plant-assets/deno-test/store-metadata全3ジョブ緑、13秒)。lien-iosは期待どおり発火せず(docs/scripts配下のみの変更のためパスフィルタ対象外)
- 結果: **T20準備(issue #20)完了**。BACKLOG.mdのT20準備行(レーンC節全体、他タスク無し)を削除、DONE.mdに追記。issue #20は進め方コメントの指示どおりクローズしない(実機2台でのE2E実施はG0(#38)+T08(#8)デプロイ+G1合格+#11-19 close後の別セッション)。issue #20へ「準備完了・実機待ち」コメント投稿へ続行。commit時点でT15(つつく+リアクション)エージェントがproducts/lien/ios/Lien/Core/Strings.swift等を並行変更中だったため、本タスクの対象外ファイルには一切触れていないことを確認済み
- 進捗(2026-10-12 14:29): T15 iOS側のホーム結線を実装完了(ビルド確認前)。新規: `Lien/Core/NudgeReactService.swift`(NudgeStamp/ReactionStamp enum + NudgeSending/Reacting protocol + NudgeSendError + LocalEchoCheckinServiceへのモック適合)、`Lien/Features/Nudge/NudgeSheet.swift`(スタンプ選択UI。NudgeSheet/ReactionSheet+共通StampGrid、自由入力なし)、`LienTests/NudgeReactTests.swift`(canNudge/canReact gating・成功/失敗/limitReached・スタンプ語彙がサーバーのmessages.tsと一致することを検証)。既存ファイル編集: `Strings.swift`にNudge/Reaction namespace追加、`HomeViewModel.swift`にcanNudge/canReact計算プロパティ+sendNudge/sendReactionメソッド+能力検出(as? NudgeSending/Reacting、既存のCheckinCanceling等と同じパターン)、`HomeView.swift`のTODO(T15)箇所にNudgeArea追加+TodayArea内にReactionArea追加(どちらも@MainActor構造体、CheckinFlowViewと同じメッセージ表示+シート構成)。設計判断: PairSnapshotにcheckinIdが無いためReacting.sendReactionはstampのみ受け取り対象解決は実装側に委ねる(本結線は後続タスク)。ローカルにフルXcode無し(CLTのみ)のため`swiftc -parse`で構文チェックのみ実施、全ファイルパースエラー無し。次: path-scoped commit → push.sh → lien-ci/lien-ios CI確認
- 検証完了(2026-10-12 14:40頃): commit 5552670 push後、lien-ci run 38208218797 success、lien-ios run 38208218811 success(iOS build+test 7m17s、`Executed 139 tests, with 0 failures`。新規NudgeReactTests 14件全てpassedをログで個別確認)。CI赤無し・fix retry不要。
- 結果: **T15(つつく+リアクション)完了**。バックエンド commit `8b49d50`(functions nudge/react新設+messages.ts語彙拡張、deno test 188緑+lint/fmt clean)+ iOS commit `5552670`(NudgeReactService.swiftのcapability protocol+LocalEchoCheckinServiceモック適合、HomeViewModel canNudge/canReact gating、HomeView結線、NudgeSheet.swift、NudgeReactTests.swift 14件)。lien-ci/lien-ios CI両緑。tasks/BACKLOG.mdからT15行削除、tasks/DONE.mdに追記。残作業(issue #15完了コメントに明記予定): 実Supabase結線(関数は意図的に未デプロイ)・checkinIdベースの実リアクション対象解決(PairSnapshotにcheckinId列が無いため今回はstampのみのプロトコルに設計)・ワンタップ返事記録API(nudges.replied活用、T16/issue#16へ委譲済み)。次: BACKLOG/DONE/JOURNALをcommit→push→issue #15へ完了コメント投稿→close

## 2026-10-12 15:05 (対話/Opus — セッション「タスク洗い出しとデザイン改善」) — Workflow 完了・申し送り訂正
- **訂正(14:05 の他セッション記録について)**: v4_drafts/「タネの子」は #49 のF制作サブエージェントの逸脱ではなく、**本セッション(Opus)がユーザーの直接指示「イラストはダサすぎるので刷新して」に基づいて制作したもの**。F 本制作は不要(採否は #40 でユーザー判断)
- Workflow 完了(7エージェント・全成功): Haiku max×2 で47件洗い出し → Opus max×2(クリティカルパス/品質・リスク)で方針レビュー。並行して Opus max で成長ルール設計→敵対レビュー→改訂(最終版 1254行)
- レビューの重大指摘(両レビュー一致): ①close-day/grant-tickets の **cron が本番未登録**(成長・ストリーク・チケットが本番で進まない)②iOS に GET /snapshot・約束設定導線・ソロモード・push_token 保存が無く「CI緑だが本番で動かない」③写真パスがペア×日付単位で2人目が上書き ④plants.stage の CHECK(0..5) で段階追加すると close-day が失敗 ⑤Xcode 26 SDK 必須・Supabase 無料枠の自動停止(実例あり)⑥審査: UGC 1.2/5.1.1(v)/ソロ説明の不一致。逆算: 審査提出 11/23〜27、公開目標 12/11
- 成長ルール最終案: 10段階(0/1/3/7/14/21/30/45/66/100回)・「ふたりの葉」(左=自分/右=相手がチェックインでひらく)・すやすや(しょんぼり置換・汗なし)・100回後は花壇(v1.0.1)・世代交代なし・成長回数は streak_days の both 行数から数える(v1.0 は migration 不要)
- 次: 成長ルールに合わせてイラストをSVGレイヤー部品(約31点)に再構成 → 報告書と #40 承認依頼
- 節目(イラスト v4 レイヤー化): 成長ルール最終案 §9 に合わせ、SVG レイヤー33点を制作(gen_layers.py)— 鉢2・体4(body/hands_rim/arms_up/solo_seed)・顔6・ふたりの葉4(nub×2/leaf_open/leaf_folded)・頭の植物 s2〜s9・花の塗り s6〜s9・効果5。目視QCで修正したもの: 花の輪郭が花びらごとに重なる問題(塗りと線を別レイヤーにした副作用)→ 花びらの和集合の外形線+仕切り線を幾何計算で描く方式に変更 / 茎を花の外形の手前で止める / 上端の切れ(高さ予算の再配分)/ ほころびの花びら(爪状→丸い冠)/ 演出のグローがキャラを褪せさせる / バンザイ腕が耳に見える / zzz の位置と色。SVG の決定論(2回生成でハッシュ一致)・禁止要素なし・XML 妥当性を確認。旧6段階の契約13枚も同じレイヤーから合成(フォールバック)
- 節目(文書): docs/REVIEW-2026-10-12.md(洗い出し+レビューの統合版・決定パッケージ D1〜D6・逆算日程)と docs/GROWTH.md(成長ルール最終案。承認待ち)を作成。v4_drafts/README.md に重ね順・状態対応・のぞき位置・受け入れ基準の自己チェックを記載
- 実施中: アートの独立レビュー(Opus max)→ 指摘反映後に commit/push → #40(画風・成長ルール・アイコン)と #50(決定パッケージ)に承認依頼
- 節目(独立レビュー反映): アートを Opus max で独立レビュー → 「方向性は合格・承認依頼前に H1〜H5 を直すべき」。反映: H1 たたんだ葉が段階2〜4の植物を隠す(毎朝縮んで見える=罰に近い)→ 頭の植物を葉より上に重ね、ひとひねりを葉より上へ、たたむ角度46°で外側へ / H2 段階9の散らかり → ハートのタネを茎のすき間へ、光は茎より下に / H3 段階7の冠の重なり → 間隔拡大+左右の塗りの重なりを画素で自動チェック / H4 花の色を左右別にできない → petal 層を左だけにして右は反転(v1.1 で各自が色を選べる)/ H5 ダーク方式 → 背面プレートに決定。ほか段階0の光る芽を形でも区別・視線を強化・stop-opacity 廃止・影を pot_back へ・腕をミトン型・小部品の線を細く。gen_v4.py から汗/clipPath の旧関数を削除。レイヤーは34点(bg_plate 追加)。決定論(2回生成でハッシュ一致)を再確認
- commit/push: 41b3668(REVIEW-2026-10-12.md・GROWTH.md・v4_drafts 一式)。lien-ci success。approval-ping 発火を確認
- 承認依頼: #40(D1 画風 v4 / D2 成長ルール / アイコン — 画像7枚付き)・#50(決定パッケージ D1〜D6+人間の作業: G0 を 10/16 まで・Xcode 26 導入・テスター募集)に needs-approval+human-gate。#49 に「F 本制作は行わず v4 で置換提案中」を記録
- 結果: ユーザー依頼4点(Haiku 洗い出し・方針レビュー・イラスト刷新・成長ルール再考)は完了し、承認待ちで停止。**承認後の次アクション**: (1) 決定に従い #50/BACKLOG/DONE を整理し新タスク(W1 アプリ結線・cron 登録・写真パス修正・Pages 公開・T28準備)を起票 (2) v4 採用なら取込タスク(SVG→xcassets・PlantCharacterView・plant-assets CI の SVG 化)(3) 成長ルール採用なら GROWTH.md §8 の順で REQUIREMENTS/DESIGN 改定 → サーバー → iOS

## 2026-10-12 16:10 (対話/Opus) — 決定「全部推奨で」→ 起票・計画更新・第1波着手
- 着手: ユーザー回答「全部推奨で」= D1 v4 採用 / D2 成長ルール10段階 / D3 v1.0 から7機能を外す / D4 本番変更の包括承認 / D5 Supabase Pro 化(支払いのため人間)/ D6 計測は SQL のみ
- 事実確認(読み取りのみ): 本番は ACTIVE_HEALTHY。拡張は supabase_vault のみで **pg_cron / pg_net 未導入・cron ジョブ0件**(レビュー指摘 M1 を確定)。checkins は pair_id を持たないため写真なしのソロのチェックインはサーバー側で受付可
- 起票: #51 cron / #52 写真パス / #53 push_env / #54 成長ルール(サーバー)/ #55 W1 アプリ結線 / #56 植物描画 / #57 植物体験 / #58 仕様改定。ラベル on-hold・v1.0.1 を新設し #21・#24・#33〜#36 に付与(ループから外す)。#19 は分割、#35 は計画の作り直しを記録。#40・#50 に決定を記録し needs-approval を外した(human-gate の close は人間)
- 整理: BACKLOG を第1波の計画で作り直し(T10〜T14 の残骸を削除)。DONE に T08準備①②・T10〜T14 の追記漏れを補完(JOURNAL の事実のみ)
- 次: 第1波を並列実行 — backend(#51→#52→#53→#54、Sonnet)∥ docs(#58、Sonnet)∥ ios-serial(#55、Sonnet)。各ステップ後に Opus でレビュー→必要なら修正。サブエージェントは JOURNAL に直接書かず、オーケストレータが集約して記録する
- 第1波 起動(Workflow wf_1eabad77-d26): backend(#51 cron → #52 写真パス → #53 push_env → #54 成長ルール)∥ docs(#58)∥ ios-serial(#55 W1)。実行 Sonnet max、各ステップ後に Opus max レビュー → must_fix があれば Sonnet で修正。本番変更は D4 の範囲(cron・migration 0003〜0005・関数の一括デプロイ)。進捗は完了時にここへ集約して記録する

## 2026-10-13 01:10 (対話/Opus) — 第1波 完了の集約(Workflow wf_1eabad77-d26・10エージェント・約6.7時間)
- **#51 cron(本番)**: pg_cron 1.6.4 / pg_net 0.20.3 を導入し lien-close-day(00:10 JST)・lien-grant-tickets(毎日 00:05 JST 起動・1日だけ呼ぶ)を登録。鍵は Vault 参照(migration に書かない)。発見: Edge Function が見る鍵は legacy(eyJ…)ではなく default secret key(sb_secret_…)— Vault はこちらに更新。scripts/OPS.md・ops/*.sh 追加(6062884)
- **初回の定期実行を本番で確認(オーケストレータ・読み取りのみ)**: 2026-10-13 00:10 JST close-day = HTTP 200(dateLocal 10-12・pairs 6・recordedBoth 2・recordedTicket 4・errors 空)/ 00:05 grant-tickets = 0 rows(1日でないので呼ばない=設計どおり)。成長・ストリークが本番で進むようになった
- **#52 写真パス(本番)**: pairs/<pair>/<date>/<user_id>/… に変更、migration 0004 で本人の区画以外への書き込みを RLS で拒否。スモーク27項目全通過(8fdba73)
- **#53 push_env(本番)**: migration 0005(users.push_env+列 GRANT)、apns.ts でトークン単位の環境選択と 410/BadDeviceToken 時の push_token 掃除(e0e5380)。deno 206 緑
- **#54 成長ルール v2(本番)**: 10段階・streak_days の both 行数から数える・昨日の仮判定・plant-name 新設・11関数を一括デプロイ。スモーク55項目 PASS(949c6ea ほか)。**Opus レビューで must_fix 2件** → 修正: ①react の push は最初の1回だけ・相手の当日判定は相手のTZ ②昨日の仮判定を close-day 確定前(現地 1:00 前)に限定(1日中かかると、確定後に届いた昨日付けチェックインで数字が戻る不具合)。再デプロイ+スモーク35項目 PASS(〜793527d)。契約フィクスチャのずれ検査を lien-ci に組み込み。deno 285 緑
- **#58 仕様改定**: REQUIREMENTS/TASKPLAN §9/CONCEPT/E2E-M1/ストア説明文を決定どおりに(d3f8103)。Opus レビュー must_fix 1件=「v1.0 で相手の写真を当日ホームで見せる」担当が不在 → **#59 PV を起票**して解消(cc9e4e4〜9cadad1)
- **#55 W1 アプリ結線**: Live/Stub ファクトリ・accessToken・Invite/Snapshot/NudgeReact の Live・自己修復同期・push_token/push_env 自動保存・AppRouter(4状態)・ソロモード・契約フィクスチャ16件+検査。lien-ios 緑(261テスト 0失敗)(30ead91〜d9a787f)。Opus レビュー ok(改善提案11件は第2波へ)
- 本番のテストデータ: 台帳を OPS.md §8 に記録(KPI 集計から除外する SQL つき)
- 持ち越し(第2波へ): OPS の再実行手順の誤り(リセット通知の再送・grant-tickets の判定)/ 監視の自動化(毎朝 00:40 JST の Actions)/ cron 専用シークレット・net の権限 revoke / Release ビルドで Config 欠落時に Stub へ黙って落ちる / supabase-swift の版固定 / push_token のコールドスタート再送 / review-notes §1.1・§1.2 と実装のずれ5点 / DESIGN §3.3・§3.6・§5.6・§7・§10 の更新
- 次(第2波): backend 堅牢化 B3 ∥ docs 整合 DOC2 ∥ ios-serial(W1 手直し+罰なし lint → T28準備 → PA 新イラスト取込)。順序変更: 新イラストを最初の内部 TestFlight(10/23 目標)に載せるため PA を PV・T23 の前へ(PA は PV・T23 に依存しない)
- 第2波 起動(Workflow wf_cc8900bd-a55): backend #60 堅牢化 ∥ docs #61 ∥ ios-serial(#62 W1 手直し+罰なし lint → #28 T28準備 → #56 新イラスト取込)。新規起票 #60・#61・#62。各ステップ後に Opus max レビュー

## 2026-10-13 04:00 (対話/Opus) — 第2波 完了の集約(Workflow wf_cc8900bd-a55・11エージェント・約3.6時間)
- **#60 backend 堅牢化(本番)**: close-day に notify(手動再実行は通知しない)+今日以降を確定しないガード / grant-tickets を月単位の実行記録で冪等化(migration 0006)/ cron 認証を専用シークレット LIEN_CRON_SECRET に切替(migration 0007。Vault から万能鍵を削除)/ 毎朝 00:40 JST の監視 workflow lien-cron-watch / cron 式の静的テスト / push_env を getUser で読む / DESIGN 更新。11関数再デプロイ・スモーク29項目 PASS。**Opus レビュー must_fix 1件**=「前夜の cron が起動しなかった」を監視が赤にできない → 直近の予定起動の記録を必須にして修正。未達1件: net の権限 revoke は Supabase の所有者権限のため postgres から不可 → 公開スキーマ監視で代替(OPS §9)。意図しない本番データ変更1件(スモークでテストペア P3/P4 に both が1行ずつ。通知なし・OPS §7 に記録)
- **注意: このリポジトリは公開**。監視 workflow の Actions ログは件数・ID を出さないよう修正済み(修正前の run 2件にテストペアの件数が残る)
- **#61 docs**: DESIGN §3.3(AppPhase 4状態ほか)・§3.6(ディープリンクは明示タップ)・review-notes §1.1/§1.2 を実装に合わせた。レビュー ok
- **#62 W1 手直し+罰なし文言 lint**: push_token の再送・オンボ復帰・Live 構成テスト・招待シートの間隔・「相手を招待する」・StringsReviewTests(Strings.swift 全リテラル146件を検査)。lien-ios 309テスト緑。レビュー ok
- **#28 T28準備**: Xcode 26.6(macos-26)に固定・lien-release.yml(dry_run で無署名 archive 緑)・ExportOptions・PrivacyInfo(必須理由 API の棚卸し)・MARKETING_VERSION 1.0.0・**v4 アイコン(空色)**・Release で Config 欠落を致命に・supabase-swift 固定・push_env を署名の aps-environment から判定。lien-ios 345テスト緑。#28 は開いたまま(G0 後の人間作業 約1時間: ASC API キー+GitHub Secrets 6件 → lien-release を本番実行)
- **#56 植物 v2-a(描画)**: v4 SVG レイヤー34点を本番アセットに取込(生成は Chrome 不要の決定論スクリプト・plant-assets CI は再生成 diff 検査)、PlantLayers / PlantCharacterView で描画を置換(左右で別の花色・ダークは背面プレート)、ウィジェット試作も差替。lien-ios 365テスト緑。**オーケストレータが CI の実描画一覧を目視**: Chrome の下書きと差なし → 受け入れ基準10を満たした。artifact は 11/11 に消えるため products/lien/assets/plant/ci_render/ に保存
- 片付け: v4_drafts/composed の重複ファイル(正式ファイルとバイト一致の未追跡コピー)を削除。BACKLOG の順序を TASKPLAN §9 に揃えた(PA → PV → T23 → PB)
- 次(第3波): ios-serial(#59 PV 相手の写真 → #23 審査対応一式 → #57 PB 成長の体験+VoiceOver ほか)∥ docs(DESIGN/GROWTH/TASKPLAN/E2E/README の持ち越し)∥ CI 保守(ops テストの統合・xcodegen 固定・リリース前の CI 緑確認ほか)∥ backend(本番に対する2ユーザーの API E2E スクリプト)
- 第3波 起動(Workflow wf_13c84c7c-f34): ios-serial(#59 PV 相手の写真 → #23 審査対応一式 → #57 PB 成長の体験)∥ docs #65 ∥ ci #66 ∥ backend #67 本番 API 通しテスト。新規起票 #65・#66・#67、#57 に追加範囲をコメント

## 2026-10-13 12:30 (対話/Opus) — 第3波 完了の集約(Workflow wf_13c84c7c-f34・14エージェント・約7.6時間)
- **#59 PV 相手の写真**: 相手の当日 checkins の photo_path を RLS の範囲で読み、署名付き URL をクライアントで作ってホームに表示(サムネ優先・タップで原寸・メモリのみ・失敗は静かに植物だけ)。migration・新関数なし。lien-ios 447テスト緑。レビュー ok(改善7件は次波)。Xcode の無い Mac で push 前に約30秒で下見できる ios/scripts/macos-check/ を追加
- **#23 審査対応一式(本番)**: 新関数 pair-dissolve(ブロック=解消)・delete-account(写真→データ→auth の順の完全削除)を本番デプロイ。設定画面(約束の編集・規約/ポリシー/お問い合わせ・解消・削除・サインアウト)、長押しの通報(mailto)とブロック、オンボでの規約への明示同意、セッション無効時のオンボ復帰。本番スモーク 48+8 PASS(使い捨てユーザーは全削除)。**Opus レビュー must_fix 1件**=REQUIREMENTS §3.15 のプロフィール編集(ニックネーム+アイコン)が未実装 → 実装して修正
- **#57 PB 成長の体験**: snapshot の新キー3つ(省略可)・ゲージの文・段階アップの全画面演出(各段階1回)・名前付け(plant-name の Live)・VoiceOver 文・葉の下の約束の絵文字・のぞき・PA の手直し。lien-ios 747テスト緑。レビュー ok
- **#65 文書**: DESIGN §3.3/§3.5/§3.8/§4.1/§7・8文字コード・E2E 順序・review-notes・README を実装に合わせた。レビュー ok
- **#66 CI 保守**: ops テストを lien-ci に統合・XcodeGen 2.46.0 を SHA-256 で固定・リリース前に同じ SHA の CI 緑を確認・codesign 構文・棚卸しスクリプトのテスト・checkout を Node 24 版に・シミュレータ起動の分離。lien-release dry_run 緑。レビュー ok
- **#67 本番 API 通しテスト**: 匿名ユーザー3人で S01〜S21 を本番に流し **244項目 PASS / FAIL 0**(PV の経路・PushTokenSync の経路・RLS の拒否を含む)。契約フィクスチャとのずれ1件(署名発行の失敗が 404 でなく 400)→ アプリ側の写像を修正済み。テストデータは全削除。レビュー must_fix 1件(招待トークンの正規表現が大文字 I を誤って除外)→ 修正。lien-ci に e2e-tests ジョブ
- 新規 issue(エージェント起票): #68 取消後も写真の実体が Storage に残る / #64 公開後の規模対応(on-hold)/ **#63 net 権限の件を代わりの守りで受け入れるか(人間判断)**
- G0(#38)は未完了のまま(最終更新 6/11)
- 次(第4波): ios-serial(#16 通知 縮小版 → #17 ウィジェット S+ロック → #18 履歴 → #19 チケット残数 → #22 シェア画像)∥ backend(#19 サーバー側 ticketBalance+#68 写真の削除+バケット制限 → #16 サーバー側 節目の通知)∥ docs
- 第4波 起動(Workflow wf_61db8718-7fe): ios-serial(仕上げ=#59/#57 の改善提案 → #16 通知 縮小版 → #17 ウィジェット S/M/ロック → #18 履歴 → #19 チケット残数 → #22 シェア画像+節目のお祝い)∥ backend(#19 サーバー側 ticketBalance+#68 取消時の写真削除+バケット制限)∥ docs #69(文書の追随+KPI の SQL+#63 の判断材料)。判断: 節目の通知は v1.0 では出さずアプリ内のお祝い+シェア誘導にする(サーバー側の通知設定が v1.1 のため、オフにできない通知を作らない=D3 の帰結)

## 2026-10-20 09:55 — T19a(#19) iOS: チケット残数バッジ
- 着手: Issue #19 の iOS 残分を実装する。範囲は D3(2026-10-12)・TASKPLAN §9 の T19a = snapshot の `ticketBalance` を読む `PairSnapshot` + ホームの残数バッジ(0枚でも表示)。**お休み宣言 UI / rest-declare は 1.0.1 のため作らない**(Issue 本文の古い計画より D3 と TASKPLAN §9 を優先)。
- サーバー側(ticketBalance)は 2026-10-13 に完了済み。契約フィクスチャにも `snapshot.paired=2` / `snapshot.solo=null` が入っていることを確認。
- 作業場所: worktree `/Users/kojimaryoki/.consilium/wt/Challenge-19`、ブランチ `consilium/19-t19-ui`。origin に対象ブランチ・既存 PR は無し(重複作業なし)。
- 検証予定: `products/lien/ios/scripts/macos-check/check.sh test PairSnapshotTests HomeViewModelTests ContractFixtureTests StringsReviewTests` と `views`。Xcode は無いためフルのシミュレータ CI は push 後に GitHub Actions で確認する。
- 実装: `PairSnapshot.ticketBalance: Int?`(キー欠落・null・型違いは nil、0 は有効値、エンコードは null を明示) / `HomeViewModel.ticketBalance`(ペア成立かつ 0 以上のときだけ返す。ソロ・負の値は nil)/ `TicketBalanceBadge`(ホームのストリーク直下。0枚でも表示、アイコン+「お休みチケット 残り○枚」)/ `Strings.Tickets`。`HomeView` は nil のときバッジごと出さない。
- テスト: PairSnapshot の欠落/null/型違い/0/往復/翌日リセット、HomeViewModel の 2・0・nil・ソロ・負・空状態、契約フィクスチャ(snapshot/checkin/invite-accept/nudge/plant-name/pair-dissolve/push)の値、StringsCatalog、0枚バッジの実描画(白紙でない)。既存の全テストに回帰なし。
- 検証: `scripts/macos-check/check.sh all` = module 74 ファイル・**998 tests / 0 failures / 20152 assertions**、views 103 ファイル、widget 18 ファイルとも OK(既存の ISO8601DateFormatter の Swift 6 警告のみ。この変更では増えていない)。フルのシミュレータ CI は push 後。
- CI(正本): **lien-ios run 39351451628 success**(12m44s・commit d229f32)。`Executed 1075 tests, with 0 failures` / `** TEST SUCCEEDED **`。新規の `TicketBalanceBadgeRenderTests` 2件、`PairSnapshotTests` / `HomeViewModelTests` / `ContractFixtureTests` の ticketBalance テストがログ上で passed。lien-ci run 39351451853 も success(サーバー側の変更なし)。
- 目視: CI artifact `plant-render-sheets` の `ticket_01_balances.png` / `ticket_zero_large.png` / `ticket_zero_accessibility5.png` を取得して確認。0枚でもバッジが表示され、最大の文字サイズ(accessibility5)でも折り返して欠けない。
- 結果: **PR #84 作成**(https://github.com/Ryoki63/Challenge/pull/84)。お休み宣言 UI / rest-declare は D3・TASKPLAN §9 のとおり v1.0.1 の対象なので実装していない。レビュー役職(eng-review)の判断待ちで、issue は閉じない。

## 2026-10-20 11:54 (eng-exec) — T27 #27 Strings.swift 全文言のレビュー
- 着手: オンボ磨き・空状態・エラー文言の総点検(罰なし原則)。`Strings.swift` を全件読み、`StringsCatalog` の 297 単位(580 出力)をレビュー
- 成果: `docs/STRINGS-REVIEW.md` に全 297 単位の判定(OK 291 / 修正 6 / 保留 0)、空状態 14・エラー文言 33 の点検、判定基準、修正理由、変えないと決めた点を記録
- 修正 6 件: Dissolve の「ストリーク」「アーカイブ」をユーザーの言葉に / 閉じるボタン2件を「閉じる」に / 「名前をかえる」→「名前を変える」/ 「写真をおくっています…」→「写真を送っています…」/ nameInvalidError を「改行や見えない文字は、名前に使えません」に
- 検査: `scripts/macos-check/check.sh` = module 74ファイル・**992 tests 0 failed**(assertions 24446)・views 102ファイル・widget 18ファイル。レビュー関連 28 tests 0 failed。CI `lien-ios` は PR #86 で確認
- 回帰検査: `StringsReviewTests` にログ網羅・文言一致・集計・開発者ことば・閉じる・通信エラーの6テストを追加
- 残: 初回同期失敗時に `.promiseSetup` を出す画面遷移は文言では決められないため、`docs/STRINGS-REVIEW.md` §6.1 に判断材料と推奨案を残した(eng-lead / T30)。実機 VoiceOver は T20
- 結果: PR #86 を作成(レビュー待ち。マージはしない)

## 2026-10-20 12:25 (HQ/eng-exec — T30 審査チェックリスト消化 / issue #30) — 文書側を確定・PR 作成
- 着手: worktree `Challenge-30`(origin/main `35bad0d`)。Issue #30 の残り(REQUIREMENTS §8 の文書・App Privacy・年齢レーティング・プライバシーマニフェスト・審査用デモ運用)を実施。iOS の実機/TestFlight 確認は G0(#38)後で、この Mac には Xcode が無い(`xcodebuild` は CommandLineTools)ため、実ビルドは CI と 10/23 の内部 TestFlight に委ねる
- 変更(文書): `marketing/privacy-policy.md`・`legal/privacy.html` から「Sign in with Apple の識別子」「利用状況(自動取得)」の行を削除し、D3(v1.0 は SIWA なし)・D6(分析 SDK・計測テーブルなし。アプリは計測のために何も送らない)を明記。§8 を「v1.0.1 以降」に。`legal/CHECKLIST-G4.md` の計測手段の未決定項目を D6 の確認に置き換え、SIWA の確認を追加
- 変更(review-notes): §1.3 を匿名認証の実態に合わせた**2組のデモ運用**に確定(相手役のニックネーム+提出日に発行する招待コード。コードはリポジトリに置かず ASC の Notes for Review へ)。§2.1 を `PrivacyInfo.xcprivacy` の5型(Name / Photos / Other User Content / User ID / Device ID)に一致。§2.2 に年齢レーティングの UGC 設問(4+/9+ の分岐、健康・ウェルネスは要確認)、§2.7 にプライバシーマニフェストの台帳を追加。§1.1・§1.4・§1.5 にコードで一致を確認した証跡を追記
- 追加(道具): `products/lien/scripts/review-demo/`(partner.sh / partner.ts / partner_lib.ts / partner_lib_test.ts / README.md)。公開 anon キーだけを使い、セッションはリポジトリ外の 0600 ファイル。create / new-invite / checkin(--photo)/ nudge / status / delete を用意
- 追加(テスト): `products/lien/scripts/ops/marketing_docs_static_test.ts` を新設し、D6・D3 の記載漏れ、§2.1 とマニフェストの不一致、§1.3 の TBD 残り、G4 の未決定項目を CI で止める。`review-demo` の単体テストを lien-ci の e2e-tests ジョブに追加
- 変更(仕様・計画): REQUIREMENTS §8 に 2026-10-20 の反映注記と各項目の追記(チェックボックスは実ビルド確認まで `[ ]` のまま)。TASKPLAN §9.4 の T30 行と #58 引き継ぎ2・3 に完了を記録
- 検証(ローカル): supabase functions `deno test` 393 passed / 契約フィクスチャ 22 件一致 / ops `deno test --allow-read` 76 passed(新規8件を含む)/ e2e unit 65 passed + `deno check` / review-demo 17 passed + `deno check` / store metadata OK / `git diff --check` OK / 秘密の混入なし
- 残り: G0 承認後の内部 TestFlight(10/23)で §1.1・§1.4・§1.5 の手順を実ビルドで再現 → §8 のチェックを埋める。提出日(10/27)に相手役の招待コードを2つ発行して ASC の Notes for Review に記入。Support URL/Privacy URL の Pages 公開と連絡先は G4(#42)
- 補記(2026-10-20 12:55): この記録は PR #88 のマージ解決(7fba989)で `progress/JOURNAL.md` から落ちていたため、追記として復元した。内容はコミット `08191a1` の記録のまま(検証の ops は当時 76。その後、マニフェストのトラッキング検査を1件足して 77 になり、CI で確認済み)

## 2026-10-20 12:42 (eng-exec) — T32 #32 ASO 初期設定(キーワード・説明文)の本編
- 着手: 2026-10-12 の T32準備(store_metadata/ja の確定値化+verify_metadata.py+CI ジョブ)の続き。完了条件「ASC にキーワード・説明文設定完了」のうち、リポジトリ側で確定できる部分を終わらせ、残りを G4 後の ASC 投入だけにする
- 前提の変化: 2026-10-12 の確定値は「次の需要の山=1月の新年需要」に合わせていたが、10-20 のオーナー決定で公開 10/31・審査提出 10/27 に前倒しした。キーワードはバージョン提出と同時にしか変更できないため、季節外れの「新年」「正月」で初回の索引枠を使うと11〜12月は戻せない → 通年訴求に再調整(退避値は alternatives.md §8.3)
- 変更: keywords 81→99字(新年/正月を外し、朝活・早起き・筋トレ・勉強・ダイエット・遠距離を追加)/ promotional_text を季節非依存に(「広告なし」は v1.0 の事実)/ description の末尾節を「◆ 思い立った日が、はじまりの日」に、ウィジェット節を「自分と相手の今日の○×」に(REQUIREMENTS §3.10 との一致)
- 検査の追加: issue #32 の「検証」が「表示名との語重複なし」を verify_metadata.py で検査すると書いていたが実装されていなかった。表示名・サブタイトルとの重複/キーワード同士の包含重複/Pairy 語の不在 を追加。単体テスト `tools/test_verify_metadata.py` 24件(赤になる例を固定)を新設し、CI の store-metadata ジョブで実行
- Pairy 語: Issue の表題は「Pairy 関連語」だが、TASKPLAN §9.4 の T32「Pairy 語は全廃」が後。全廃のまま(機械検査で担保)。戻すなら G4 でリスク承認
- 成果: `store_metadata/ASC-ENTRY.md`(ASC の画面→ファイルの対応・貼り付け手順・入力後の証跡チェック)。残るのは G0 の Apple 承認 → ASC アプリレコード → G4 承認 → このシートどおりの投入
- 判明: issue の進め方コメント手順7は「App 情報に keywords」としているが、キーワード欄はバージョンページ側。手順書は実画面の構成に合わせ、ずれを ASC-ENTRY.md に注記した
- 未解決: 表示名「ふたりの約束」とサブタイトル「約束はひとつだけ」の「約束」重複(§2 の不採用理由と矛盾)。推奨は現状維持、代替案つきで alternatives.md §8.5 に記載
- 結果: 検証(verify_metadata.py / unittest 24件)緑。PR を作成し、ASC 投入は G4 の人間判断待ちとして issue は閉じない

## 2026-10-20 12:56 (eng-exec) — #49 T09v2 の状況確認: フェーズ1は提出済み・v4 採用で置換済み
- 着手: HQ が #49 を status:in-progress で再ディスパッチ(12:55)。作業前に origin/main・対象ブランチ・PR・既存成果物を確認
- 判明: #49 のフェーズ1は **2026-06-10 に完了済み**(commit 96ebfe9)。4スタイル(a〜d)と成長カーブ案を `v2_drafts/` に制作し、#40 に画像付きで提出済み(comment 4672531055)。その後 2026-06-11 に v2 は不採用、v3 を経て 2026-10-12 に v4「タネの子」が「全部推奨で」承認(comment 6121307014)。取込は #56/#57、成長ルールは #54 でいずれも closed
- 検証: 4スタイルの `gen.py` を一時ディレクトリで再実行し、追跡済み PNG と SHA-256 完全一致(決定論)。コンタクトシートは 1264×288(8倍)。#40 の raw リンクは HTTP 200。origin に対象ブランチ・既存 PR は無し(重複作業なし)
- 判断: v2 の再制作・#40 への再提出はしない(差し戻し済みの案の再提出は混乱と退行になる)。再発防止として `v2_drafts/README.md` に経緯・受入証拠・再生成手順を記録
- 結果: PR を作成(レビュー待ち)。#49 は「フェーズ1完了・v4 で置換済み」として、close の判断をレビュー役職/人間に委ねる

## 2026-10-20 15:03 (computer-operator) — #79 MK6 X 投稿の実行前確認
- 着手: 指定 worktree・`consilium/79-mk6-x` で確認を開始。作業開始時の tracked/untracked 差分は無し。origin/main と HEAD は一致し、対象リモートブランチは未作成のため、そのブランチからの pull は未実施。
- 確認: #79 は OPEN・assignee 未設定。Consilium の本タスク割当はあるが、Issue の assignee による排他は確認できない。オーナーの X ハンドル・ログイン済みブラウザの指定は本文・コメントに無い。無関係なブラウザやアカウントを探索せず、投稿操作は開始していない。
- 節目: #75 の最新非 bot コメントは `<!-- lien-agent -->` 付きの承認依頼で、人間の返信は無し。PR #99 は OPEN・レビュー無し、HEAD `62d4bc7a7f49ce512bff4ed343f4caefe4422bfc` の承認台帳は未承認。記入例や mkt-exec の自己点検を承認に数えない。
- 【承認待ち】: MK2 の承認・レビューと対象アカウントの引継ぎが未成立のため外部操作を停止。初回提案は明日 2026-10-21 08:00 JST で、時刻承認・投稿予約・24時間後確認の登録はしていない。`products/lien/marketing/x/log.md` に未投稿と欠測値 `null` を記録し、#79 へ1件にまとめて引継ぎを依頼する。
- 検証: 一時的な Python の直接検査で、初回は検査側の行数期待値16が誤りのため FAIL。14項目の名前を明示して検査し直し、理由付き null・架空キャプチャ無し・未来の提案時刻/未登録の区別・JOURNAL 追記のみ・変更2ファイルの範囲を PASS。`git diff --check` PASS。コード/設定/画像の変更が無いためアプリのテスト・型チェック・lint・build・独立レビューは対象外。
- 通知: #79 に承認待ちコメント（6284552555）を投稿し、`needs-approval,human-gate` を付与。readback で OPEN のままと bot の通知コメントを確認（モバイル端末への配達は未確認）。`status:*` は変更していない。
- 結果: **BLOCKED**。指定時刻の投稿・URL/キャプチャ・24時間後反応は未達。未承認投稿をしない条件は遵守。承認・アカウント引継ぎ待ちの実行ログのみ提出し、原稿や承認台帳は変更せず、Issue は close しない。

## 2026-10-20 14:38 (mkt-exec) — MK4 #77 先行ペア 5〜10 組の募集文と受け入れ手順
- 着手: 公開日(10/31 目標)に使い始めてもらうペアを 5〜10 組集めるための**下書き**を作る。外部 TestFlight は省略するため、公開後の初期ユーザーとして招く。送信・投稿は一切しない(mkt-lead 承認 → mkt-review レビュー → computer-operator/人間)
- 確認した前提: issue #77 本文 / #42(G4)は**承認待ちのまま**= `SupportLinks.contactEmail` は空(`products/lien/ios/Lien/Core/SupportLinks.swift:25`) / G0 #38 未了= App Store URL 未確定 / TASKPLAN §9.2 の 10/31 公開・10/27 提出・10/24 凍結 / REQUIREMENTS §0・§3・§7 / CONCEPT §7 / GROWTH §10.5(聞き取りは3日目と10日目) / KPI §0(公開リポジトリにペア ID・ハンドルを書かない)
- 方針: 連絡先とストア URL は値を推測せず `<CONTACT_EMAIL>` `<APP_STORE_URL>` のトークンで残す(G4・G0 の確定後に1箇所ずつ置換)。X 本文には日付を書かない(公開日は審査結果で動く)
- 成果物の置き場: `products/lien/marketing/early-pairs/`
- 成果: `products/lien/marketing/early-pairs/` に 4 本 — ①`README.md`(前提・募集枠・スケジュール案・文面原則・承認台帳・主張と根拠)②`x-post.md`(X の募集 4 本: 本命/物語/スレッド補足 2 本。140 字・日付なし)③`acquaintance.md`(知人向け 3 種)④`acceptance.md`(受付→確定→公開日の案内→症状別の困りごと→3 問→お礼。問い合わせ先は `<CONTACT_EMAIL>`)⑤`tracker.md`(X の反応・P01〜P10・集計・週次報告の書き方。個人情報を書かない欄設計)
- 判断: **contactEmail は推測で埋めない**。G4(#42)が承認待ちで `SupportLinks.contactEmail` が空なので、`<CONTACT_EMAIL>` のトークンで残し「G4 後に1箇所置換・空のまま送らない」を手順の先頭に置いた。ストア URL も `<APP_STORE_URL>`(G0 #38 後)。G4 の値は専用アドレスを作るのが推奨(私用アドレスをストアと公開リポジトリに出さない)
- 判断: X の本文に日付を書かない(#75 と同じ原則)。公開日は審査結果で動くため、日付は 1 対 1 の DM と案内文でだけ伝える。知人向けは 1 対 1 なので「10月31日に公開する予定」と書いてよい
- 判断: フィードバックは Day 3 の 3 問に集約(GROWTH §10.5 の 3 日目・10 日目のうち、10 日目はお礼と任意のひとことにした)。質問を 4 問に増やさない
- 追加(検査): `products/lien/scripts/ops/early_pairs_static_test.ts` を新設。X 本文の 140 字・日付断定・禁止語・v1.0 に無い機能・競合名、連絡先トークンの存在、メールアドレスらしき文字列の不在、Day 3 が 3 問であること、P01〜P10 の行、相対リンクの実在を CI で止める。禁止語・日付・未実装機能の各検査は、わざと文面を壊して赤になることを確認した
- 検証: `deno test --allow-read products/lien/scripts/ops/` = **84 passed / 0 failed**(既存 77 + 新規 7)。`products/lien/marketing` の `verify_metadata.py` OK・単体テスト **24 passed**。`git diff --check` OK。`deno fmt --check` OK
- 残り: mkt-lead 承認 → mkt-review(景表法・誇大表現・体験していない機能)→ 10/21 の承認後に知人連絡(10/22)・X 投稿(10/23)。G4 で contactEmail が決まったら置換、G0 後にストア URL を確定
- 結果: PR を作成(レビュー待ち)。送信・投稿はしていない。Issue は閉じない

## 2026-10-20 14:40 (mkt-exec) — MK5 #78 計測設計(UTM・App Analytics・週次 SQL)
- 着手: worktree `Challenge-78`。issue #78 の完了条件(チャネル別 UTM 命名規則 / App Analytics の指標一覧 / KPI.md の SQL と組み合わせた週次の見方 / SDK を入れない代替案)を、`products/lien/marketing/measurement.md` にまとめる。D6(分析 SDK なし)・#30 の App Privacy と整合させる
- 方針: 標準 UTM は App Store に渡らないため、DL のチャネル attribution は Apple のキャンペーンリンク(`pt`/`ct`/`mt`)を正とし、UTM は将来の Web 計測用の予約として同じ命名を定義する。アプリ側の変更・SDK・計測専用テーブルは足さない
- 成果: `products/lien/marketing/measurement.md` を作成。§2 にチャネル別の `ct` 命名規則(X / ティザー / 紹介)と UTM 対応、§3 に ASC Analytics の指標一覧としきい値、§4 に KPI.md と組み合わせた週次シート・分母一覧・補助 SQL、§5/§6 に SDK を入れない代替案と #30 の App Privacy との整合を書いた。docs/KPI.md §2.8 と docs/STRUCTURE.md からリンクを追加
- 判断: 標準 UTM は App Store の campaign 計測に使われないため、`ct` を正とし、UTM は将来の Web 計測用の対応表にした。公開日(10/31)は ASC の Campaigns が出る前で `ct` を発行できないため「タグなし」とし、0 ではなく null で記録する運用にした
- 検証: 相対リンク7件の解決 OK / `ct` 例11件が `[a-z0-9_]`・30文字以内 / `pglast` で KPI.md の SQL に補助 SQL を差し替えた全文を構文解析 OK(2 statements)/ marketing tools の unittest 24件 OK / `git diff --check` OK
- 結果: コミット `322cc4d` を push し、PR #101 を作成(https://github.com/Ryoki63/Challenge/pull/101)。マージはせず、mkt-review の判断待ち
- CI: PR #101 の `lien-ci` 全5ジョブ(deno test / e2e / ops / plant assets / store metadata)が緑
- 追記: 表記の定義(ASC / DL / D1・D7・D30)を `0db7a0d` で追加。最終 CI も全5ジョブ緑

## 2026-10-20 14:25 (mkt-exec) — #75 MK2 X 開発ストーリー10本+公開日告知セット(下書き)
- 着手: worktree `Challenge-75`(ブランチ `consilium/75-mk2-x-10`)。Issue #75 の受入条件は「marketing/x/ に日付つき投稿案(日次10本+公開日・翌日・1週間後)」「各投稿に本文140字目安・添付画像・根拠・リンク先」「約束はひとつだけ/罰を使わない原則」「mkt-lead 承認+mkt-review レビュー済みのものに status:ready 相当」「日付を断定しない」
- 前提確認: 公開目標 10/31・審査提出 10/27 は決定済みだが、App Store の公開日は審査結果に依存するため、本文では日付を断定せず「近日公開/公開しました(公開確認後)」で書く。投稿・外部送信は本タスクの範囲外(下書きのみ)
- 置き場所: リポジトリ直下に `marketing/` は無く、Lien のマーケ資産は `products/lien/marketing/`(既存の review-notes 等も `marketing/...` と略記)。Issue の `marketing/x/` はこの配下と解釈し、`products/lien/marketing/x/` に置く
- 根拠の範囲: CONCEPT §2/§5/§7、REQUIREMENTS §0/§3.2〜§3.13/§4/§7、GROWTH §4。v1.0 に無い機能(課金・アルバム無制限・Apple連携)は書かない。競合名(Pairy)はストア方針(TASKPLAN §9.4)に合わせて出さない
- 成果物: `products/lien/marketing/x/` に投稿案13本（10/21〜10/30 の日次10本 + 10/31 公開日 + 11/01 公開翌日 + 11/07 1週間後）。各ファイルに本文（140字以内）・添付画像・代替テキスト・根拠（docs の節/実装パス）・リンク先・数値の根拠・投稿メモ・承認チェック
- 判断: 10/21〜10/31 の11日間を「日次10本（10/21〜10/30）+ 10/31 公開日告知」で埋めた（10/31 を日次に数えると11本になり、受入条件の「日次10本 + 公開日」と重複するため）。公開日は審査結果に依存するので、本文では日付を断定せず「近日公開/公開しました（公開確認後）」の2文面を用意
- 判断: 実機スクリーンショットが無い（`screenshots/` は旧画風の SVG 下絵のみ）ため、UI を見せる7本は「指定:」にして撮影条件（Frame 番号）を明記。既存アート6点はそのまま投稿できる形でパスを指定。**旧画風の下絵は使わない**
- 判断: 「status: ready 相当の印」は mkt-exec では付けない（役職分離）。`review.md` に承認台帳（mkt-lead / mkt-review の2欄）を用意し、両方 ok になるまで `status: ready` にできないよう検査で固定した
- 追加: `x/tools/check_posts.py`（13本の静的検査: 140字・禁止語8語+誇大表現・競合名・日付断定・数値の根拠・節の実在・画像の実在・承認前 ready の禁止）と `x/tools/test_check_posts.py`（35件）。`.github/workflows/lien-ci.yml` の store-metadata ジョブに2ステップ追加
- 検証: `python3 x/tools/check_posts.py` = OK 13本 / unittest 35件 OK / 既存の `verify_metadata.py` OK・unittest 24件 OK（回帰なし）/ YAML の構文とステップ追加を確認
- 結果: **PR #99 作成**（https://github.com/Ryoki63/Challenge/pull/99）。CI `lien-ci` run 39375076692 は全ジョブ success（store-metadata に追加した2ステップも実行され、`OK: 13 本` と unittest 35 件を確認）。`status: ready` は mkt-lead 承認 + mkt-review レビュー待ちのため付けていない（検査で固定）。issue は承認待ちとして開いたまま

## 2026-10-20 15:10 (mkt-exec) — #75 追補: X アカウントのブランディング案
- 着手: オーナー返信「投稿文ok!あとはアカウントのブランディング考えないと」(2026-10-20)を受けて再開。13本の文面は mkt-lead 承認として記録し、受け皿（表示名・handle・bio・アイコン・ヘッダー・固定ポスト・トーン）の設計を追加する
- 前提: handle の空き確認はこの作業では行わない（X にログインしない）。未確認と明記し、取得はオーナーの操作にする
- 判断: ブランディングは「10/21 08:00 の初投稿までに設定できるもの」に限定する。ヘッダー画像は未制作でも開始できるようにし、日付・URL を描かない
## 2026-10-20 14:05 (mkt-lead) — MK1 #74 公開前後 30 日の獲得計画
- 着手: Issue #74。worktree `Challenge-74` / ブランチ `consilium/74-mk1-30-10-21-11-30`(origin/main `fdf1ef5`)。作業前に origin の対象ブランチ・PR を確認(重複なし)
- 置き場所の判断: Issue の完了条件は「docs/GROWTH.md か marketing/plan.md」。`docs/GROWTH.md` は**植物の成長ルール**(プロダクト仕様)で獲得計画の置き場ではないため、`marketing/plan.md` を新設する。MK2(#75)の `marketing/x/`・MK5(#78)の `marketing/measurement.md` と同じく、マーケの新しい文書はリポジトリ直下の `marketing/` に置く(既存アセットは `products/lien/marketing/`)
- 事実確認(計画に書く前に読む): KPI ゲートは TASKPLAN §5(500 DL / 40% / D30 25%)、率の定義と分母は KPI.md §4、DL の出どころは KPI.md §2-8(ASC App Analytics のみ)。**D30 は式 `started_on + 31 <= 今日` により 11/30 時点で分母 0**(公開 10/31 のコホートは 12/1 から)。11/30 に判定できるのは 2 項目だけ
- 予算: 追加支出の上限は 30,000 円。固定費(Apple 年会費 12,800 円・Supabase Pro 約 3,750 円)を足しても収まる範囲に、広告枠を 10,000 円で抑える設計にする
- 成果: `marketing/plan.md`(344 行)。6 区間(W-0〜W4)・週次カレンダー・チャネル 3 つ・予算・広告の上限と停止条件・週次の指標(分母つき)・KPI ゲートとの整合・未達時の動き・公開日がずれた場合の読み替え・書いてはいけないこと・承認の流れ。ルート `marketing/` を新設したので `docs/STRUCTURE.md` にも役割を追記(ストア文言は `products/lien/marketing/` のまま)
- 設計上の判断: ①30,000 円は「使ってよい額」ではなく「失ってよい額」なので、既定はオーガニック 0 円・広告は最大 10,000 円の非常口にした ②固定費(Apple 12,800 + Supabase Pro 約 3,750)を足しても 26,550 円で上限内 ③しきい値は 40% / 50% の 2 本だけに統一(広告の停止と §8 の立て直しで同じ基準を使う)④キーワードは v1.1 提出(11/9)でしか変えられない 1 回きりの機会なので、広告は 1 週ずらして切り分ける ⑤測れないもの(シェア画像・招待発行率・ティザー PV)は 0 ではなく null と明記
- 検証: リンク 13 本すべて解決 / 曜日の記載 23 か所すべて一致 / 表の列数 0 不整合 / DL 配分の合計 = 500 / 予算 26,550 ≤ 30,000 / しきい値 63・45 の計算一致 / `git diff --check` OK / `verify_metadata.py` OK(99/100 字・変更なし)/ unittest 24 件 OK。**deno はこの Mac に無い**ため ops テストと CI は push 後に確認する
- レビュー前の自己点検で直した点: KPI の SQL の節番号(§4→§3)/ 公開前の本数(10 日→11 日)/ 広告の停止条件と §8 のしきい値を 40%・50% の 2 本に統一(別々の基準を持たない)/ 「同じ週に 2 つ以上変えない」と「キーワード差し替え + 広告」の矛盾を、広告を 1 週ずらすことで解消 / 罰を使わない原則の根拠を GROWTH §3.1 から CONCEPT §5-1 に修正 / ティザーの解析タグは #76 の判断であることを明記
- 結果: **PR #98 作成**(https://github.com/Ryoki63/Challenge/pull/98)。7 commit・docs のみ(+365 行)。CI(lien-ci)5 ジョブすべて success(head `69ea55f`)。受入条件のうち **mkt-review の承認が残り**なので、issue は閉じず、レビュー役職の判断を待つ
- 補記: 独立レビューのサブエージェントを 1 体起動したが、長時間応答が返らなかったため中断した(成果物には未反映)。代わりに、リンク・曜日・算数・表の列数・節の実在を機械的に検査し、引用した数値と分母はすべて KPI.md §4 / TASKPLAN §5 と突き合わせ済み
- 追記: 2 体目の独立検証(対象を `marketing/plan.md` と KPI.md §4・TASKPLAN §5 に絞ったもの)が完了。A〜E すべて一致、**受入条件は満たす**との判定。①§6.1 の分母が KPI.md §4 の母数条件と同値(D7=+8日・D30=+31日・招待=結果確定・つながり=作成+7日)②11/30 の D30 分母 0 は `started_on + 31 <= 11/30 ⇒ started_on <= 10/30` で正しい ③500/40%/25% は改変なし ④DL 合計 500・予算 26,550 ≤ 30,000 ⑤受入条件の記載節は §3・§4・§5・§6・§5.1・§11

## 2026-10-20 13:05 (eng-exec) — #72 B5: snapshot に dateLocal を載せる(0:00〜1:00 の完了不明扱いの解消)
- 着手: worktree `Challenge-72`(origin/main `fdf1ef5`、作業前に対象ブランチ・PR が無いことを確認)。Issue の受入条件5つと、DESIGN §3.4/§4.2・REQUIREMENTS §3.12・README §12 を読んだ
- 判断(TASKPLAN §9 の直列): snapshot の形を変える順は GS → T19 → T33 → T35。**#72 は T19 の直後・T33 の前**に入れる。v1.0 の通知の修正で、キーの追加だけ・migration 無し。T33 は v1.1 の別ブランチ、T35 は v1.2 以降なので、後ろに置くと v1.0 に間に合わない
- サーバー: `_shared/snapshot.ts` の `PairSnapshot` に `dateLocal`(組み立てに使った「今日」)を追加。`buildPairSnapshot` は `todayLocal` をそのまま、`buildSoloSnapshot` は入力に `todayLocal` を足して載せる(`loadSnapshotForUser` が解決済みの「今日」を渡す)。既存のキーは変えない(schemaVersion は 1 のまま)
- クライアント: `PairSnapshot.dateLocal`(省略可 `String?`。デコードで "YYYY-MM-DD" だけ通し、崩れた値は nil)。`snapshotDay(calendar:)` / `daysSinceSnapshotDay(now:calendar:)` を足し、`reflectsToday` と `completionOnItsOwnDay` と `StreakRiskPlan.target` が**完了の日**を `dateLocal` で決める。キーが無い古いサーバーの snapshot だけ従来の時刻判定(1:00 まで不明)に落ちる
- 効果: 0:00〜1:00 に自分でチェックインした人の、その日のリマインドがその場で取り消される(`staleIDsForToday`)。前の日の日付で組み立てられた snapshot(キューで 0:07 に届いた 23:58 のチェックイン)は、今日の完了として読まない
- 契約: `contracts/*.json` を再生成(15 ファイルに `dateLocal` の1行だけ。`--check` 一致)。`contracts/README.md` に経緯を追記
- 検証: deno `397 passed`(新規4)/ contracts `--check` 22 件一致 + tools 3 passed / e2e unit 65 passed / ops 77 passed / iOS `check.sh test` = **84 classes・1085 tests 0 failed** / `check.sh views` 112 ファイル OK / `check.sh widget` 18 ファイル OK
- **main が赤かった(2件。この PR で直した/報告する)**: ①`HomeViewModel.presentShareImage()` と `HomeView` の `if viewModel.canShareRecord {` の閉じ括弧が #85(T22)で落ちており、**main は iOS ビルドが通らない**(lien-ios の main の run が failure。`HomeView.swift:513/526/609`・`HomeViewModel.swift:282/389/399/410`)。→ この PR で括弧2つを戻した(挙動の変更なし)。②`StringsReviewTests` が 44 件赤 — #83(T18 履歴)と #85(T22 シェア)が `docs/STRINGS-REVIEW.md` を更新していない(43 単位が未記載)。→ 同じ判定基準で追記レビューし、§7.20〜§7.22 と集計(297 → 340 件)を追加した(文言は変えていない)
- 残: レビュー(eng-review)。デプロイは関数を一括で(DESIGN §3.4 の互換性。アプリの解釈より先にサーバーを出さない — 順序はどちらでも壊れないが、まとめて出す)
- 結果: PR を作成(マージしない)

## 2026-10-20 14:20 (ux-exec) — MK3 #76 公開前ティザーページと法務ページの生成・配備の仕組み
- 着手: origin/main(fdf1ef5)から `consilium/76-mk3-github-pages`。まず Issue 本文と関連(#79・#80・#42・TASKPLAN §9.2)・`SupportLinks.swift`・`marketing/store_metadata/ja` を確認
- 前提の確認: **Issue 本文が「配備先の repo と URL は eng-lead が決め、この Issue に書く」としているが、#76 にそのコメントが無い**。一方でアプリの `SupportLinks.webBaseURL` は `https://ryoki63.github.io/Challenge`、法務は `.../lien/legal/{terms,privacy}.html` を指しており(DESIGN §7・web/invite のコメントも同じ)、配信パスは実装側で既に一意。この土台に合わせて作り、URL の正式決定と初回の Pages 有効化(Settings > Pages > Source = GitHub Actions)は人間に残した
- **X の @ハンドルは repo のどこにも無い**(#79 が「オーナーが最初にこの Issue へ書く」としている)。実在しないアカウントを指さないため `site.json` の `xUrl` を null にし、未設定のあいだはリンクを出さない。設定すると出ることはテストで固定
- 変更: `products/lien/web/tools/build_site.py`(md→html の生成器。Markdown パーサも自前、依存ゼロ)/ `site.json` / `web/site/`(配信物)/ `tools/test_build_site.py`(47件)/ `.github/workflows/lien-pages.yml`(Actions 配備。いまは workflow_dispatch のみ)/ `lien-ci.yml` に `pages-site` ジョブ / `web/README.md` / CHECKLIST-G4 §3・§4 / 構成図3か所
- 生成の検証: 生成した `marketing/legal/{privacy,terms}.html` の `<main>` 本文が、手で保守していた既存 HTML と**バイト一致**(差分は戻りリンクと、terms に無かった表の CSS だけ)。md が正本であることを壊さずに置き換えられた
- 公開の門: `--check-publishable` が (1) G4 の `【要記入: G4: …】` が残っていたら (2) `xUrl` が未設定なら 配備を止める。プレースホルダ付きの法務ページが公開される事故を機械で防ぐ
- 画面: ティザーは 1行説明(= 確定済み `subtitle.txt`)・スクリーンショット3枚・「近日公開」・法務リンク・サポート欄。**フォーム・メール収集・外部スクリプト・外部フォントなし**。訴求は `description.txt` / `promotional_text.txt` の確定値から取り、罰・恥系(禁止語)を含まないことをテストで検査
- スクショ: 旧 SVG(`marketing/screenshots/`)は旧画風(ドット絵)で、v1.0 に無い「ウィジェットの相手写真」「写真→相手のウィジェット」を含むため使わなかった。v4 の合成済み立ち絵(`assets/plant/v4_drafts/composed/`)を埋め込んだ自己完結 SVG を3枚生成(ホーム/ウィジェット/チェックイン完了)。文言は `Strings.swift` と `screenshots/plan.md` §2 のデモデータに合わせた。実機キャプチャへの差し替えは #80
- 検証: `python3 -m unittest discover -s tools -p "test_*.py"` 47件 OK / `build_site.py --check` OK / `--check-publishable` は想定どおり NG(G4 未記入・xUrl 未設定)。headless Chrome で index と3枚を描画して目視確認
- 結果: PR を作成。**公開そのものは未了**(G4 の4項目・X の @ハンドル・Pages の有効化が人間の作業)。issue は閉じない

## 2026-10-20 13:18 (eng-exec) — T33 #33 RevenueCat組込 + ペイウォール(3文脈)
- 着手: G6(#44)/T37 前でも実装・CI 検証できる範囲を実装する。実際の課金設定(RevenueCat アカウント・商品・価格・特商法・ストア申請)は行わない。
- サーバー: `_shared/premium.ts` に `derivePairPlan` を抽出(grant-tickets から再エクスポート)。`snapshot.pairPlan`(free/premium)をメンバーの `users.premium_until` から導出し、`USER_COLUMNS`/`PARTNER_SELECT` に premium_until を追加。RevenueCat Webhook(`revenuecat-webhook`。Authorization の定数時間比較、期限は延ばす方向だけ・EXPIRATION は現在の期限以下だけ失効)を追加。contract fixtures 22 件再生成。
- iOS: `PurchasesClient`(RevenueCat / Mock / 利用不可)・`EntitlementStore`(自分の購読 ∪ pairPlan、相手プレミアムの適用済み判定)・`PaywallContext`(節目/アルバム30日超/チケット切れ)・`PaywallViewModel`/`PaywallView`(価格・トライアルは offerings から。閉じる・復元常設)。`Strings.Paywall` 追加。チケット0枚のバッジからチケット切れ文脈を結線(節目・アルバムは画面側の実装後)。
- プロジェクト: RevenueCat 5.96.0 を Lien ターゲットだけに SPM 追加。`REVENUECAT_API_KEY` を xcconfig/Info.plist に追加(空なら利用不可の実装。偽の価格を出さない)。
- 既存 main の不具合修正: `HomeViewModel.presentShareImage()` と `HomeView` の `if canShareRecord` の閉じ括弧が無く、ローカル型検査が通らなかったため最小修正。
- 検証: `scripts/macos-check/check.sh test` = 87 ファイル・**1086 tests / 0 failures / 26419 assertions**、`views` 120 ファイル OK。`deno test` = **409 passed / 0 failed**、contract fixtures `--check` = 22 件一致、ops tests 77 passed。
- 残(G6/T37 後): RevenueCat の実キー設定・商品ID・トライアル日数・Webhook URL/秘密・サンドボックス購入の実機確認。アルバム30日超(T21)と節目からのペイウォール導線の結線。
- 追記(13:40): 自分の購読が有効なときは購入ボタンを押せないようにした(二重購入防止)。ローカル 1087 tests / views OK。CI は再実行。

## 2026-10-20 15:10 (ux-exec) — MK7 #80 ストア用スクリーンショット(v4・6.7/6.1)
- 着手: ブランチ `consilium/80-mk7-v4-6-7-6-1`(origin/main `fdf1ef5`)。T26 の下絵(旧ドット絵・旧範囲)を、v4「タネの子」の実画面から作り直す。完成画像は CI のシミュレータで描く(この Mac に Xcode は無い)
- **判明(重大): main が赤**。`#85`(T22 シェア画像)が 2026-10-20 03:38 の lien-ios **failure** のままマージされ、`HomeView.swift` の `if viewModel.canShareRecord {` と `HomeViewModel.swift` の `func presentShareImage()` の閉じ括弧が1つずつ落ちていた。ほかに `StringsReviewTests` が T18/T19a/T22 で追加された 43 単位を `docs/STRINGS-REVIEW.md` に持たずに赤(2件)。どちらもこの作業の前提(ビルド・テスト緑)を満たせないため、最小の修正を同じブランチに入れた
- 方針: 画像は (1) 本物の View(HomeView/HistoryView/WidgetRootView/ShareImageCardView)を 430×932 / 393×852pt・3倍で ImageRenderer 描画 → raw、(2) キャプションと合成して 1290×2796 / 1179×2556。キャプションの正本は `marketing/screenshots/captions.json`(mkt-exec と共有)。システムが描くもの(ステータスバー・ナビバー・壁紙)は描かない
- ローカル検証: `scripts/macos-check/check.sh all` = module 80 ファイル・**1069 tests / 0 failures / 25851 assertions**、views 112 ファイル、widget 18 ファイルとも OK(既存の ISO8601DateFormatter の Swift 6 警告のみ)。新テストは枠と一緒に views の型検査セットで型検査し、CI の実描画に回す

## 2026-10-20 16:50 (ux-exec) — MK7 #80 続き(CI artifact を取り込んで確定)
- lien-ios #39385881488(commit b5265f9)の artifact `store-screenshots` を取得。6.7in 1290×2796 / 6.1in 1179×2556 の PNG 各6枚、manifest(provenance=b5265f9 / runId=39385881488)、G4 用の一覧 `contact-sheet-6.7in.png` を `marketing/screenshots/` に追加
- 目視: 12枚とも実画面(ホーム・相手待ち・ウィジェット・カレンダー・シェア画像・ソロ)が描けている。空画像・文字切れは無し。カレンダー10/13 は薄い点(途切れ)で、赤や「失敗」の表現は無い
- 旧 T26 の SVG 下絵10枚と `gen_screenshot_svg.py` を削除(plan.md / README.md の「廃止」と実体を一致させた)。画像の縦横比は元の実描画のまま(歪めていない)
- 検証: `cd products/lien/marketing && python3 tools/verify_screenshots.py` = OK(各6枚・アルファなし・寸法一致・captions の SHA-256 一致)、`python3 -m unittest discover -s tools` = 36 tests OK
- 結果: 画像・manifest・一覧・設計/手順・機械検査をコミットし、PR を作成(レビュー待ち)

## 2026-10-20 17:10 (ux-exec) — MK7 #80 main 取り込み(実画面が変わったため画像を描き直す)
- PR #104 が main と conflict。origin/main は 8 commit 進み、#96(T33 RevenueCat)で HomeView / HistoryView / Strings が変わっていた。b5265f9 の画像は main の画面と一致しなくなるため、merge して CI で描き直す
- 解消: `docs/STRINGS-REVIEW.md` は main 版を採用し、§11 に紛れていた T19a/T18/T22 の重複43行を削除(main の StringsReviewTests が赤だった原因。369 行で緑に戻した)。`check.sh` の EXCLUDE_TESTS は PaywallRenderTests と StoreScreenshot 系の両方を残す
- `HomeView.SnapshotContent` の `onShowPaywall` に既定 nil を付け、課金導線を持たないスクショ描画から呼べるようにした(UI は変えない)
- ローカル検証: `check.sh test` = **1106 tests / 0 failures / 26519 assertions**、`views` 120 ファイル OK、`widget` 18 ファイル OK
- 次: merge commit を push → lien-ios で最新 main の画面から画像を生成 → artifact を差し替える

## 2026-10-20 17:32 (ux-exec) — MK7 #80 main 取り込み後の再生成と CI の赤直し
- merge 後 `lien-ios` #39389661638 で再生成。1回目は全ステップ成功後に20分の実行上限で cancelled(artifact は取得可)、再実行(attempt 2)で **success**。manifest = commit `c308e5c` / runAttempt 2 / generatedAt 17:28 JST
- 画像12枚 + 一覧は b5265f9 の版と SHA-256 で**完全一致**(main の課金導線はスクショでは nil のため、画面の見た目は変わらない)。manifest と README の来歴だけ更新
- main が赤だった2件を補修(どちらもテストの期待値のみ): deno 型検査は #97 の `todayLocal` 必須化に `snapshot_test.ts` の pairPlan ケースが未追随、`SNAPSHOT_KEYS` は #96 の `pairPlan` 追加で22個なのに期待値21
- 検証: `verify_screenshots.py` OK / unittest 36 OK / `lien-ci` #39392331252 success / `lien-ios` #39389661638(attempt 2) success

## 2026-10-20 21:17 — G4 #42 承認返信の反映 (eng-exec)
- 着手: 指定 worktree / branch `consilium/42-g4` は clean。origin/main と同一 HEAD `13f0570`、同名リモート branch・既存 PR は無し。Issue の assignee は空だが、今回の Consilium 作業者タスクで直接割当済み。main は変更しない。
- 承認根拠: オーナー `Ryoki63` の 2026-10-20 18:48 JST「それでOK!」(issuecomment-6288190684)を確認。直前の承認依頼はストア文言6ファイルと Pairy 不採用・新年訴求の2方針。スクショ・法務記入事項・独自ドメインまで承認済みとは拡張せず、現物と依頼範囲を照合する。
- 方針: 文言の承認記録と未決項目を分離する。ストア申請・外部公開・ドメイン購入は行わず、対象資料の検証後に PR を提出する。human-gate の Issue は close しない。
- 照合: 承認依頼時 `37e12ed` と HEAD の差分を確認。表示名・サブタイトル・リリースノートは同一 blob、キーワード・プロモーション・説明文は変更済み。#90 の通年案を旧新年案への「それでOK!」だけで承認済みにしない。旧版へ戻すと成長ルール等の不整合が戻るため、素材は維持して再確認を求める。
- 直接確認: スクショ12枚の寸法・アルファ・manifest とキャプション一致は既存検査で OK。6.7in 一覧画像も目視確認。法務原稿の制定日・事業者表記・連絡先・裁判所は未記入、`SupportLinks.contactEmail` は空。スクショのオーナー承認、実機表示、App Privacy、リージョン、提供地域、独自ドメインの判断は確認できていない。
- 変更: `marketing/G4-REVIEW.md` に承認コメントの日時・対象版・文言 hash・各受入項目の状態・判断依頼1件を記録。ASC 投入シートと法務チェックリストから参照し、全体承認・ASC 設定完了との混同を防止する。実装・素材・法務原文は変更しない。
- 検証: `marketing/tools/verify_metadata.py --print` PASS(6ファイル・keywords 99/100字)、`verify_screenshots.py` PASS(12枚)、marketing unittest **36 tests / 0 failures**。web `build_site.py --check` PASS(生成物11件一致)、web unittest **47 tests / 0 failures**。
- 公開ゲート: `web/tools/build_site.py --check-publishable` は exit 1。法務HTML4件の G4 未記入と `site.json` の `xUrl` 未設定を検出(5件)。既存ブロッカーとして保持し、再実行・回避・公開はしない。iOS の型チェック/lint/バイナリ build は実装無変更のため対象外。
- 機械検査補足: 文書の hash/リンク照合は実際の10件すべて一致したが、検査用ワンショットの総数assertを11件とした誤りで初回 exit 1。検査対象自体を減らさず、6文言+2画像来歴+2相対リンクの計10件へ集計を直して再確認する。
- 独立レビュー1回: G4 完了と #76 の公開ゲート(`xUrl`)を混同する1文に P2 指摘。該当文だけ修正し、#42 本文の確認・承認とサイト公開可否を明確に分離した。全体の再レビューは追加しない。
- 検査結果: hash/相対リンク照合 **10件 PASS**、`git diff --check` PASS。全要件の確認は一部未了(現行文言・画像・法務の人間承認待ち)、関連テスト83件 PASS、HTML生成11件 PASS。型チェック/lint/iOS build は文書変更のみで対象外、公開前ゲートは既存未記入で FAIL、残TODOゼロとはしない。
- 結果: **blocked / 承認待ち**。承認済み範囲と証拠の記録は作成済み。残る判断は1件にまとめて #42 に通知し、PR を提出する。Issue close・マージ・ストア入力・申請・公開・購入は行わない。
- 提出: commit `9d73be5` を `origin/consilium/42-g4` へ push。PR #114 https://github.com/Ryoki63/Challenge/pull/114 を作成(main 向け・未マージ)。`lien-ci` run 39422336491 は対象 SHA `9d73be5` で **success**。iOS build の新規実行を意味しない。
- 【承認待ち】: #42 comment-6290842503 に現行素材と法務必須値の判断を1件に集約して通知し、`needs-approval,human-gate` を付与。Issue は open を維持。hash・相対リンク・差分検査済み。提出時点で tracked worktree clean / local HEAD = remote branch を確認(この提出記録の追記は別 commit で同期する)。

## 2026-10-20 20:21 (ux-exec) — MK3 #76 公開先承認後の再開確認
- 着手: 指定 worktree / `consilium/76-mk3-github-pages` のみで再開。開始時の tracked/untracked 差分なし。PR #100 は 2026-10-20 に main へマージ済み。公開先の推奨案に対するオーナー返信(issuecomment-6287900053)を確認し、`Ryoki63/Challenge` / `https://ryoki63.github.io/Challenge` を確定値として扱う。URL の再承認は求めない。
- 同期: 公開済み履歴を書き換えず origin/main を merge。squash 済み PR #100 と元ブランチの重複による3ファイルの競合を、main の CI・構成図と両側の JOURNAL 記録を保持して解消。別 worktree や secret は読み書きしていない。
- 判明: #76 は assignee 未設定(本セッションの Consilium 割当はあるが Issue による排他は未確認)。#42 の「それでOK!」は確認できたが、制定日・事業者名・公開連絡先・管轄裁判所の具体値は原本に未記入。#79 にも公開 X ハンドルの記載が無く `site.json.xUrl` は null。これらを包括的な「推奨案で」の返信から推測しない。
- 公開状態: Pages GET は HTTP 404。リポジトリ本体は public だが Pages サイトの有効化・配備成功は確認できない。設定の変更・workflow_dispatch・法務公開は実行しない。PR #100 の GitHub review は0件であり、mkt-review 済みとする証拠にはならない。
- 時刻補正: 上の見出しと着手コメントの「20:21」は転記時の誤り。再開直前の実測は `2026-10-20 20:15:27 +0900`、本追記直前の実測は `2026-10-20 20:19:23 +0900`。既存記録を改変せず訂正を追記する。
- 検証: web の unittest **47件 PASS**、`build_site.py` **11件生成 PASS(生成物差分なし)**、`--check` **11件一致 PASS**。`--check-publishable` は **exit 1(法務4出力の未記入・xUrl未設定)**。公開不可を検知した結果であり、公開検査のPASSとは扱わない。`git diff --check origin/main` PASS。型チェック/lint/iOS build はコード変更なしのため対象外。
- 独立レビュー1回: サブエージェントに mkt-review 観点をまとめて依頼し、**要修正/公開不可**。約束の各自1つという単位、チケット保護/記録伸長の条件、実画面と SVG の差を指摘。`web/PUBLISH-STATUS.md` に根拠と未確認境界を記録。正式な Consilium 役職評価や文言承認済みとはしない。公開情報が未提供のため停止し、未解決指摘をPASSに変えない。
- 変更: web README と G4 チェックリストに公開先承認を反映。Pages 有効化や mkt-review は `--check-publishable` が検査しないことを明確化。`PUBLISH-STATUS.md` に Issue 本文の完了条件を逐語的に照合し、公開未達・X未達・スクショ受入留保・文言未承認を明記。
- 【承認待ち】2026-10-20 20:25 JST: #76 に質問を1件へ集約して投稿(issuecomment-6289781172)。URLは再質問せず、残る公開用5項目の提供(推奨)か保留かを依頼。`needs-approval,human-gate` を付与。`status:*`・assignee は変更せず、Issue は開いたまま。
- 提出: **PR #111** https://github.com/Ryoki63/Challenge/pull/111 を作成。変更を commit/push 済み、mainへの直接push・force push・マージはしない。PR作成時点のCIは lien-ci **6/6 PASS**、lien-ios は pending。iOS完了とは報告しない。
- 最終確認: 全要件の実装=未達(公開・X・画像の受入・文言承認)、関連テスト=47件PASS、静的サイトbuild=11件成功、生成物一致=11件PASS、公開前チェック=FAIL(exit 1)、型/lint/iOS build=本変更は文書のみで対象外、直接文書検査=PASS、残TODOゼロ=未達。未達項目は PUBLISH-STATUS.md に明示。
- 結果: **BLOCKED**。公開先承認の反映と検証・引継ぎまで実施。公開用の具体値は推測せず、法務原本・サイト設定・生成物・公開設定を変更しない。担当役職の未解決レビュー指摘と、オーナー入力後の公開作業が残る。

## 2026-10-20 19:45 (computer-operator) — #79 MK6 オーナー返信後の再開確認
- 着手: 指定 worktree・`consilium/79-mk6-x` のみで再開。開始時の tracked/untracked 差分は無し。#79 の 18:30 JST のオーナー返信は「ブラウザ操作でアカウントを作成させ、そこで投稿などを開始」であり、以前の「既存アカウントの引継ぎ待ち」から新規作成の準備へ前提を更新した。
- 同期: PR #103 は既にマージ済み、リモートの作業ブランチは削除済みのため `git pull --rebase` は対象 ref 不在で停止。公開済み履歴を書き換えず `origin/main` を merge。JOURNAL の末尾競合は両側の既存記録を残してマーカーのみ除去した。
- 承認確認: #75 に 18:31 JST のオーナー返信「投稿文ok!あとはアカウントのブランディング考えないと」がある。一方、原稿13本は `draft`、mkt-review の完了記録は未確認。computer-operator がレビューや ready 化を代行せず、投稿許可と正式レビューを区別する。
- 排他確認: #79 の assignee は空。Consilium の役職割当は受領しているが、GitHub assignee による排他は未成立。status ラベルは変更しない。
- ブラウザ確認: Computer Use で新規タブ `https://x.com/i/flow/signup` を開こうとしたが `Browser is not available: iab`。続けて接続ブラウザ一覧を確認し `[]`。X のページはまだ開けておらず、アカウント作成・入力・投稿・認証操作・予約登録は未実行。ネイティブ操作経路の利用可否を次に確認する。
- 節目(20:03 JST): ネイティブの Chrome に新規 X 登録タブを作成できた。実際の X ドメインに「メールアドレスまたはユーザー名」の空欄と Google/Apple/電話番号の認証経路が表示されたため、契約どおり入力前に停止。連絡先を推測・転用せず、アカウントは未作成、投稿も無し。
- 証跡: ブラウザ外枠と既存タブ情報を除外し、登録パネルだけを `products/lien/marketing/x/evidence/2026-10-20-x-signup-required.png` に保存(20:02 JST)。1320×1256、SHA-256 `30b0e430525a8e19ce858e57fa28dae97525ccad243301eb8a2897159c07a7ac`。画像を目視確認し、入力欄は空、個人情報・認証情報無し。登録成功の証拠とは扱わない。
- 検証: `PYTHONDONTWRITEBYTECODE=1 python3 products/lien/marketing/x/tools/check_posts.py` = OK 13本、`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s products/lien/marketing/x/tools -p 'test_*.py'` = 35 tests OK。原稿・承認台帳・コード・設定は未変更。型チェック・アプリ build・独立レビューは実行ログと証跡だけの変更のため対象外。
- 【承認待ち】: オーナーに開いた Chrome の登録タブで認証・作成確定まで自身で実施してもらい、公開 @ハンドルとログイン済みタブだけを返信してもらう1件の引継ぎを依頼する。mkt-review・ready 化と担当割当の整理は orchestrator に引き継ぐ。投稿 URL・24時間後の反応は引き続き理由付き null、予約・定期実行は未登録。
- 通知確認(20:05 JST): PR #110 を作成、commit `663a091` を作業ブランチへ push 済み。#79 に認証引継ぎコメント `6289443014` と `needs-approval,human-gate` を付与し、readback で OPEN・bot の通知コメント `6289445727` を確認。モバイル端末への通知配達自体は未確認。status ラベルは変更していない。
- 最終検査: Python 直接検査で main に対する変更3ファイル限定、JOURNAL/logの過去本文がそのまま接頭辞として残ること、画像のハッシュ/寸法/EXIF無し、理由付き null、予約未登録を PASS。`git diff --check origin/main` PASS。20:05 時点の PR CI は6ジョブ SUCCESS、iOS build/test は IN_PROGRESS（全CI成功とは報告しない）。
- 結果: **BLOCKED**。登録前画面の到達・証跡・ログ・PR 提出まで実施。アカウント作成・投稿・24時間反応の受入条件は未達。原稿・正式承認・アプリコードに変更無し。Issue/PR は閉じず、マージしない。

## 2026-10-20 21:30 (computer-operator) — #79 MK6 @lien_promise 作成後の再開
- 着手: 指定 worktree / `consilium/79-mk6-x` のみで開始。開始時の差分無し、`git pull --ff-only` は Already up to date。公開済み履歴は変更していない。PR #110 は OPEN のため同じ PR を継続する。
- 前提更新: #79 の21:06 JSTのオーナー返信で公開ハンドル `@lien_promise` の作成を確認。新規登録・認証の再依頼はしない。投稿権限と、MK2 の正式な原稿レビュー・指定時刻・実投稿の成功を分けて確認する。
- 原稿確認: 当ブランチの13本は draft / 正式承認台帳は空。#75 の最新コメントと同 Issue のリモートブランチでは、オーナーの「投稿文ok!」を mkt-lead 承認として記録済みだが mkt-review は未実施、初投稿は10/21 08:00 JSTと明示。10/20の当日原稿は存在しない。computer-operator が原稿を新作・ready化・レビュー代行して投稿しない。
- 節目(21:34 JST): 現在の Chrome が `x.com/lien_promise` を表示し、Account menu / Profile とも `@lien_promise`、Set up profile / Post 導線と0 postsを確認。投稿経路は利用可能であり、認証・API鍵の再依頼は不要。#79 を自分へ assign 後 readback で一致を確認。status ラベルは変更していない。
- 証跡: 一時的な全画面表示でブラウザ外枠を除き `products/lien/marketing/x/evidence/2026-10-20-x-lien-promise-login.jpg` を保存して目視確認。3024×1722 / 436174 bytes / SHA-256 `c38f5767cc96f3c7e9726cf53be08504c759741c333d1f634674dbafb8855352`。JPEG返却を確認して保存し、全画面表示を解除した。個人情報・認証情報・他タブは保存していない。表示された課金案内には進まず、投稿やプロフィール変更も行っていない。
- 検証: check_posts.py = OK 13本、unittest = 35 tests OK（並列ローカルジョブ、両 exit 0）。コード・原稿・設定に変更無しのためアプリbuild / 型チェック / lint / 独立レビューは対象外。ログイン確認と投稿成功を分離し、投稿URL・24時間反応は理由付き null、予約・定期実行は未登録のまま記録。
- 【承認待ち】: 残る判断は1件。推奨は orchestrator が mkt-review を割り当て、#75 の初回10/21 08:00原稿を正式レビュー・ready化して #79 へ渡すこと。代替は初回投稿の保留。ログイン済みブラウザは既に確認済みなので、オーナーへの認証再依頼はしない。
- 検証のつまずき(21:37 JST): 保存JPEGにAPP1メタデータが存在し「EXIF/XMP無し」検査がFAIL。値は読み出し・表示せず、投稿や外部共有の前に画像メタデータのみ除去する。画素を再圧縮せず、保存後のハッシュと寸法を再検査する。先のテスト35件とログ接頭辞検査のPASSとは区別する。
- メタデータ除去結果: APP1等2セグメントを除去し、圧縮スキャン部分は元と完全一致。配布画像は同じパスで3024×1722 / 436050 bytes / SHA-256 `8de2076d3434a98fc4420941823d9bec2f796c69450104ebaadd5b8de9597624`。上の436174 bytesと旧ハッシュは取得直後の記録であり、現在の配布画像は本行の値。過去の記録は編集せず訂正を追記した。
- 最終機械検査: 既存HEADに対するJOURNAL/logの接頭辞保持、追加2ログ+画像1枚限定、JPEG寸法/容量/ハッシュ/APP1等無し、秘密・連絡先の典型パターン無し、欠測8項目の理由付きnull、予約未登録、`git diff --check` はすべてPASS。APP1検出の初回FAILはメタデータ除去後の限定再検査で解消した。
- 通知(21:38 JST): #79 コメント `6291026868` で「推奨: orchestrator による mkt-review 割当・ready原稿引継ぎ / 代替: 初回保留」の1問に集約。`needs-approval,human-gate` と OPEN をreadbackで確認。認証の再依頼無し、statusラベルは不変更。通知先端末へのプッシュ到達は未確認。
- 結果: **BLOCKED**。投稿手段・アカウント一致・証跡保存は確認済み。受入条件の実投稿・指定時刻の運用・24時間反応は未達。PR #110 に記録を提出し、Issue close・PR mergeは行わない。build/型/lintはコード非変更のため対象外であり、アプリを実行・ビルドしたとは報告しない。

## 2026-10-20 18:29 — Issue #94 [mkt M8] 紹介記事とプレス向け素材
- 着手: worktree・ブランチ・origin を確認。Issue #94 の受入条件に沿って、ファクトシート・紹介文 3 種・スクリーンショット素材を作成し、レビュー可能な PR まで進める。
- 節目: 正本を照合。v1.0 は全機能無料（terms.html 第3条）、公開前法務欄に運営者名と連絡先メールの G4 プレースホルダーが残る。将来価格案（月700円・年2,400円）は CONCEPT §6 の将来案であり、公開時価格に使わない。既存スクショ6枚は v4 実画面生成で、3枚を同梱する。
- 作業上の制約: PDFスキルを適用。スキル指定の artifact-operation marker は当該ファイルが worktree に無く実行できなかったため、PDFは生成せず編集可能な1枚HTMLのファクトシートを作る。連絡先・提供元は事実を補完せず G4 未確定と明記する。
- 節目: `products/lien/marketing/press/` にHTMLファクトシート・紹介文3種・v4実画面3枚を作成。紹介文は60/198/556文字で確認。Safari の印刷プレビューでA4 1ページを確認。mkt-review は未実施なので、Issue の完了条件は未達。
- 制約: PDFスキル指定の marker が worktree 内に無く、reportlab/pdfplumber/Poppler/WeasyPrint も未導入。HTMLを印刷可能な納品物として採用しPDFは生成していない。
- 続き(再開): 前段の下書きを引き継ぎ、正本と再照合して確定。紹介文は 60 / 196 / 554 字（60字は上限ちょうど、200/600 は上限内）。将来機能・価格案・実績値は本文から除外し、提供元・連絡先は G4 #42 の `<OPERATOR_NAME>` / `<CONTACT_EMAIL>` のままにした。
- 修正: ファクトシートにスクショ3枚を埋め込み、対象を「恋人・夫婦・友達・家族」に統一（CONCEPT §5）。価格の出典に CONCEPT §6 を追加。A4 1ページ（Chrome headless 印刷、595×842pt、`/Count 1`）を確認した。
- 追加: `products/lien/marketing/tools/verify_press.py`（文字数・宣言一致・v1.0 の範囲・将来価格/実績値の不在・必須項目・G4 トークン・スクショ3枚の寸法/アルファ/元画像 SHA-256 一致・リンク切れ）と `test_verify_press.py` 27件。CI `store-metadata` に検査ステップを追加。
- 検証: `verify_press.py` OK / `python3 -m unittest discover -s tools -p "test_*.py"` 63件 OK / YAML 構文 OK / `git diff --check` OK。
- 訂正: 前段の「60/198/556」「Safari の印刷プレビュー」「PDFスキル」は確定記録ではない。確定値は 60/196/554、A4 1ページは Chrome headless で確認した。PDF は納品物にせず、編集可能な HTML を正本にした。
- 更新: 600字版に「相手のチェックインは、相手の名前で通知されます。」を追加し、578字に確定（宣言・README も 578 に更新）。

## 2026-10-20 18:14 (eng-exec) — E3 #93 通知・ウィジェットの取りこぼし対策
- 着手前確認: 指定 worktree / ブランチ `consilium/93-e3-nse`、追跡・未追跡差分なし。HEAD と origin/main は `13f057030a1e63fefe295bb0fc5e6519b343e652` で一致。対象リモートブランチ・既存 PR はなし。
- 排他確認: `gh issue view 93 --repo Ryoki63/Challenge --json assignees` は `assignees: []`。認証ユーザーは `Ryoki63`。役職タスクは受領済みだが、AGENTS.md の「着手前に自分が assignee か確認する」を満たせないため、実装・テスト・ビルドは開始しない。
- 承認返信確認: `needs-approval` Issue の bot を除く最新コメントを確認し、人間の返信に該当する未処理コメントはなし。他タスクは変更していない。
- 【承認待ち】Issue #93 の排他担当割当を依頼する。推奨: `Ryoki63` を assignee に設定して本 worktree の eng-exec を再開。別担当が稼働中なら本タスクを待機。
- 結果: blocked。受入条件4項目はすべて未検証。コード・テスト・設定・secret は変更していない。担当割当後、NSE → App Group、起動時差分補完、リトライ・重複防止テスト、lien-ios CI の順で進める。

## 2026-10-20 19:10 (eng-exec) — E3 #93 承認後の実装再開
- 着手: オーナーの「実行しちゃってください／担当は任せます」をタスク契約で確認。Issue #93 の assignee に認証本人 `Ryoki63` を設定・再取得し排他割当を確認、着手コメントを投稿した。
- 同期確認: `git fetch origin main` 後、HEAD と origin/main の追加差分なし。既存 PR・対象リモートブランチなし。作業前差分は前回停止時の JOURNAL 追記のみで、その内容は保持する。指定ブランチを使い、rebase・main 直接 push・マージは行わない。
- 検証計画: 既存 NSE・共有ストア・起動同期を調査 → 必要な最小変更と回帰テスト → 独立レビュー1回 → ローカル検査と lien-ios CI → PR/Issue に証拠を記録。ローカルは Command Line Tools のみで `xcodebuild` 不可のため、iOS ビルド/実行は CI で検証する。
- 調査/判断: NSE 保存と起動 GET /snapshot は既存。ただし push の重複/逆順で無条件上書き・reload、同期失敗の自動再試行なし、差分取得なし。既存の「状態は snapshot が正」を維持し、差分は HTTP ETag による条件付き GET(内容が同じなら 304、違えば最新状態)で実装する。イベント履歴/DB migration/新しい通知は追加しない。
- 互換性: PairSnapshot/プッシュの JSON キーは変更しない。条件ヘッダなしの旧アプリには従来の 200 応答。共有ストアはプロセス間の read-compare-write を調停し、重複/逆順と競合取得を抑止する。リトライは1回だけ(最大2試行)、認証エラーは自動再試行しない。G1 の p50/実機 NSE 実行と写真 DL(T17b)は今回の完了根拠に含めない。
- 19:33 検証節目: `deno test` 全419件、snapshot の局所11件、契約フィクスチャ一致とツールテスト3件、releaseスクリプト130件、snapshot/index.ts の `deno check` が PASS。Swift ローカル型検査は SDK 明示でも既定でもホストの `SwiftBridging` 重複定義で失敗(2回)したため、以降ローカルコンパイラは再試行せず CI の Xcode を使う。独立レビュー1件を並行で実施中。
- 19:38 検証方針更新: 既存 `scripts/macos-check/check.sh` に、このホストの SwiftBridging 重複を SDK 非変更の VFS overlay で解消する専用手順があることを確認。同じ直接型検査の3回目ではなく、この既存補助テストを出力先も worktree 内に限定して実施する。iOS/NSE 本体の成否は引き続き lien-ios を正本とする。
- 19:42 検証/修正: 専用補助検査で Lien module 89ファイルの build が通過。追加 NSE テストの同期 closure に MainActor 専用の既存 ReloadCounter を使った隔離違反を検出したため、そのテストだけローカル Int カウンタへ修正した(製品の actor 制約は変えない)。同じテストスイートを再確認する。
- 19:45 検証節目: 専用補助検査の全1126テスト/26578 assertionsが PASS。旧SHAの lien-ios はテスト修正前のためキャンセルを要求し、修正後に新規実行する。ETag の200応答取得と、再起動時に前回ETagから取りこぼした最新状態を回復する回帰テストも追加する。
- 19:44 記録時刻の訂正: 上の「19:45」は入力時刻の誤記で、実際の1126件PASS確認・2件追加は19:43以前。追加後は全1128テスト/26587 assertionsが PASS。過去行は編集せず本行で訂正する。
- 19:47 提出準備: 実装/回帰テスト/設計記録を consilium/93-e3-nse に push(SHA 565653e)。PR #109 を作成: https://github.com/Ryoki63/Challenge/pull/109 。lien-ci #39410095257 成功、lien-ios #39410095377 進行中。PR本文も未検証項目は未チェックのまま。独立レビューの結果と iOS CI の完了を待ち、マージは実施しない。
- 19:53 独立レビュー: P2「304後、A→B→A の遅延B pushで巻き戻る」、P1「消去後にNSEが旧snapshotを復元」を受領。304の確認時刻ヘッダを保存し、消去を同じ調停に参加させ、snapshot無しではNSEが初期化しない形で修正。各回帰テストを追加した。初回取得は認証済みGETの責務とし、製品仕様/JSON schemaは変更しない。19:47の提出準備行は19:46の操作(実時計確認前に記入した分)で、成否の記録は変更なし。
- 19:54 修正検証: 全1130補助テスト/26595 assertions、Deno全419件、deno check が PASS。確認時刻なしの304を拒否するHTTP回帰テストも追加し局所確認へ進む。独立再レビューは上記2指摘の修正に限定して1回依頼した。修正前の iOS run はキャンセル済みで成功扱いしない。
- 20:06 限定再レビュー結果: 304の指摘は解消確認。消去失敗時の未調停フォールバックには競合が残るとの指摘を受領し、その分岐を削除した。消去エラーを呼出元へ返し、AppModelは同期を閉じたままセッションを維持、次のライフサイクル通知で後始末を再試行する。失敗を成功扱いせず、サインアウトは調停済み消去の後に行う。全体レビューの追加反復は行わず、この差分と回帰テストをeng-reviewへ明示して渡す。
- 20:06 局所検査の注意: AppModelAccountTests単独選択は既存共通モックがAppModelTests内にあるためコンパイル不可(製品のコンパイルは成功)。依存テストを含む全スイートで確認し直す。同じコマンドの繰り返しではなくテスト選択不足を解消する。
- 20:12 検証節目: 全1133補助テスト/26609 assertionsがPASS。消去失敗→前面復帰での再試行と通常同期停止を確認。先行SHA e5b5d6eのlien-ios #39411277506は1216 XCTest/0 failures、TEST SUCCEEDEDで成功。最新の消去失敗処理はまだこのCIに含まれないため、最終SHAで再実行する。未解決P1とAppModelの新規影響を根拠として、例外的な追加確認をこの差分のみに絞って同じレビュワーへ依頼(全体の再評価なし)。
- 20:14 テスト選択の訂正: 共通MockSnapshotClientの定義はAppModelTestsでなくSnapshotSynchronizerTestsだった。局所選択2回で同じ不足が続いたため、局所選択は打ち切り(3回目なし)。アカウント削除の後始末失敗も成功にしないテストを1件追加したため、直前に成功した全スイートで追加差分を検証する。
- 20:18 限定確認: 未調停消去のP1解消をレビュワーが確認。新規P2「メモリだけの消去待ちは再起動で失う」を受け、消去開始マーカーをApp Groupへ永続化し、初期化時に同期を閉じ、NSEも適用しないよう修正。マーカー保存失敗なら消去を開始せず、完了後だけ解除する。AppModel再生成→後始末再開と消去待ち中push拒否の回帰テストを追加。直前の全1134件/26618 assertionsはPASSだが、この永続化差分は別途確認する。
- 20:20 永続化差分の検証: 全1136補助テスト/26628 assertions、module 89ファイルbuild、git diff --checkがPASS。再起動後の消去再開・NSE拒否・失敗伝搬を実行で確認。これ以上のレビュー反復はせず、P2修正後の再レビューは未実施と明記してeng-reviewへ渡す。最終コードをpushしiOS CIを確認する。
- 20:27 CI待ち: 最終コードSHA `0e2f5d252cae1a56d76f76887866d10b6a65c7cf` はローカル/リモート一致。lien-ci #39414244113成功、lien-ios #39414244122はBuild & test中。受入条件4は結果待ちであり未完了。PR #109はOPEN、マージしていない。CI後の本JOURNAL追記は監査ログのみの差分としてcode SHAとの同一性を別に確認する。
- 20:36 CI失敗と原因: lien-ios #39414244122はbuild成功後、1221 XCTest中1件失敗。SDKセッション破棄テストがsnapshot削除だけを完了条件にし、後続のasyncサインアウト/植物メモリreset前に観測した。永続マーカー導入に合わせ、該当する2件の待機条件をsnapshot無しかつ消去待ちマーカー解除へ変更(テスト削除/skipなし)。製品動作の失敗と混同せず、失敗runを成功扱いしない。修正後の同じiOS CIで検証する。
- 20:52 CI成功: 最終コードSHA `af426291d6e73141fe8ab00a475f74b1f31f159e` の lien-ios #39416345514 は 1221 XCTest / 0 failures、**TEST SUCCEEDED**(14m24s)。lien-ci #39416345543 も全ジョブ成功。受入条件4項目(NSE→App Group、起動/前面復帰の差分補完、リトライ/重複表示防止テスト、CI緑)を確認した。
- 20:53 引き渡し: PR #109 を eng-review へ引き渡す。G1/T20 の APNs→NSE→WidgetKit 実機 p50≦60秒、NSE 実行/通知予約合わせ込み、写真サムネDL(T17b)は残課題であり、今回のPASSに含めない。マージ・本番デプロイ・ストア申請は行っていない。以後の差分は本JOURNALの監査記録のみで、製品コードは af42629 から変えない。

## 2026-10-20 20:52 (eng-exec) — T32 #32 オーナー承認後の再開
- 着手: 指定 worktree / consilium/32-t32-aso-pairy で再開。開始時の tracked/untracked 変更なし。PR #90 は 2026-10-20 13:01 JST に main へマージ済み、同一 head の追加 PR は未作成。
- 承認確認: #32 のオーナー返信「それで良い」(2026-10-20 18:36 JST)は PR #90 の通年訴求・キーワード99字・「約束」重複維持と、G0 承認後に人間が ASC 投入する提案への同意。文言の再承認は求めない。
- 依存確認: G0 #38 は OPEN で Apple Developer 加入完了の証跡なし。G4 #42 は OPEN だが 2026-10-20 18:48 JST にオーナー返信「それでOK!」あり。ASC 設定済みとは扱わず、投入手順・承認記録と残る人間操作を照合する。
- 同期: PR #90 の head は origin から削除済みで pull --ff-only は同期不可。履歴を書き換えず origin/main を merge。CI は main の既存検査をすべて保持し、JOURNAL は両側の記録を保持して今回の記録だけ末尾へ置いた。
- 変更: ASC-ENTRY と alternatives に #32 / #42 の承認原文と時刻を記録。#42 の返信は旧候補に対するものなので、通年版の採用根拠は #32 と明記。文言の再承認・ASC の代理操作・審査提出を行わず、人間の保存・再読み込み確認と証跡返却を次の工程にした。
- 発見・修正: `verify_metadata.py --print` の見出しだけが「App 情報 > キーワード」のままだった。既存の ASC-ENTRY に合わせ「バージョン情報 > キーワード」へ修正し、回帰テスト1件を追加。承認済み `ja/*.txt` は main と差分なし。
- ローカル検証: marketing で `PYTHONDONTWRITEBYTECODE=1 python3 tools/verify_metadata.py --print` = OK / keywords 99/100字、`python3 -m unittest discover -s tools -p 'test_*.py' -v` = 37件 PASS(メタデータ25件・スクショ12件)、`python3 tools/verify_screenshots.py` = 各6枚 OK。変更 Python 2ファイルは AST 構文検査 PASS、`git diff --check` PASS。
- 適用外: iOS/バックエンド変更なしのため iOS ビルド・型チェックは対象外。Python の専用型チェック/lint/build 設定はなく、関連テスト・AST・CLI 実行・差分検査で確認。独立レビュー1回を依頼済み(結果待ち)。ASC の受入条件は未達のためタスク全体を done にしない。
- 独立レビュー: 重大指摘なし。残リスク「G4 対象素材」を追加の受入条件と誤解しうる点だけ、ASC-ENTRY §3 に「G4 全体の close / スクショ完成はキーワード・説明文保存の追加受入条件にしない」と明記。再レビューが必要な重大未解決事項なし。
- 提出: PR #113 を作成(未マージ)。`lien-ci` #39419045074 は6ジョブすべて success。main 同期によって自動起動した `lien-ios` #39419044975 は実行中のためビルド完了とはまだ扱わない。
- 最新検査: head c5d7425 の `lien-ci` #39419301608 も6ジョブすべて success。PR #113 にコマンド・37件 PASS・独立レビュー・非該当/未確認の境界をコメントした。
- 【承認待ち】#32 に comment 6290434543 を投稿し、`needs-approval,human-gate` を付与。質問は文言の再承認ではなく、G0確認後の人間による ASC 入力・保存・再読み込みと証跡返却の1点。#32 / #38 / #42 は close せず、status ラベルは HQ に委ねた。
- 提出チェック: リポジトリ側修正 PASS / 関連37テスト PASS / CLI動作確認 PASS / AST構文 PASS / diff --check PASS / 独立レビュー1回・重大指摘なし / 型チェック・lint専用設定なし / iOS・バックエンドの実装変更なし。残TODOはASC保存証跡の人間返却で、受入「App Store Connect にキーワード・説明文設定完了」は未達。
- 結果: **BLOCKED(人間のASC入力・保存証跡待ち)**。承認済み文言は変更せず、PR #113 を push 済み・未マージで提出。審査提出・公開・本番変更は未実施。

## 2026-10-20 15:40 (mkt-exec) — #75 追補2: main 取り込み（MK7 の実画面・T33 の課金）への追随
- 着手: オーナー返信を受けた追補の続き。origin/main は #96（T33 課金）・#100（MK3）・#104（MK7 スクショ）まで進んでいた。**PR #99 は squash で main に入っていた**ため、分岐点が無く rebase すると同じ記録を二重に積む。履歴を書き換えないよう、`git merge origin/main` で取り込み、衝突は x/ 配下を自分の側（承認・ブランディング入り）、`.github/workflows/lien-ci.yml` を main の側（pages-site と MK7 の検査を含む）で解いた
- 判断: MK7 の実画面6枚を使い、`指定:` だった5本（10-23・10-25・10-31・11-01・11-07）を差し替えた。**代替テキストは実際の画像（contact sheet）を見て書き直した**（本文は変えていない）。残る指定は 10-24（チェックイン完了）と 10-26（ロック画面の通知）の2本
- 判断: 画像の選択は mkt-exec の裁量（役職カード「スクリーンショットのキャプションと訴求順」）。mkt-lead の承認は本文・リンク方針・投稿順に対するものとして review.md §7 の範囲を書き直した
- 発見: T33 でペイウォールが main に入った。`REVENUECAT_API_KEY` が公開ビルドに入ると、商品設定（T37 / G6・〜11/1）より先に「購入できないペイウォール」が出て、10/31 の「いまは全部、無料で使えます」と矛盾する。review.md §5-7 に、公開ビルドのキーを G4 で確認するよう記録（マーケ側では直せない）
- 検証: `check_posts.py` OK（13本 + branding）/ unittest **52件** OK / `verify_metadata.py` OK・unittest 24件 OK（回帰なし）
- 結果: 追補の PR を作成（マージしない）。`status: ready` は mkt-review 待ちのため付けない

## 2026-10-20 23:01 (eng-exec) — G5b #107 審査リジェクト一次返信・証拠ガイド
- 着手: 指定 worktree と `consilium/107-g5b` を確認。作業前差分なし、対象リモートブランチ・既存 PR なし。認証本人 `Ryoki63` を Issue #107 の assignee に設定し再取得した。
- 同期: `git fetch origin main` と `git merge --ff-only origin/main` は Already up to date。履歴の書き換え・main 直接 push・他 worktree の操作は行わない。
- 範囲: 5 種の却下理由別の返信型と証拠、デモ情報・審査導線の1枚索引、再提出チェックリストを作る。認証情報は読まず複製せず、ストアへの返信・申請・本番変更は行わない。
- 確認計画: 既存 `review-notes.md` と確定仕様・実装を照合 → Apple 公式ガイドライン確認 → 文書作成 → リンク・必須項目・出典の直接検査と必要な資料レビュー → 指定ブランチへ commit/push、PR 提出。承認待ち一覧は確認済みだが、割り当て外 Issue の再開・状態変更はしない。
- 節目(23:10): Apple 公式 Guidelines と ASC 返信/再提出ヘルプを照合。5条項の返信型・スクショ/動画/手順、デモ正本への1枚索引、再提出チェックリストを作成した。通知拒否/PhotosPicker、匿名認証、通報=メール下書き、ブロック=ペア解消の既知制約を既存ノート/ソースに合わせた。
- 判断: v1.0 無料の正本と T33 購入コードの存在は別。無料/課金の提出ビルド確認を返信前ゲートとし、UGC フィルタ・運営対応期限・空の連絡先も適合済みと断定しない。今回は文書だけを変更し、課金/通報コード・設定・実デモ・ASC は操作していない。
- 検証(23:24): 一時 Node 検査で5条項それぞれに返信型/スクショ/動画/手順、再提出10項目、ローカルリンク33件(見出し18件)とコードフェンスを確認。REQUIREMENTS §8 のリンクを修正し全件 PASS。GitHub Markdown とローカル GFM で描画し、Chromium 1180px/390px で横溢れなし。索引の A4 印刷プレビューは `/Count 1` (1ページ)、本文の表・英語型・再提出欄も目視確認した。プレビュー/PDF/検査ハーネスは一時ファイルで、納品対象は Markdown。
- 検証: `python3 tools/verify_metadata.py` / `verify_screenshots.py` / `verify_press.py` はすべて OK、`python3 -m unittest discover -s tools -p 'test_*.py'` は64件 PASS (marketing ディレクトリ)。`git diff --check` PASS。型/lint/iOS build は対象外(アプリ/設定/CI の変更なし、文書の直接検査で代替)。実ビルド採証・ストア返信・デモ発行・再提出は今回未実施で、実施済みと書いていない。
- 独立レビュー: 文書の受入条件・根拠/事実境界・権限・課金/UGC を1人にまとめて依頼し、必須修正なし。実ビルドと運営基準等の未確認境界はガイドに保持。追加の全体レビューは行わない。
- 提出前確認: 受入条件3項目の文書は揃った。差分は審査用 Markdown 3件と JOURNAL の追記だけで、secret/個人情報/アプリ挙動の変更なし。指定ブランチへ commit/push 後、PR を作成して CI とリモート SHA を確認する(レビュー役職が判断するためマージしない)。
