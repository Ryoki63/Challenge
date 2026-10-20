# Lien Android v1.0 テスト計画・端末マトリクス

- 作成日: 2026-10-21
- 担当: qa-lead（品質・セキュリティ部長）
- Issue: #123 `[AND-QA] Android 版のテスト計画と端末マトリクス`
- 状態: **テスト計画の提案**。実機・CI での実施結果ではない。実施結果はリリース候補（RC）ごとに別途記録する。
- 承認: qa-lead（本計画の責任者）。独立レビューと orchestrator の確認を経て確定する。
- 対象: Lien（APP-001）Android v1.0。iOS v1.0（10/31 公開）を最優先とし、Android は iOS の E2E・審査・課金を遅らせない範囲で進める。
- 正本: [docs/REQUIREMENTS.md](../REQUIREMENTS.md)（WHAT）/ [docs/DESIGN.md](../DESIGN.md)（iOS の現行実装・HOW）/ [docs/E2E-M1.md](../E2E-M1.md)（iOS 実機 E2E）
- Android の要件差分: PR #132 の `docs/android/REQUIREMENTS-ANDROID.md`（2026-10-21 時点で未マージ）
- Android の全体計画: PR #131 の `docs/android/PLAN-ANDROID.md`（2026-10-21 時点で未マージ）
- 技術設計: `docs/android/ARCHITECTURE-ANDROID.md`（Issue #121 で作成中。本計画の作成時点では未存在）

> 本 Issue の受入条件は本文の4項目だけである。本書の「公開判定基準」は製品仕様を追加するものではなく、qa-lead が公開可否の判断材料を orchestrator に提出するための QA ゲートである。受入条件そのものを独断で緩めない。

---

## 0. 結論（先に 8 行）

1. **テスト対象 OS は Android 10〜16（API 29〜36）**。推奨は `minSdk 29` / `targetSdk 36` / `compileSdk 36`。Google Play は 2026-08-31 以降、新規アプリと更新に API 36 以上を要求する。
2. **最小で効く構成は、エミュレータ2台（API 29 / 36）＋ Android 実機2台（API 36 の stock 端末 / API 33〜34 の OEM 端末）＋ iPhone 1台（iOS 17+）**。これで旧 OS・通知権限・最新 OS・OEM の電池制御・launcher・iOS 混在ペアを押さえる。
3. **ウィジェットは Glance のホストテストと実 launcher を分ける**。`updatePeriodMillis` は最短30分、WorkManager の周期実行も最短15分で、**60秒 p50 は OS の保証ではない**。可視 push / data-only push からの更新を実機・launcher 別に10回計測する。
4. **FCM は「通知メッセージ」と「data-only メッセージ」を分けて試験する**。data-only はウィジェット更新の第一候補だが、バックグラウンド実行時間・Doze・強制停止の制約を受ける。通知メッセージはバックグラウンドでシステム通知欄に出て、通常 `onMessageReceived` を呼ばない。
5. **Doze / App Standby / OEM の電池最適化は、エミュレータの `force-idle` で近似できるが、実機の OEM 挙動は代替できない**。CI の合格を実機合格と読み替えない。
6. **iOS⇄Android の相互運用は、同じ Supabase の別ユーザーとしてペアを組み、APNs と FCM の token を上書きしないことを確認する**。端末のタイムゾーン混在は v2+ の厳密対応であり、v1.0 は国内（JST）ペアを前提にする。
7. **CI は unit / contract / lint / assemble を毎 PR、instrumentation を API 36 で毎 UI PR、API 29/33 を nightly と RC で回す**。実 FCM・Doze・実 launcher・性能・Play pre-launch report は実機または Play Console の範囲に残す。
8. **公開可（QA 推奨）の条件は、S0/S1 が 0 件、P0 ケースが指定のゲート構成で PASS、CI が RC の SHA で緑、セキュリティ・プライバシー確認完了、iOS 回帰と混在ペア E2E が緑**。未実施のゲート項目を「合格」と読み替えない。

---

## 1. 位置づけと範囲

### 1.1 この文書で決めること

- テスト対象の OS 範囲と、実機/エミュレータの最小マトリクス
- ウィジェット更新・FCM 受信・Doze/省電力下の試験観点
- iOS⇄Android ペアの相互運用試験項目
- CI で回す範囲と、実機でしか見られない範囲の仕分け
- 重大欠陥の判定基準と、公開可否を判断するための QA ゲート
- 実施体制・証跡・スケジュール・未確定事項

### 1.2 対象（Android v1.0）

`docs/REQUIREMENTS.md` の `[v1.0]` と、PR #132 の Android 要件差分で「含める」とした範囲を対象にする。Android 専用の新機能は追加しない。

- 匿名 Auth、セッション保存、オンボーディング
- 約束1つ（20字・絵文字・リマインド時刻）、ソロ利用
- 招待（8文字コード・QR・`lien://` リンク・72時間・1回限り）、ペア成立・ペア解消
- チェックイン（1日1回、当日取消、任意写真、オフラインの冪等キュー）
- ふたりストリーク、お休みチケットの自動消費、カレンダー
- つつく、リアクション、植物（10段階・ふたりの葉・名前）
- ホーム S 相当の Glance ウィジェット、ウィジェットからのホーム遷移
- 端末ローカル通知（リマインド・21時のストリーク危機）
- サーバー通知（相手のチェックイン・写真・つつく・リアクション等）の FCM 配送
- シェア画像、設定、アカウント削除、サインアウト
- iOS⇄Android の混在ペア（同じ Supabase project / Auth / Edge Functions / DB / Storage）

### 1.3 対象外（この計画では合格を判定しない）

- 課金・ペイウォール（v1.1。Google Play Billing / RevenueCat の共用可否は #120 の推奨であり、v1.0 のテスト対象ではない）
- ホーム M の写真、ロック画面ウィジェット相当、カメラ撮影、ワンタップ返事、写真アルバム、花壇・おきゃくさん、サーバー側の通知種別設定、曜日指定、複数ペア、Sign in with Apple（いずれも v1.0.1 / v1.1 / v2+）
- Android 10 未満、タブレット・折りたたみ・Android Go・ChromeOS・Wear OS・Android TV・Android XR
- Google Play サービス（GMS）を持たない端末（Huawei の HMS 等）。FCM が使えないため、v1.0 の対応端末に含めない。残余リスクとして記録する
- Play Console の登録・審査申請・本番公開ボタン、契約・送金・銀行・税務・認証情報（人間または #124 の範囲）
- 外部ペネトレーションテスト。本計画は設定レビューと負の認可テストまでを含む

### 1.4 前提と未確定（null）

| 項目 | 現時点 | 扱い |
|---|---|---|
| Android 実機の保有・借用 | **null**（リポジトリに記録なし。PMO #119 でも未確認） | 確保できるまで実機ゲートは「未実施」。エミュレータ合格で代替しない |
| iPhone 実機（iOS 17+） | **null**（既存 E2E 端末の流用可否が未確認） | 混在ペア E2E の必須構成。確保できなければ AC3 は未実施 |
| 最終 `minSdk` | **null**（Compose / Glance / FCM のライブラリ制約と #121 の決定待ち） | 本計画は 29 を推奨。29 より上げる場合は qa-lead がマトリクスを更新 |
| FCM の検証用プロジェクト / 認証情報 | **null**（#138 / #124） | 実 FCM は検証用プロジェクトで行う。secret はリポジトリに置かない |
| 追加 token モデル（複数端末・provider） | **null**（#138 の設計待ち） | 複数端末の期待値を推測で固定しない。設計が決まった時点で X-18 を更新 |
| 正確なローカル通知時刻の許容幅 | **null**（#140 / #143 の実装仕様待ち） | 実測値を記録し、許容幅が決まるまで「合格」と断定しない |
| Android の公開日 | **null**（PMO #119 のアカウント種別・公開日判断待ち） | 本計画は日付を約束しない。PMO のゲートに追随 |
| 16 KB page size 対応 | **null**（native library の有無次第） | native が無ければ静的検査で足りる。ある場合は 16 KB イメージで確認 |
| Play の Data safety / アカウント削除の Web 導線 | **null**（#124 / #125 の範囲） | ストア申請前に #124 と突合する |

---

## 2. 品質目標と公開判定

### 2.1 重大欠陥の判定基準

| 深刻度 | 定義 | 例 |
|---|---|---|
| **S0: 公開ブロッカー** | 利用者のデータ・プライバシー・課金・アカウントに回復不能な害、またはコアループが起動不能 | ペア外のユーザーに snapshot / 写真 / 約束が見える。別ペア・別アカウントに通知が届く。JWT / FCM token / 写真の署名 URL が漏れる。起動クラッシュ・ANR でオンボーディング/ペア/チェックインが完了できない。チェックインの消失・重複確定。ウィジェットに別ペアの状態が出る。Play ポリシー違反（UGC 通報・アカウント削除・Data safety の不整合） |
| **S1: 重大** | 主要機能が使えない、または回避策が難しい。ゲート構成で再現する | ゲート構成の実機で相手の通知が届かない。ウィジェットが前面復帰後も更新されない。オフラインキューの操作が失われる。写真が相手に表示されない。ペア解消後も相手のデータが読める。アクセシビリティで主要操作が不能。60秒 p50 目標をゲート構成で大きく外す（OS 制約として説明できない場合） |
| **S2: 中** | 主要機能は使えるが、一部の条件で不便・表示崩れ・文言不整合 | 特定の OEM launcher でウィジェットの余白が崩れる。通知チャンネルの説明が不正確。ダークテーマで一部の文字が読みにくい。エラーメッセージが英語のまま |
| **S3: 軽微** | 見た目・文言・操作感の小さな問題 | 余白、アイコンの位置、言い回しの好み |

- 「テストが未実施」は欠陥ではない。**未実施のゲート項目がある状態を「合格」と扱わない**。
- 同じ症状でも、ゲート構成（3.2）の実機で再現するものは S1 以上、エミュレータだけで再現するものは原因を切り分けてから深刻度を決める。
- 既知の OS 制約（強制停止中の FCM 不達、Doze 中の通常優先度の遅延など）は、期待値として文書化されていれば欠陥にしない。ただし**利用者の主要操作を黙って失う**ものは S1 とする。

テストケースの優先度は、**P0 = 公開ゲート**、**P1 = v1.0 の必須機能（契約待ち・条件付きを含む）**、**P2 = 探索的・対象外に近い**、**P3 = 対象外** とする。P0 は 2.2 の G2 の対象、P1 は機能が v1.0 に含まれる場合に G2 の対象とする。

### 2.2 公開可（QA 推奨）のゲート

以下をすべて満たしたときだけ、qa-lead は orchestrator に「公開可（QA 推奨）」を提出する。1つでも未達なら「条件付き」または「保留」とし、理由と残余リスクを書く。

| # | ゲート | 証跡 |
|---|---|---|
| G1 | S0 / S1 が 0 件（オープン） | Issue / PR の欠陥一覧 |
| G2 | P0 ケース（および v1.0 に含まれる P1 ケース）が、それぞれ指定した実行層の必須構成で PASS（全ケースを全構成で回す意味ではない） | テスト実行記録（端末・OS・SHA・日時 JST） |
| G3 | RC の SHA で CI が緑（unit / lint / instrumentation API 36 / contract） | GitHub Actions の run URL |
| G4 | セキュリティ・プライバシー確認（5.6）が完了し、S0/S1 なし | チェックリストと負の認可テスト結果 |
| G5 | iOS v1.0 の回帰が緑で、iOS⇄Android 混在ペア E2E が PASS | lien-ios の run、X-01〜X-23 の P0/P1 の記録 |
| G6 | 実機でしか見られない範囲（7章）のうち、公開判定に必要な項目が実施済み | 実機記録・動画・logcat（秘匿情報を除去） |
| G7 | 未確定事項（1.4）が、公開判断に影響するものから解消または明示的なリスク受容になっている | orchestrator / オーナーの判断記録 |

- **QA は受入条件を独断で緩めない**。ゲートを外す判断は qa-lead 単独では行わず、orchestrator と product-lead の合意を記録する。
- 公開の最終操作は人間（Play Console の本番公開ボタン）。QA の「公開可」は判断材料であり、公開承認ではない。

### 2.3 欠陥の扱い

1. 再現手順・期待・実際・端末/OS・ビルド SHA・時刻（JST）・証跡を Issue に記録する。氏名・メール・端末の固有 ID・token は書かない。
2. S0/S1 は修正後、**影響範囲のケースとスモーク（オンボ・ペア・チェックイン・通知・ウィジェット）**を再実行する。
3. S2 以下は修正または「既知の制約」として Issue 化し、公開判定に影響しないことを qa-lead が確認する。
4. テストの失敗を「flaky」として再実行だけで閉じない。同じ SHA で1回だけインフラ再試行を許し、製品不具合なら欠陥として起票する。

---

## 3. 対象 OS と端末マトリクス

### 3.1 推奨 OS 範囲

| 項目 | 推奨 | 根拠・境界 |
|---|---|---|
| テスト対象 | **Android 10〜16（API 29〜36）** | Issue #123 の推奨範囲。API 29 は scoped storage と通知権限なしの旧挙動、API 36 は現行 target の最新挙動を含む |
| `minSdk` | **29（Android 10）** | これ未満は利用者シェア・検証コスト・ライブラリ制約の観点で v1.0 の範囲外とする推奨。最終値は #121 のライブラリ制約で確定する |
| `targetSdk` | **36（Android 16）** | Google Play は 2026-08-31 以降、新規アプリと更新に API 36 以上を要求する。Android 公開がそれ以降なら必須 |
| `compileSdk` | **36** | target 36 の動作確認と最新 API のコンパイルに揃える |
| ABI | 実機 **arm64-v8a** / エミュレータ **x86_64** | Google Play の配布は arm64 が主。CI は x86_64 |
| 画面 | スマートフォンのみ | v1.0 はタブレット・折りたたみを対象外。ウィジェットのサイズ適応はスマートフォンの launcher で確認する |
| ページサイズ | 4 KB / **16 KB** | Android 15+ の 16 KB ページサイズ端末に対応する。native library がある場合は必須確認 |

> `minSdk 29` は「29 未満を永久に切る」という製品決定ではない。Android の需要・端末分布・#121 の技術制約が変わったら、qa-lead がマトリクスと試験範囲を更新する。

### 3.2 最小マトリクス（公開ゲート）

「最小で効く組合せ」を、OS の挙動変化・OEM 差・実機依存・iOS 混在の4軸で選ぶ。

| ID | 種別 | 構成 | 必須 | 主な確認 | 確保状況 |
|---|---|---|---|---|---|
| **E29** | エミュレータ | Android 10 / API 29 / Google APIs / x86_64 | 必須 | 旧 OS、通知の実行時権限なし、背景制約、Glance の基礎、scoped storage | AVD 作成可 |
| **E36** | エミュレータ | Android 16 / API 36 / Google APIs / x86_64 | 必須 | target 36、edge-to-edge、予測型戻る、最新の通知/バックグラウンド制約、CI の instrumentation | AVD 作成可 |
| **P36** | 実機 | Pixel 8 以降など Android 16 に更新できる stock 端末 / arm64 | 必須 | 最新 OS、stock launcher、FCM、Doze、ウィジェット、性能 | **null** |
| **P-OEM** | 実機 | Samsung Galaxy A/S 級または Xiaomi/OPPO 級 / Android 13〜14 / arm64 | 必須 | OEM launcher、`POST_NOTIFICATIONS`、通知チャネル、電池最適化・自動起動の制限 | **null** |
| **I17** | 実機 | iPhone / iOS 17.0+ | 必須 | iOS⇄Android のペア、APNs と FCM の分離、相互の通知/ウィジェット | **null**（既存 E2E 端末の流用可否） |

- **P36 と P-OEM の2台で、stock と OEM の両方**を押さえる。1台しか用意できない場合は、P36 + I17 で混在ペアの最小確認はできるが、OEM の電池制御・通知権限・launcher 差は未検証になる。その状態で G2 を満たしたとは扱わない。
- **E29 は実機の代わりではない**。API 29 の実機がない場合、旧 OS の OEM 挙動は残余リスクとして記録する。
- **I17 は既存の iOS E2E 端末を流用する**。iOS 側のビルドは TestFlight または Xcode 直インストール（sandbox / production の違いは既存 E2E の手順に従う）。

### 3.3 OS 別の確認ポイント

| API | Android | 主な挙動・変更 | 最小構成での扱い |
|---|---|---|---|
| 29 | 10 | scoped storage、通知の実行時権限なし、背景実行の制限、ダークテーマ | **E29 で必須** |
| 30 | 11 | package visibility、一時許可、bubbles | 単独構成にしない。実装が package visibility を使う場合だけ追加 |
| 31 | 12 | `SCHEDULE_EXACT_ALARM` の導入、スプラッシュ画面、通知のタップ制限 | **E31 を RC で追加**（正確なローカル通知を使う場合） |
| 32 | 12L | 大画面・ウィジェットの角丸など | 単独構成にしない。E31/E33 で代替 |
| 33 | 13 | `POST_NOTIFICATIONS` の実行時許可、通知チャネル、per-app language | **P-OEM で必須** |
| 34 | 14 | 正確なアラームが新規インストールで既定拒否、Foreground Service の type 必須、runtime receiver の export 指定 | P36/E36 が上位互換で覆う。正確なアラームの分岐がある場合は **E34 を追加** |
| 35 | 15 | edge-to-edge の強制（target 35+）、16 KB ページサイズ、Foreground Service の時間制限 | P36 が覆う。native library がある場合は **E35-16K を追加** |
| 36 | 16 | target 36 の最新挙動、edge-to-edge、予測型戻る、最新の通知/バックグラウンド制約 | **E36 / P36 で必須** |

> API 30 / 32 / 35 を最小構成から外すのは、単独の挙動差が小さい、または 36 が上位互換で覆うため。実装がその API 固有の分岐を持つ場合、Play pre-launch report で指摘がある場合は追加する。

### 3.4 追加構成（RC 前後に必要に応じて）

| ID | 種別 | 構成 | 使う条件 | 主な確認 |
|---|---|---|---|---|
| E31 | エミュレータ | Android 12 / API 31 | 正確なローカル通知（リマインド・21時）を使う | `SCHEDULE_EXACT_ALARM` の許可/拒否、スプラッシュ、通知タップ |
| E33 | エミュレータ | Android 13 / API 33 | 通知権限の回帰を CI で回す | `POST_NOTIFICATIONS` の許可/拒否、チャネル |
| E34 | エミュレータ | Android 14 / API 34 | 正確なアラームの既定拒否を分岐で扱う | 既定拒否、設定画面からの許可、Foreground Service type |
| E35-16K | エミュレータ | Android 15/16 の 16 KB page size イメージ | native library を含む場合 | インストール、起動、native クラッシュ有無、`zipalign -c -P 16` |
| P29 | 実機 | Android 10/11 の OEM 端末 | 借用できる場合 | 旧 OS の電池制御、通知、launcher |
| P34 | 実機 | Android 14 の OEM 端末 | P-OEM が API 33 のときの補完 | 正確なアラーム既定拒否、FGS、通知 |
| P-2ndOEM | 実機 | P-OEM と別メーカー（例: Samsung と Xiaomi） | 2台目を借用できる場合 | OEM 差の比較（自動起動・電池最適化・launcher） |

- タブレット・折りたたみは v1.0 のゲートにしない。ウィジェットの resizable / 大画面対応は v1.1 以降の課題として記録する。
- Android Go は FCM・メモリ制約が異なるため、v1.0 のゲートにしない。

### 3.5 調達・初期化・データの扱い

- 実機は **専用のテスト端末** とし、個人の Google アカウント・写真・連絡先を入れない。工場出荷状態または専用テストプロファイルを使う。
- 端末の時刻は **Asia/Tokyo** に合わせる。タイムゾーン混在の試験（X-20）だけ意図的に変える。
- テスト用の Supabase / FCM 環境の有無は 1.4 のとおり **null**。専用環境ができるまでは、既存の E2E 用テストユーザー方式（`docs/E2E-M1.md`）を踏襲し、**本番の一般ユーザーのデータには触れない**。
- 実機の調達（購入・借用）は予算・総損失上限の範囲。**購入は人間の承認なしに行わない**。借用・既存端末の流用を優先する。

---

## 4. テストレベルと CI / 実機の仕分け

### 4.1 テストレベル

| レベル | 目的 | 主な道具 | 実行頻度 | ゲート |
|---|---|---|---|---|
| Unit（JVM） | 純粋ロジック・DTO・日付・キュー・通知 payload・エラーマップ | JUnit / kotlinx.serialization / Turbine 等 | 毎 PR | 必須 |
| Contract（JVM） | `products/lien/contracts/*.json` を Android の本番デコーダで読む。iOS と同じ意味になるか | JUnit + 共有フィクスチャ | 毎 PR（contracts 変更時は必須） | 必須 |
| Compose UI（instrumentation） | 画面遷移・入力・権限拒否・設定変更・プロセス死からの復帰 | Compose UI Test / Espresso / UiAutomator | 毎 UI PR / nightly | 必須（API 36） |
| Glance host（instrumentation / JVM） | ウィジェットの状態マッピング・サイズ・更新要求 | Glance testing / fake host | 毎ウィジェット PR | 必須 |
| Mock E2E | Android 単体で API / FCM / 時計をモックした通し | fake API / fake FCM / fake clock | 毎 PR | 必須 |
| Staging E2E | 実 Supabase・実 FCM・iOS 実機を含む通し | 実機 / 検証用プロジェクト | RC / 機能完了時 | 必須 |
| 物理手動 | 実 launcher・OEM 電池・通知 UI・性能・TalkBack | 実機 | RC | 必須 |
| Play pre-launch | Play Console の自動テスト（クラッシュ・ANR・アクセシビリティ等） | Play Console | RC | #124 と連携 |

### 4.2 CI で回す範囲

| 対象 | CI | 理由 |
|---|---|---|
| `assembleDebug` / `testDebugUnitTest` / `lintDebug` | 毎 PR | ビルド・JVM テスト・静的検査。Android の最小ゲート |
| 契約フィクスチャのデコード | 毎 PR（`products/lien/contracts/**` 変更時は必須） | iOS と同じ JSON を同じ意味で読む。サーバーとクライアントのズレを早期に検出 |
| Compose UI の instrumentation | API 36 で毎 UI PR / nightly | 画面遷移・入力・権限拒否・設定変更。エミュレータで再現できる範囲 |
| Glance の状態マッピング / 更新要求 | 毎ウィジェット PR | 実 launcher の描画は代替できないが、状態計算と update 要求は検証できる |
| API 29 / 33 の instrumentation | nightly / RC | 旧 OS・通知権限の回帰。PR ごとに全 API を回すとコストが大きい |
| 16 KB page size の静的検査 | RC（native library がある場合） | `zipalign -c -P 16`、16 KB イメージでの起動 |
| サーバー（Deno）・契約生成の回帰 | `lien-ci`（contracts / functions 変更時） | Android の FCM 追加が既存 APNs を壊していないか |
| iOS の回帰 | `lien-ios`（contracts 変更時） | 混在ペアの契約互換。iOS を遅らせない |

### 4.3 実機でしか見られない範囲（概要）

詳細は 7 章。CI の合格を実機合格と読み替えない。

- 実 FCM の配送（Google のインフラ・token・Doze）
- OEM の電池最適化・自動起動制限・バックグラウンド制限
- 実 launcher のウィジェット描画・更新・リサイズ・再起動
- Android 13+ の通知権限ダイアログ・チャネル設定 UI（OEM 差）
- `lien://` の実アプリ起動、App Links のドメイン検証（v1.1 準備）
- コールドスタート・電池消費・発熱
- ロック画面の通知表示（秘匿情報）
- 再起動後の通知・ウィジェット・token の復元
- Play pre-launch report（Play Console）
- iPhone との混在ペア

### 4.4 実行環境の原則

- **本番データを変更しない**。検証用の Supabase / FCM が用意できるまでは、既存の E2E 用テストユーザーだけを使う。
- **secret / token / 個人情報をログ・スクリーンショット・Issue・PR に出さない**。FCM のサービスアカウント鍵（旧 server key）、Supabase の service_role、APNs の鍵はリポジトリに置かない。
- テスト用の写真は合成画像（または許諾済みの素材）を使う。実在の人物の写真を使わない。
- 端末の画面録画・スクリーンショットは、テスト用ニックネームとダミーデータだけで撮る。

---

## 5. テスト観点

### 5.1 ウィジェット更新（Glance）

#### 5.1.1 更新経路の前提

Android v1.0 のウィジェットは、iOS の WidgetKit / NSE と同じ仕組みではない。第一候補は次の経路とする（詳細は #121 / #137 の設計に従う）。

1. **自分の操作**: ローカル楽観更新 → サーバー応答の snapshot で確定 → Glance 更新。
2. **相手の操作**: サーバーが FCM の **data-only 高優先度**メッセージに snapshot を同梱 → アプリの受信処理が snapshot を保存 → `GlanceAppWidget.updateAll()` を要求。
3. **フォアグラウンド復帰**: `GET /snapshot` で自己修復し、差分があれば更新。
4. **OS の定期更新**: `updatePeriodMillis`（最短30分）や WorkManager（周期最短15分）は**補助**であり、60秒の保証ではない。

#### 5.1.2 試験ケース

| ID | 条件 / 手順 | 期待結果 | 実行層 | 優先 |
|---|---|---|---|---|
| W-01 | 初回起動 → ソロまたはペア成立 → ホーム画面に S ウィジェットを追加 | 自分の状態・相手の状態・ストリーク・植物・細いバーが正しい。プレースホルダーや前回の別ペアの状態が出ない。タップでホームに遷移 | INST / 実機 | P0 |
| W-02 | 自分がチェックイン → ウィジェットを観察 | 自分の側が即時（楽観更新）に変わり、サーバー応答で確定する。相手側は変わらない。取消で戻る | 実機 | P0 |
| W-03 | 相手（iOS/Android）がチェックイン → 10回計測 | T0=相手の POST、T1=ウィジェットの表示切替。p50 ≤ 60秒、p90 も記録。端末・launcher・OS・電池設定を記録 | 実機 | P0 |
| W-04 | 相手が当日取消 → ウィジェットを観察 | 相手側が未完に戻る。自分の側は変わらない。次回前面復帰でも巻き戻らない | 実機 | P0 |
| W-05 | アプリを前景 / 背景 / 画面オフの順に切り替えてチェックイン | 二重更新・二重通知がない。前景では即時、背景では data push、画面オフでは Doze の結果を記録 | 実機 | P0 |
| W-06 | 最近のアプリ一覧からスワイプして終了 → 相手がチェックイン | ウィジェットは最後の snapshot のまま。クラッシュしない。次回アプリ起動/前面復帰で `GET /snapshot` により回復する | 実機 | P1 |
| W-07 | 設定 → アプリ → 強制停止 → 相手がチェックイン | 強制停止中は FCM が届かず、ウィジェットは更新されない（Android の仕様）。次回起動で回復する。**不達を欠陥にしない**が、期待値として記録 | 実機 | P1 |
| W-08 | 端末を再起動 → ロック解除 → アプリ起動 | ウィジェットが消えない。最後の snapshot を表示し、起動後に更新される。日付をまたいだ場合は前日の完了状態を残さない | 実機 | P1 |
| W-09 | `adb shell dumpsys deviceidle force-idle` で Doze → 相手が高優先度 / 通常優先度で送信 | 高優先度は wake して処理することを試みる。通常優先度は maintenance window まで遅延する。復帰後に二重更新しない。実測を記録 | E29/E36 + 実機 | P0 |
| W-10 | 機内モード → 自分のチェックイン → 復帰 | 最後の snapshot を表示し、クラッシュしない。復帰後にキューが送信され、ウィジェットが一致する | 実機 | P0 |
| W-11 | JST 23:59 → 00:00 → 00:10（close-day）→ 00:59 | 日付が変わると葉がたたまれる。`dateLocal` と表示が一致する。前日の完了状態が残らない。0:00〜1:00 の snapshot の日付ずれを正しく扱う | 実機 | P0 |
| W-12 | ウィジェットのサイズ変更、フォントスケール 1.0 / 1.3 / 2.0、ダークテーマ、日本語 | S の範囲で文字・植物・バーが欠けない。タップ領域が極端に小さくならない。別ペアの情報が混ざらない | 実機 | P1 |
| W-13 | 同じウィジェットを2つ配置 → launcher を再起動 → 両方を観察 | 両方が同じ状態に更新される。launcher 再起動後も再描画される。メモリリーク・クラッシュがない | 実機 | P1 |
| W-14 | サインアウト / アカウント削除 / ペア解消 → ウィジェットを観察 | 前のペアの情報が消える。未ログインまたはソロの表示になる。別アカウントの情報が見えない | 実機 / INST | P0 |

**計測方法（W-03）**

- 画面録画または高速度カメラで、相手の送信操作とウィジェットの表示切替を同じ時計に写す。`adb shell dumpsys appwidget` と logcat の timestamp も補助に使う。
- 10回の中央値（p50）と90パーセンタイル（p90）を出す。**端末・launcher・OS・バッテリー設定ごとに分け、全体の平均でごまかさない**。
- 60秒を超えた場合は、アプリの処理時間・FCM の配送時間・launcher の描画時間に分けて記録する。OS の制約なら「既知の制約」、アプリの処理なら欠陥とする。

### 5.2 FCM 受信・通知

#### 5.2.1 前提

- Android 13+ は `POST_NOTIFICATIONS` の実行時許可が必要。許可しない場合、**アプリ内の状態表示とチェックインは使える**が、通知は表示されない。
- Android 8.0+ は通知チャネルが必要。チャネルの重要度・音・バイブは利用者が変更できる。アプリが同じ ID で作り直しても、利用者の設定を上書きしない。
- FCM の **notification message** はバックグラウンドでシステム通知欄に表示され、通常 `onMessageReceived` を呼ばない。**data-only message** は受信コールバックに届くが、バックグラウンド実行時間・Doze・強制停止の制約を受ける。
- APNs の `users.push_token` / `push_env` を FCM token で上書きしない。provider 別の保存・無効化・複数端末の扱いは #138 の設計に従う。

#### 5.2.2 試験ケース

| ID | 条件 / 手順 | 期待結果 | 実行層 | 優先 |
|---|---|---|---|---|
| F-01 | オンボーディング → 通知許可 → 匿名 Auth 成立 | FCM token が取得され、サーバーの本人の登録に保存される。APNs の列・iOS の token を壊さない。未ログイン時に取得した token は Auth 後に送る | E2E | P0 |
| F-02 | Android 13+ で通知を拒否 → 相手がチェックイン | 通知は出ない。アプリ内の状態は更新される。チェックイン・ペア操作は使える。設定への導線があり、無限に再要求しない | 実機 | P0 |
| F-03 | F-02 の後、OS 設定で通知を許可 → 相手が再送 | 再インストールなしで通知が届く。token が変わっていれば再登録される | 実機 | P0 |
| F-04 | 通知チャネルの重要度・音・バイブを変更 → 通知 | 利用者の設定が尊重される。アプリが同じチャネルを再作成して設定を戻さない。チャネル名・説明が日本語で分かる | 実機 | P1 |
| F-05 | アプリ前景で相手がチェックイン | アプリ内表示と通知が二重にならない。通知をタップすると正しい画面に遷移する | 実機 | P0 |
| F-06 | アプリ背景で相手がチェックイン | notification message は通知欄に出る。data-only は受信処理が走り、ウィジェット更新を要求する。二重処理しない | 実機 | P0 |
| F-07 | タスク一覧からスワイプ / 強制停止 → 相手がチェックイン | スワイプ後は notification message が出る。data-only は走らないことがある。強制停止後はどちらも届かない。タップで起動し、snapshot を自己修復する | 実機 | P1 |
| F-08 | FCM token のローテーション（`onNewToken`）→ 送信 | 新しい token がサーバーに反映される。古い token への送信は失敗し、無効 token だけが掃除される。通知が重複・欠落しない | E2E | P0 |
| F-09 | アプリを再インストール → 新しい匿名ユーザーで開始 | 古い token が新しいユーザーに紐づかない。前のアカウントへ通知が行かない。再登録される | E2E | P0 |
| F-10 | サインアウト / アカウント削除 | token が登録から外れる。以後の通知が届かない。ローカルの snapshot・未送信キュー・通知が消える。他人のアカウントに通知が行かない | E2E | P0 |
| F-10b | ペア解消（アカウントは残る） | token は本人のアカウントに残る（再ペアに備える）。相手からの通知は止まり、ウィジェットから相手の情報が消える。解除後に再ペアできる | E2E | P0 |
| F-11 | 同じアカウントで2台の Android（または iOS と Android） | #138 で決めた契約どおりに登録・配送される。**未決定のまま「両方に届く」と仮定しない**。片方だけ・最新だけ等の結果を記録し、契約と照合する | E2E | P1（契約待ち） |
| F-12 | snapshot 同梱の data-only payload のサイズ・未知キー・欠損キー | FCM の上限（4 KB）以内。写真を含めない。未知キーは無視し、必須キーの欠損はクラッシュしない。壊れた payload は破棄してログに token を出さない | JVM / INST | P0 |
| F-13 | 同じメッセージの重複受信・順序逆転（古い `updatedAt` が後着） | 古い snapshot で新しい状態を上書きしない。重複通知・重複更新がない。ウィジェットが巻き戻らない | JVM / INST | P0 |
| F-14 | Doze 中に高優先度 / 通常優先度のメッセージ | 高優先度は wake して処理することを試みる。通常優先度は maintenance window まで遅延する。復帰後に二重処理しない。実測を記録 | 実機 | P0 |
| F-15 | 通知タップ（通常 / ペア解消 / 招待 / 写真） | 正しい画面・正しいペアに遷移する。未ログインならオンボーディング後に目的地へ。別アカウントの画面を開かない | 実機 | P0 |
| F-16 | ロック画面の通知表示（秘匿情報を隠す設定 / 表示する設定） | token・UUID・写真 URL が出ない。約束・ニックネームの表示は OS の秘匿設定に従う。ロック解除前に操作できない | 実機 | P1 |
| F-17 | 通知の名義・本文（相手のニックネーム、絵文字、日本語、定型文） | 相手のニックネーム名義で届く。自由文入力はない。文字化け・絵文字の欠落がない。本文に secret がない | 実機 | P1 |
| F-18 | GMS なし端末（Huawei 等） | v1.0 の対応外。FCM が使えないことを記録し、HMS 対応を v1.0 の合格条件にしない | 対象外 | P3 |

**FCM の試験用 doubles**

- CI / JVM では、FCM の送信を fake gateway に置き換え、payload の生成・受信・保存・重複排除を検証する。
- 実 FCM は検証用の Firebase プロジェクトで行う。**FCM のサービスアカウント鍵（旧 server key）は CI の secret に置く場合も、Android アプリには埋め込まない**。
- 本番の FCM プロジェクトへテスト送信しない。テスト用の宛先（テストユーザー）だけに送る。

### 5.3 省電力（Doze）・バックグラウンド

#### 5.3.1 前提

- Doze 中は、通常優先度の FCM は maintenance window まで遅延する。高優先度は wake して限られた処理を実行できるが、無限ではない。
- WorkManager は JobScheduler 経由で、Doze 中は実行が延期される。周期実行は最短15分で、正確な時刻保証はない。
- 正確なアラーム（`setExactAndAllowWhileIdle` 等）は Android 12+ で `SCHEDULE_EXACT_ALARM` が必要。Android 14 では新規インストール時に既定で拒否される。拒否時のフォールバック（inexact alarm / WorkManager / アプリ内表示）は #140 / #143 の設計に従う。
- OEM（Samsung / Xiaomi / OPPO 等）は独自の「スリープ」「自動起動」「バッテリー最適化」を持つ。Android 標準の API だけでは同じ挙動にならない。

#### 5.3.2 試験ケース

| ID | 条件 / 手順 | 期待結果 | 実行層 | 優先 |
|---|---|---|---|---|
| D-01 | 画面オフ・未充電・静止 → `force-idle` → 高優先度 data-only を送信 | 高優先度は wake して受信処理を試みる。実際の遅延・不達を記録し、アプリの処理か OS の制約かを切り分ける。成功時はウィジェット更新を要求する | E36 / 実機 | P0 |
| D-02 | 同じ条件で通常優先度を送信 | maintenance window まで遅延する。復帰後に処理され、二重更新しない。遅延を欠陥にしない | E36 / 実機 | P0 |
| D-03 | `adb shell am set-standby-bucket <pkg> rare` → 相手がチェックイン | FCM / WorkManager の挙動を記録。通知・ウィジェットが最終的に一致する。アプリ起動で自己修復する | E36 / 実機 | P1 |
| D-04 | OEM の電池最適化・自動起動制限を ON → 画面オフ → 相手がチェックイン | 通知・ウィジェットの遅延/不達を記録。クラッシュしない。設定を変えた場合の回復を確認。OEM 差を比較する | P-OEM / P34 | P0 |
| D-05 | 再起動 → ロック解除 → 通知・ウィジェット・token | 再起動後にローカル通知の予約が復元される。ウィジェットが再描画される。FCM token が維持される（再取得が必要なら再登録される）。日付をまたいだ状態が正しい | 実機 | P1 |
| D-06 | 端末の時刻・タイムゾーンを変更（JST → 他TZ → JST） | クラッシュ・データ破壊がない。リマインド・21時通知・`dateLocal` の変化を記録する。国内ペア前提の範囲を超える差異は v2+ の課題として分離する | 実機 | P1 |
| D-07 | `SCHEDULE_EXACT_ALARM` を許可 / 拒否（Android 12+、14+ の既定拒否を含む） | 許可時は正確な時刻、拒否時は設計されたフォールバックで動作する。SecurityException で落ちない。許容幅は #143 の仕様に照らす | E31 / E34 / 実機 | P0 |
| D-08 | 機内モード / 低バッテリー / Data Saver で WorkManager を実行 | 制約に従って延期・再試行される。重複実行・無限リトライがない。復帰後に状態が一致する | E36 / 実機 | P1 |
| D-09 | `adb shell am kill` でプロセス死亡 → 復帰 | 未送信キュー・snapshot・ウィジェットが復元される。二重送信しない。認証セッションが維持される（または再認証される） | E36 / 実機 | P0 |
| D-10 | バックグラウンドデータ制限 / 省データモード | FCM の受信可否を記録。アプリ内の操作は使える。復帰後に自己修復する | 実機 | P1 |

**エミュレータでの補助コマンド（例）**

```sh
adb shell dumpsys battery unplug
adb shell dumpsys deviceidle force-idle
adb shell dumpsys deviceidle unforce
adb shell am set-standby-bucket <package> rare
adb shell dumpsys deviceidle
adb shell dumpsys appwidget
adb shell pm grant <package> android.permission.POST_NOTIFICATIONS   # API 33+
adb shell pm revoke <package> android.permission.POST_NOTIFICATIONS  # API 33+
```

- `force-idle` は Doze の近似であり、OEM の独自制御や実際の maintenance window のタイミングまでは再現しない。**D-04 / D-05 は実機のみ**。
- 端末の画面ロック・暗号化・バッテリー残量などの条件を記録する。結果は「端末・OS・OEM・設定」ごとに分ける。

### 5.4 iOS⇄Android 相互運用

#### 5.4.1 前提

- 両 OS が**同じ Supabase project** の Auth / Edge Functions / DB / Storage / contracts を使う。
- 各端末は**別々の Supabase anonymous user** を持ち、招待受諾で `pair_members` が異なる Auth UUID を結ぶ。OS 間で匿名セッションを移行しない。
- APNs の `push_token` / `push_env` と FCM の token は**別の provider として扱う**。Android の登録が iOS の token を上書きしない。
- snapshot の `dateLocal` / `ticketBalance` / `plantNextStageAt` / `pairPlan` の null 契約を両 OS で同じに解釈する。
- 国内（JST）ペアを前提とする。時差ペアの厳密対応は v2+。

#### 5.4.2 試験ケース

| ID | 条件 / 手順 | 期待結果 | 実行層 | 優先 |
|---|---|---|---|---|
| X-01 | iOS が招待を発行 → Android がコード/QR/リンクで受諾 | 両端末でペア成立。相手のニックネーム・約束が見える。iOS の招待シートが閉じる。自動受諾しない | E2E | P0 |
| X-02 | Android が招待を発行 → iOS が受諾 | X-01 の逆。コードの大文字小文字・紛らわしい文字の除外が両 OS で同じ | E2E | P0 |
| X-03 | iOS の共有リンクを Android で開く / 逆 | `lien://invite/<token>` でアプリが起動し、コードがプリフィルされる。未インストール/不正リンクは手入力案内。App Links（https）は v1.1 準備として別記録 | E2E | P0 |
| X-04 | 同じ招待を iOS と Android が同時に受諾 | 片方だけ成立。敗者には既存のエラーコード。`pair_members` が二重にならない。再試行で冪等 | E2E | P0 |
| X-05 | 招待の72時間経過 / 使用済み / 取消後の受諾 | 期限切れ・使用済みのエラーが両 OS で同じ意味。勝手にペアが作られない | E2E / server test | P1 |
| X-06 | 約束の設定・編集（20字・絵文字）→ 相手のホーム/ウィジェット | 両 OS で相手の約束が同じに見える。編集後もストリークが継続する。文字数・絵文字の扱いが同じ | E2E | P0 |
| X-07 | iOS がチェックイン → Android の状態・通知・ウィジェット / 逆 | 相互に完了状態が見える。通知は相手の名前名義。ウィジェットは W-03 の目標に従う。二重チェックインしない | E2E | P0 |
| X-08 | iOS が当日取消 → Android / 逆 | 両 OS で未完に戻る。ウィジェットも戻る。翌日以降に遡及しない | E2E | P0 |
| X-09 | iOS が写真を添付 → Android で閲覧 / 逆 | 署名付き URL で表示される。端末に永続保存しない。ペア外・解消後は取得できない。写真の上限・形式が両 OS で同じ | E2E | P0 |
| X-10 | iOS がリアクション → Android / 逆 | スタンプが相手に表示され、通知はリアクションした人の名前名義。1人1つ・付け替えの扱いが同じ | E2E | P1 |
| X-11 | iOS がつつく → Android / 逆、1日4回目 | 通知が相手の名前名義で届く。3回まで。4回目は拒否。自由文がない | E2E | P0 |
| X-12 | 両者が同じ日にチェックイン → ストリーク・植物・節目 | 両 OS で「ふたり達成」、ストリーク +1、植物の段階・葉・ゲージが一致する。節目の演出が各段階1回だけ | E2E | P0 |
| X-13 | 片方だけ未完了 → close-day（00:10 JST）→ チケット消費 | 両 OS でチケット残数・カレンダー・通知が一致する。ストリークが継続する。チケットがない場合は責めない文言でリセット | E2E / server test | P0 |
| X-14 | JST 23:59 / 00:00 / 00:10 / 00:59 に、片方の端末の時計を±5分ずらしてチェックイン | `dateLocal` が各端末で同じ日として扱われる。二重チェックイン・二重ストリークがない。close-day 後に昨日へ遡及しない。0:00〜1:00 の snapshot の日付ずれを正しく扱う | E2E | P0 |
| X-15 | Android を機内モード → チェックイン/取消/写真 → 復帰。iOS はオンライン | 復帰後に1回だけ送信され、iOS 側に1件反映される。再送・重複でも結果が変わらない（冪等）。競合時はサーバーの状態が正 | E2E | P0 |
| X-16 | iOS からペア解消 → Android / 逆 | 両 OS でソロに戻る。相手の約束・チェックイン・写真が読めない。ウィジェットから相手の情報が消える。再試行が冪等 | E2E | P0 |
| X-17 | iOS からアカウント削除 → Android / 逆 | 相手側はソロになり、削除されたユーザーのデータ・token が残らない。通知が届かない。RLS で読めない | E2E | P0 |
| X-18 | Android が FCM を登録 → iOS の APNs 登録が残る / 逆 | provider 混在で既存の APNs / FCM 登録が壊れない。配送は #138 の契約（両方または最新のみ）に従い、**片方が恒久的に届かなくなる上書きは不可**。無効 token だけが掃除される | E2E | P0 |
| X-19 | contracts の snapshot / checkin / push / error フィクスチャを両 OS がデコード | `ticketBalance=null`（ソロ）、`plantNextStageAt=null`（最終段階・ソロ）、`dateLocal` 欠落時の保守的解釈が同じ。未知キーを無視する。バージョン差でクラッシュしない | JVM / E2E | P0 |
| X-20 | Android のタイムゾーンを UTC-8、iOS を JST にしてペア | クラッシュ・データ破壊がない。日付・通知・ストリークの差異を記録する。**時差ペアの厳密対応は v2+** とし、v1.0 の合格条件にしない | E2E | P2 |
| X-21 | 通知の名義・本文・タップ先を両 OS で比較 | 相手のニックネーム名義、日本語、絵文字、タップ先の画面が一致する。別ペア・別アカウントの画面を開かない | E2E | P1 |
| X-22 | アプリ未インストールで招待リンクを開く / 別 OS で開く | Web の招待ページまたは手入力案内にフォールバックする。勝手にペアを作らない。壊れたリンクでクラッシュしない | E2E | P1 |
| X-23 | 両者が同時にチェックイン / 片方が取消中に相手がチェックイン / 同時につつく | サーバーの状態が一貫する。二重チェックイン・二重ストリーク・二重通知がない。敗者には既存のエラーコード。再試行で冪等 | E2E | P0 |

**相互運用の証跡**

- 両端末の画面録画（テスト用データのみ）、サーバーの snapshot（token・UUID を除去）、通知のスクリーンショット。
- 時刻は Asia/Tokyo。端末の時計をずらした試験は、その旨と実際の時刻を記録する。
- ペア解消・削除の後は、`snapshot` / `checkins` / `photos` の負の認可結果を記録する（値そのものは出さない）。

### 5.5 Android 単体の回帰

| ID | 範囲 | 主な確認 | 参照 |
|---|---|---|---|
| C-01 | オンボーディング / 匿名 Auth / セッション復元 | 3画面、ニックネーム8字、絵文字、通知プレ許可、再起動後のセッション、401/503 の扱い | §3.1 |
| C-02 | 約束 | 1人1つ、20字、絵文字、リマインド時刻、編集後もストリーク継続 | §3.3 |
| C-03 | ソロ利用 | ペア未成立でも約束・チェックインができる。写真はペア成立後のみ | §3.2 / §3.4 |
| C-04 | 招待 | 8文字、QR、`lien://`、72時間、1回限り、同時受諾、自動受諾しない | §3.2 |
| C-05 | チェックイン | 1日1回、当日取消、写真、オフラインキュー、冪等、プロセス死からの復帰 | §3.4 |
| C-06 | ストリーク / チケット / カレンダー | close-day、自動消費、0枚時のリセット、責めない文言、月次付与 | §3.5 / §3.6 / §3.11 |
| C-07 | つつく / リアクション | 1日3回、相手名義、定型文、1人1つ、付け替え | §3.7 / §3.8 |
| C-08 | 植物 | 10段階、閾値、葉の開閉、表情、名前、段階アップ1回、取消で戻る | §3.9 |
| C-09 | 設定 / 削除 / 解消 / サインアウト | プロフィール、通知設定、リマインド、2段階確認、削除、匿名注意 | §3.15 |
| C-10 | シェア画像 | 2種、写真を含めない、名前・ストリーク・開始日、共有シート | §3.13 |
| C-11 | 表示・アクセシビリティ | ダークテーマ、フォントスケール、TalkBack、タップ領域、コントラスト、日本語のみ | §4 |
| C-12 | 性能 | コールドスタート→チェックイン完了、ウィジェット反映、電池・発熱 | §4（Android の目標は #120 の扱いに従う） |

### 5.6 セキュリティ・プライバシー

| ID | 確認 | 合格条件 | 実行層 |
|---|---|---|---|
| S-01 | RLS の負の認可 | ペア外・未ログイン・解消後のユーザーが、相手の snapshot / checkin / photo / promise を読めない。書き込みも拒否される | server test / E2E |
| S-02 | セッション保存 | JWT / refresh token は Keystore 保護（または同等）に保存され、平文でファイル・ログに出ない。バックアップに含めない | JVM / 実機 |
| S-03 | コンポーネントの公開範囲 | `android:exported` が必要なものだけ。receivers / services / activities に不要な外部起動口がない。intent の入力を検証する | 静的検査 |
| S-04 | ディープリンク | 不正 token・他人の token・期限切れで自動受諾しない。オープンリダイレクトがない。`lien://` の外部入力でクラッシュしない | INST / 実機 |
| S-05 | PendingIntent / 通知 | `FLAG_IMMUTABLE` 等で他人が改ざんできない。通知タップで別アカウントの画面を開かない | 静的検査 / 実機 |
| S-06 | ログ・クラッシュレポート | token / JWT / 写真の署名 URL / UUID / ニックネーム等の個人情報を出さない。デバッグログは release で無効 | JVM / 実機 |
| S-07 | 権限 | 位置情報・連絡先・ATT 相当・分析 SDK がない。写真は Photo Picker 等で必要最小限。`READ_MEDIA_IMAGES` を不要に要求しない | 静的検査 |
| S-08 | 写真の署名 URL | 有効期限が短い。端末に永続保存しない。解消後は新規発行できない。古い URL の残余（DESIGN の 3600 秒）を理解して記録する | E2E |
| S-09 | 通信 | HTTPS のみ。cleartext を許可しない。証明書エラーで黙って続行しない | 静的検査 / 実機 |
| S-10 | Play の Data safety / アカウント削除 | 実際に収集するデータ（Auth ID、ニックネーム、写真、FCM token 等）と Data safety の申告が一致する。アプリ内削除と Web の削除導線（必要なら）がある | #124 / #125 と突合 |
| S-11 | UGC の通報・ブロック | 写真・ニックネーム・約束から通報でき、ブロック=ペア解消が機能する。運営の連絡先が有効 | 実機 / ストア申請前 |
| S-12 | 依存・secret | リポジトリに secret / keystore / `.env` がない。FCM のサービスアカウント鍵（旧 server key）をアプリに埋め込まない。署名鍵は #124 の管理に従う | 静的検査 |

> 本計画は外部ペネトレーションテストの代替ではない。S-01〜S-12 は v1.0 の設定・実装レビューと負の認可テストの範囲を定める。

---

## 6. CI 計画

### 6.1 ジョブ構成（`lien-android.yml` の新設を推奨）

| ジョブ | ランナー | トリガー | 主なコマンド | 必須 |
|---|---|---|---|---|
| `android-unit` | ubuntu-latest / JDK 17 | `products/lien/android/**`、`products/lien/contracts/**`、workflow の変更 | `./gradlew --no-daemon clean assembleDebug testDebugUnitTest lintDebug` | 毎 PR |
| `android-contract` | 同上（`android-unit` に含めてもよい） | contracts 変更時は必須 | `./gradlew --no-daemon testDebugUnitTest --tests '*Contract*'` | 毎 PR |
| `android-instrumentation-api36` | ubuntu-latest + KVM + emulator | UI 変更を含む PR / nightly / RC | `./gradlew --no-daemon connectedDebugAndroidTest` | UI PR / RC |
| `android-instrumentation-api29` | 同上 | nightly / RC | 同上（API 29 AVD） | RC |
| `android-instrumentation-api33` | 同上 | nightly / RC | 同上（API 33 AVD） | 任意 |
| `android-16k` | 同上 | RC（native library がある場合） | `zipalign -c -P 16`、16 KB イメージで install / 起動 | RC |
| `lien-ci` | 既存 | contracts / functions 変更 | `deno test`、契約 `--check` | 必須 |
| `lien-ios` | 既存 | contracts 変更 | 既存の iOS CI | 必須 |

- Android の CI は **macOS ランナーを使わない**（iOS の予算を奪わない）。ubuntu の KVM でエミュレータを動かす。
- action は commit SHA で固定する（リポジトリの既存方針）。`reactivecircus/android-emulator-runner` 等を使う場合も SHA 固定。
- docs のみの変更では Android の重いジョブを起動しない（path filter）。ただし contracts を変えた場合は契約テストを必ず回す。

### 6.2 ローカル / CI のコマンド

```sh
cd products/lien/android

# 毎 PR
./gradlew --no-daemon clean assembleDebug testDebugUnitTest lintDebug

# instrumentation（API 36 のエミュレータを起動済みの状態）
./gradlew --no-daemon connectedDebugAndroidTest

# 失敗時のレポート
# build/reports/tests/
# build/reports/lint-results-debug.html
# build/outputs/androidTest-results/
```

- `products/lien/android` は本計画の作成時点で未存在（#121 が雛形を作成中）。上記コマンドは #121 の雛形に合わせて確定する。
- unit test には、日付（`Clock` 注入）、通知 payload、ディープリンク、オフラインキュー、token 状態、snapshot の null 契約を含める。
- instrumentation には、オンボーディング、約束、招待、チェックイン、設定、権限拒否、プロセス死、設定変更（ダークテーマ・フォントスケール）を含める。

### 6.3 エミュレータ設定

| 項目 | 値 |
|---|---|
| イメージ | `google_apis`（Play Store なし） / x86_64 |
| API | 29 / 33 / 36（必須は 29 / 36） |
| 画面 | 1080x2400 / 420dpi 相当 |
| 言語 | 日本語（`ja-JP`） |
| タイムゾーン | `Asia/Tokyo` |
| アニメーション | 無効（window / transition / animator scale = 0） |
| 起動 | `-no-window -no-audio -no-boot-anim`、KVM 有効 |
| タイムアウト | 30分（初回起動を含む） |

- エミュレータのスナップショットを使う場合も、テスト前に cold boot して状態を固定する。
- API 29 の `google_apis` イメージで `POST_NOTIFICATIONS` が存在しないことを確認する（存在したら設定ミス）。
- 16 KB イメージは API 35/36 の提供状況を SDK Manager で確認して使う。

### 6.4 失敗時の扱い

- **同じ SHA で1回だけ**インフラ起因の再試行を許す（エミュレータ起動失敗、ネットワーク断）。製品不具合は再試行で隠さない。
- P0 のテストを `@Ignore` / quarantine する場合は、Issue 番号と qa-lead の承認を必須にする。P0 が quarantine されたままの RC は公開ゲートを通さない。
- flaky 率が高いテストは、原因を修正するか、テストを分割する。リトライ回数を増やして緑に見せない。
- 失敗時は、JUnit XML、lint レポート、スクリーンショット、logcat、`adb bugreport` を artifact に残す。token / PII は除去する。

---

## 7. 実機でしか見られない範囲

| # | 項目 | CI で代替できない理由 | 構成 | 証跡 |
|---|---|---|---|---|
| 1 | 実 FCM の配送 | Google のインフラ・token・Doze・OEM の制約。fake gateway では配送時間・不達を再現できない | P36 / P-OEM | 送信時刻と受信時刻、通知の画面録画 |
| 2 | OEM の電池最適化・自動起動 | Samsung / Xiaomi / OPPO の独自設定。`force-idle` は近似にすぎない | P-OEM / P34 | 設定画面、受信/不達の記録 |
| 3 | 実 launcher のウィジェット | Glance の host test は launcher の描画・更新・リサイズを再現しない | P36 / P-OEM | 画面録画、`dumpsys appwidget` |
| 4 | 通知権限ダイアログ / チャネル UI | OEM の設定 UI・権限の文言が異なる | P-OEM | 画面録画 |
| 5 | `lien://` の実起動 / App Links | 実アプリの intent 解決・ドメイン検証（assetlinks）が必要 | P36 | `adb shell am start` の結果、画面 |
| 6 | コールドスタート・電池・発熱 | エミュレータの性能は実機と異なる | P36 | 10回計測、p50/p90、電池統計 |
| 7 | ロック画面の通知 | OS の秘匿設定・ロック画面 UI が絡む | P-OEM / P36 | 画面写真（テストデータのみ） |
| 8 | 再起動後の復元 | 実機の再起動・暗号化・launcher の復元が必要 | P36 | 再起動前後の画面、logcat |
| 9 | 16 KB page size | エミュレータイメージで代替できるが、実機の配布形態・native の有無を確認する | E35-16K / 実機 | `zipalign`、起動ログ |
| 10 | Play pre-launch report | Play Console の自動テスト。クラッシュ・ANR・アクセシビリティ・プライバシー | Play Console | #124 のレポート |
| 11 | iOS⇄Android 混在ペア | 実 iOS 端末と APNs が必要 | I17 + P36 | 両端末の画面録画、通知 |

- 実機の台数が足りない場合、優先順位は **P36（最新 OS・stock）→ P-OEM（OEM・通知権限）→ P29（旧 OS）**。I17 は AC3 に必須。
- 実機でしか見られない項目をエミュレータの結果で「合格」と書かない。未実施は **null** と理由を記録する。

---

## 8. 実施計画・体制・証跡

### 8.1 スケジュール（PMO #119 の A 案に沿う目安）

| 時期 | QA の作業 | ゲート |
|---|---|---|
| 2026-10-21 | 本計画の提出（#123） | 計画レビュー |
| 〜2026-11-13 | テスト設計・フィクスチャ・CI 雛形の準備（#121 と並行） | テスト計画・マトリクス確定（PMO D3） |
| 2026-11-14〜12-06 | T-AND 実装に追随。unit / contract / UI テストを追加 | 各 PR の CI |
| 2026-12-07 | RC ビルド | ビルド・CI 緑 |
| 2026-12-08〜12-14 | 内部テスト、回帰、実機ゲート、欠陥修正 | 内部テスト合格（D5） |
| 2026-12-15〜12-28 | クローズドテスト（個人アカウントの場合）の監視・フィードバック | 12人×14日（D6、A 案のみ） |
| 2026-12-29 | 本番アクセス申請の材料 | 人間の申請（D7） |
| 2027-01-06 以降 | 公開後の監視（クラッシュ・ANR・レビュー） | 公開は人間 |

- 上記は **A 案（個人アカウント + テスター募集）** の目安。B 案（組織アカウント / D-U-N-S）はアカウント有効化後に再設定する。日付は保証ではなく、PMO のゲート結果で更新する。
- iOS v1.0（10/31）と v1.1（11/12〜13）を遅らせない。Android のコードを `main` に入れるのは 11/14 以降（PMO P1）。

### 8.2 体制

| 役割 | 担当 |
|---|---|
| テスト計画・合否判定・重大欠陥の判定・公開可否の提言 | qa-lead |
| テストコード・CI・フィクスチャの実装 | eng-exec（#121 が起票する T-AND） |
| Android の設計・ビルド・CI の土台 | eng-lead |
| Play のトラック・署名・pre-launch report | ops-lead（#124） |
| 製品範囲・受入の最終確認 | product-lead |
| UI / アクセシビリティ | ux-lead |
| 公開可否の承認・リスク受容 | orchestrator / オーナー |
| クローズドテストの実利用者（A 案） | 人間（12人以上、14日連続。金銭・商品・割引を渡さない） |

### 8.3 証跡の形式

- テスト実行記録は、次の列を持つ表で Issue / PR に残す。

| ID | ビルド SHA | 端末 / OS | 日時（JST） | 結果 | 証跡 | 欠陥 |
|---|---|---|---|---|---|---|
| W-03 | `<sha>` | Pixel 8 / Android 16 | 2026-12-08 14:00 | PASS（p50 42s / p90 71s） | 動画 URL / logcat | - |

- 実機の識別子は「Pixel 8 / Android 16」のように機種・OS で書き、シリアル番号・広告 ID・アカウントは書かない。
- 失敗時は、再現手順・期待・実際・ログ（秘匿情報を除去）・スクリーンショットを添える。
- テストデータは合成。実在の人物の写真・ニックネーム・連絡先を使わない。

---

## 9. リスクと未確定

| # | リスク | 影響 | 対策 | 状態 |
|---|---|---|---|---|
| R1 | Android 実機（P36 / P-OEM）を確保できない | 実機ゲートが未実施。FCM / Doze / launcher / 通知権限を確認できない | 既存端末の流用・借用を優先。購入は人間承認。確保できなければ「公開可」を出さない | **null** |
| R2 | iPhone（I17）を確保できない | AC3 の混在ペア E2E ができない | 既存の iOS E2E 端末を流用。不可なら AC3 未実施として報告 | **null** |
| R3 | minSdk 29 がライブラリ制約で難しい | 旧 OS の試験範囲が変わる | #121 の確定後にマトリクスを更新。29 より上げる場合は理由と影響を記録 | **null** |
| R4 | FCM の検証用プロジェクト / 認証情報がない | 実 FCM の配送・token ローテーションを試せない | #138 / #124 と調整。secret はリポジトリに置かない。fake gateway で部分検証 | **null** |
| R5 | 複数端末 / provider の token モデルが未決定 | F-11 / X-18 の期待値が決まらない | #138 の設計を待ち、決まった時点でケースを更新。推測で合格にしない | **null** |
| R6 | 正確なローカル通知の許容幅が未決定 | D-07 / 21時通知の合否が決まらない | #140 / #143 の仕様を確認。実測値を記録し、未決定なら「未判定」 | **null** |
| R7 | ウィジェット 60秒 p50 が OS 制約で達成できない | iOS と同等の体験を約束できない | 実機・launcher 別に計測。data push の経路を優先し、OS 制約なら product-lead と期待値を合意 | 未検証 |
| R8 | OEM のバックグラウンド制限で FCM が不達 | 相手のチェックイン通知・ウィジェットが遅れる | P-OEM で実測。必要なら設定案内やフォアグラウンド自己修復を設計（製品判断） | 未検証 |
| R9 | Android の公開日がアカウント種別（A/B）で変わる | テストの絶対日付が変わる | PMO #119 のゲートに追随。日付を外部に約束しない | **null** |
| R10 | 16 KB page size の native library がある | Play の要件に抵触する | native の有無を #121 で確認。E35-16K と `zipalign -c -P 16` を RC で実施 | **null** |
| R11 | Play の Data safety / アカウント削除の Web 導線が未整備 | ストア申請でリジェクト | #124 / #125 と突合。S-10 を申請前に完了 | **null** |
| R12 | テストが本番データに触れる | プライバシー・信用の毀損 | 検証用環境または E2E 用テストユーザーだけを使う。本番の一般ユーザーを触らない | 運用で防止 |

---

## 10. 受入条件との対応

| Issue #123 の受入条件 | この文書の該当 | 計画としての状態 |
|---|---|---|
| 対象 OS（Android 10〜16 の範囲を推奨案で）と実機/エミュレータの端末マトリクス（最小で効く組合せ） | 3.1（推奨 OS）、3.2（最小マトリクス）、3.3（OS 別）、3.4（追加構成） | **記載済み**。実機の確保状況は 1.4 / R1 のとおり **null** |
| ウィジェット更新・FCM 受信・省電力（Doze）下の挙動のテスト観点 | 5.1（W-01〜W-14）、5.2（F-01〜F-18）、5.3（D-01〜D-10） | **記載済み**。実行結果ではない |
| iOS⇄Android ペアの相互運用テスト項目 | 5.4（X-01〜X-23） | **記載済み**。I17 / P36 の確保が前提 |
| CI で回す範囲（Gradle unit/instrumentation on emulator）と、実機でしか見られない範囲の仕分け | 4章、6章、7章 | **記載済み**。`products/lien/android` の雛形は #121 待ち |

> 本 Issue の成果物は「テスト計画と端末マトリクス」であり、テストの実行結果ではない。RC 時の実行結果は 8.3 の形式で別途記録し、G1〜G7 の判定に使う。

---

## 11. 参照

### リポジトリ内

- [docs/REQUIREMENTS.md](../REQUIREMENTS.md) — 製品要件の正本
- [docs/DESIGN.md](../DESIGN.md) — iOS の現行実装・通知/ウィジェットの設計
- [docs/E2E-M1.md](../E2E-M1.md) — iOS 実機 E2E の手順・計測方法
- [products/lien/contracts/README.md](../../products/lien/contracts/README.md) — iOS / サーバーの契約フィクスチャ
- PR #132 `docs/android/REQUIREMENTS-ANDROID.md`（未マージ） — Android v1.0 の要件差分
- PR #131 `docs/android/PLAN-ANDROID.md`（未マージ） — Android の全体計画・日程
- Issue #120（Android 要件）、#121（技術設計）、#122（UX）、#124（Play Ops）、#137（Glance）、#138（FCM DB/API）、#139（FCM 送信）、#140（FCM 受信）、#143（設定・ローカル通知）、#144（統合検証）

### 公式資料（参照日 2026-10-21）

- Google Play: [Target API level requirements](https://developer.android.com/google/play/requirements/target-sdk) — 2026-08-31 以降、新規アプリ・更新は API 36 以上
- Google Play Console Help: [Target API level requirements for Google Play apps](https://support.google.com/googleplay/android-developer/answer/11926878)
- Android Developers: [Android 16 behavior changes](https://developer.android.com/about/versions/16/behavior-changes-16)
- Android Developers: [Notification runtime permission](https://developer.android.com/develop/ui/views/notifications/notification-permission) — Android 13+ の `POST_NOTIFICATIONS`
- Android Developers: [Create and manage notification channels](https://developer.android.com/develop/ui/views/notifications/channels)
- Firebase: [Receive messages in an Android app](https://firebase.google.com/docs/cloud-messaging/android/receive-messages)
- Firebase: [Set and manage Android message priority](https://firebase.google.com/docs/cloud-messaging/android/message-priority) — Doze 中の通常/高優先度
- Android Developers: [Optimize for Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)
- Android Developers: [Schedule exact alarms are denied by default](https://developer.android.com/about/versions/14/changes/schedule-exact-alarms) — Android 14 の既定拒否
- Android Developers: [Jetpack Glance](https://developer.android.com/develop/ui/compose/glance)
- Android Developers: [Glance app widget update](https://developer.android.com/develop/ui/compose/glance/glance-app-widget) — `updatePeriodMillis` の上限
- Android Developers: [Support 16 KB page sizes](https://developer.android.com/guide/practices/page-sizes)
- Android Developers Blog: [Prepare your apps for Google Play's 16 KB page size compatibility requirement](https://android-developers.googleblog.com/2025/05/prepare-play-apps-for-devices-with-16kb-page-size.html) — 2025-11-01 以降、Android 15+ を target する新規アプリ・更新
- Google Play Console Help: [App testing requirements for new personal developer accounts](https://support.google.com/googleplay/android-developer/answer/14151465) — 12人×14日（A 案の前提）
- Android Developers: [Verify Android App Links](https://developer.android.com/training/app-links/verify-android-applinks) — v1.1 準備
- Google Play Console Help: [Provide information for Google Play's Data safety section](https://support.google.com/googleplay/android-developer/answer/10787469)

---

## 12. 変更履歴

| 日付 | 変更 | 担当 |
|---|---|---|
| 2026-10-21 | 初版。OS 範囲、最小マトリクス、ウィジェット/FCM/Doze、iOS⇄Android、CI/実機の仕分け、公開ゲートを記載 | qa-lead |
