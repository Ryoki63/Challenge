# lien-release 本番実行シート — 内部 TestFlight まで

Issue #106 / 確認日: 2026-10-20 JST / 実行担当: **Ryoki（オーナー）**。Apple Developer Program 有効化（G0）後、内部配布まで1時間を目指す。**Appleのビルド処理・招待メール、CI待ち時間は保証できない**。事前に手順1のdry-run・内部テスター候補の確認を済ませ、超過時は待機箇所と経過時間を記録する。これは手順書であり、本番実行・署名成功の証跡ではない。

## 0. 事前準備と Secrets 6件（実値は記録しない）

**取得・登録は全件Ryokiが管理画面から直接行う。エージェントへ値や鍵ファイルを渡さない。** 設定先は全件、GitHub **`Ryoki63/Challenge` → Settings → Secrets and variables → Actions → Repository secrets**（Environment secrets / Variablesではない）。6件とも同じLien用Appleチーム／Supabaseプロジェクトから取得する。

| Secret名 | 取得元・取得するもの | 誰が取る／登録するか | 設定先・用途 |
|---|---|---|---|
| `ASC_KEY_P8` | App Store Connect → Users and Access → Integrations → App Store Connect API → **Team Keys**で発行した`.p8`全文（PEMまたはbase64）。ダウンロードは1回のみ | Ryoki（Account Holder / Admin） | 上記Repository secret。同名。署名・アップロード |
| `ASC_KEY_ID` | 同じTeam KeyのKey ID（APNs用Key IDではない） | Ryoki（Account Holder / Admin） | 同上。同名。ASC認証 |
| `ASC_ISSUER_ID` | 同じチームのApp Store Connect API画面のIssuer ID（個人キーは使わない） | Ryoki（Account Holder / Admin） | 同上。同名。ASC認証 |
| `APPLE_TEAM_ID` | Apple Developer → Membership detailsのTeam ID（大文字英数字10桁） | Ryoki（Appleチーム管理者） | 同上。同名。署名チーム |
| `SUPABASE_URL` | **Lien対象プロジェクト**のConnectダイアログ → Project URL | Ryoki（当該Supabaseプロジェクト管理者） | 同上。同名。アプリ接続先 |
| `SUPABASE_ANON_KEY` | 同じプロジェクト → Settings → API Keysのpublishableキー、またはlegacy anonキー | Ryoki（当該Supabaseプロジェクト管理者） | 同上。同名。**service_role / `sb_secret_…`禁止** |

- Apple: G0完了・対象チーム一致 → Developer PortalでExplicit App ID **`com.ryoki63.lien`**登録 → App Store ConnectでそのBundle IDのiOSアプリ作成 → Account HolderがAPIアクセスを申請・承認確認 → **Team Key**発行（既存READMEはAdmin推奨。権限付与はオーナー判断。Adminという名前だけでクラウド署名成功を保証しない）。契約同意・権限不足ならオーナー対応で止める。[A][B]
- 署名: 本体 / **`com.ryoki63.lien.widget`** / **`com.ryoki63.lien.nse`**、App Group **`group.com.ryoki63.lien.shared`**を同一チームに揃える。`-allowProvisioningUpdates`による自動登録を試す構成。失敗時はDeveloper Portalで3 App IDへのApp Group割当と本体のPush Notificationsを確認する。証明書・profileをこの手順で新規にリポジトリへ追加しない。[B]
- 内部配布: テスターは当該アプリにアクセスできる**App Store Connectユーザー**。候補と既存招待の受諾状況を事前確認。新規ユーザー招待・権限追加・配布はオーナーが承認して操作する。外部テスターの招待やApp Review提出は対象外。[C]

## 1. dry_run → 同じコミットの本番（順番を飛ばさない）

実行前にオーナーが**署名・Appleへのアップロード・内部配布の承認範囲**を確認する。本シートの作成は実行承認の代わりではない。以下はリポジトリルートから、承認済みmainの同一SHAを対象に**1ブロックずつ**実行する（ブランチ更新時は最初から）。

```sh
RELEASE_REF=main
TARGET_SHA=$(gh api "repos/Ryoki63/Challenge/commits/$RELEASE_REF" --jq .sha)
gh workflow run lien-release.yml --repo Ryoki63/Challenge --ref "$RELEASE_REF" -f dry_run=true -f internal_only=true
gh run list --repo Ryoki63/Challenge --workflow lien-release.yml --branch "$RELEASE_REF" --event workflow_dispatch --limit 5
```

**dry-runのRun IDとheadShaが`TARGET_SHA`に一致することを確認**し、`gh run watch <DRY_RUN_ID> --repo Ryoki63/Challenge --exit-status`で待つ。Summaryの無署名archive・版/Bundle ID・SDK・Privacy・接続情報の検査を確認。Secretsなしでも成功しうるため、未設定の警告は実接続・署名の検証済みを意味しない。

**本番前の停止条件:** 同じSHAの`lien-ios.yml`と`lien-ci.yml`が両方successでない、dry-run失敗、Secrets未登録、署名・接続情報の警告未解決。CI未実行なら承認済みrefで該当workflowを手動実行し、完了を待つ（`gh workflow run lien-ios.yml --repo Ryoki63/Challenge --ref "$RELEASE_REF"`。`lien-ci.yml`も同様）。この確認は本番の自動gateでも必須で、`internal_only`では回避されない。

```sh
python3 products/lien/ios/scripts/ci_status.py --repo Ryoki63/Challenge --sha "$TARGET_SHA" --workflow lien-ios.yml --workflow lien-ci.yml --require
# 上の終了コード0とdry-run成功を確認してから、次のブロックへ
```

```sh
if [ "$(gh api "repos/Ryoki63/Challenge/commits/$RELEASE_REF" --jq .sha)" = "$TARGET_SHA" ]; then
  gh workflow run lien-release.yml --repo Ryoki63/Challenge --ref "$RELEASE_REF" -f dry_run=false -f internal_only=true
else
  printf '%s\n' 'STOP: refが更新されたためdry-runからやり直す'
fi
```

本番Run IDを同様に取得し、`gh run view <RELEASE_RUN_ID> --repo Ryoki63/Challenge --json headSha`で一致確認 → `gh run watch <RELEASE_RUN_ID> --repo Ryoki63/Challenge --exit-status`。**事前比較とdispatchの間にmainが動く可能性は残る。不一致・取得不能なら直ちに`gh run cancel <RELEASE_RUN_ID> --repo Ryoki63/Challenge`を試み、手順1へ戻る。取消不能／送信結果不明ならASC到達を確認し、そのビルドは配布しない。事後のSHA照合はアップロードを確実に防ぐ自動gateではない。** 正しいSHAのrunでは**Preflight → signed archive → Verify → Export and upload → Cleanup**を確認。書き出しは`app-store-connect / upload / automatic`。本体・Widget・NSEの版は`Config/Base.xcconfig`、ビルド番号は**その本番runの`run_number`**（Run IDとは別）。`codesign --verify`の問題はwarning扱いのため、job緑だけで署名確認を済ませない。

**`internal_only=true`は連絡先・規約/プライバシーページ検査を警告にするだけ。Apple側の「TestFlight Internal Only」指定や自動配布制限ではない。** 外部グループの自動配布を含む設定を事前確認し、このビルドは内部だけに割り当てる。外部テスト・審査へは転用せず、G4と公開ページ整備後に`internal_only=false`の新runで作り直す。

## 2. 失敗時の切り戻し・再実行

| 失敗箇所・症状 | 止めて確認すること／再開方法 |
|---|---|
| Preflight / 無署名archive / CI gate | Appleへのアップロード前。前回の正常配布を維持。足りない**名前だけ**を確認しオーナーが設定、または対象SHAのCIを直す。ソース修正はPRレビュー後に採用し、手順1から |
| Bundle ID不一致 / profileにApp Groupなし | `Config/Base.xcconfig`の`LIEN_BUNDLE_ID_BASE`、3 App ID・ASCレコード・Team ID・App Groupを照合。ソースのIDを場当たり的に変更しない。オーナーがPortalの割当を修正し再実行 |
| 署名: authentication / permission / signing certificate / provisioning失敗 | 同じTeam KeyのP8・Key ID・Issuer IDとチーム、失効・クラウド署名権限をオーナーが管理画面で照合。**ASCキーとAPNsキーは別物**。p12追加・証明書の一括失効・権限拡大で回避しない。6件構成で署名できなければエラー分類を記録してeng-leadへ差し戻す |
| Export/upload失敗・タイムアウト / ビルド番号重複 | **送信済みの可能性あり**。まずASCで該当版・番号の到達/処理状態を確認し、重複アップロードを避ける。再ビルドが必要なら**新規workflow_dispatch**（`gh workflow run`）。`Re-run jobs`は同じ`run_number`なので送信済み番号には使わない |
| 配布後の不具合 | オーナーが問題ビルドの配布を止め、必要ならTestFlightでExpire Build。旧正常ビルドが有効なら内部グループで再指定しテスターへ案内（端末は自動で旧版に戻らない）。未配布ならグループへ追加しない。アップロード済みビルドの上書き・自動取消はできない |
| APNs: `BadDeviceToken` / `DeviceTokenNotForTopic` / 通知が来ない | **TestFlightはproduction、Xcode直入れはsandbox**。本体のBundle ID＝`APNS_TOPIC`、対象トークンの`users.push_env=production`、配布時の`aps-environment`を確認。archiveのdevelopment表示だけで失敗としない。`APNS_ENV`は未設定行のフォールバックにすぎない。APNs側の鍵・環境は別管理（G1 RUNBOOK）で、今回の6件に追加しない。修正はオーナー承認の別操作。アプリ再起動で再登録を試し、トークンの手書き転記・DB直接書換えはしない |

この変更は文書のみ。**DB migrationなし／本番データ切り戻しなし**。手順書自体を戻す場合はPR経由のrevertを使い、force pushしない。署名キーや接続情報の実値、profile、トークン、招待先はIssue・PR・ログ・スクリーンショットに載せない。

## 3. 実行後チェック（オーナーが確認して初めて配布完了）

- [ ] Actionsの**本番**SummaryとRun URL・SHA・版・ビルド番号を記録。Cleanup実行と署名warningの確認結果も残す（値は残さない）。dry-run成功とは分ける。
- [ ] App Store Connect → Lien → TestFlightで**同じ版・ビルド番号**が見え、Processingが終わり内部テストに追加できる。Missing Compliance等の保留があれば回答権限者が解消する。workflow緑だけでは到達済みにしない。
- [ ] Internal Testingの意図した内部グループに**そのビルド**を追加。承認済みのASCユーザーをInvite Testersで追加し、対象アプリへのアクセスも確認。[C]
- [ ] テスター本人が**招待メールの受信**を確認し、招待を受諾、TestFlightから該当番号をインストールして起動できる。未着なら送付先アカウント一致・迷惑メール・ASCユーザー招待の受諾・グループ/ビルド割当を確認してから、オーナーが再招待する。メールアドレスや端末画面の個人情報は記録しない。[C]
- [ ] 実行記録: `日時(JST) / SHA / Run URL / 版(番号) / ASC表示・処理 / 招待受信 / インストール / 待機理由`。未確認は`null + 理由`。1時間超過ならApple処理/署名/CIのどこで待ったかを記録し、再送を連打しない。

## 根拠・詳細（このシートと一緒に参照）

実装: [workflow](../../../.github/workflows/lien-release.yml) / [署名スクリプト](scripts/release.sh) / [書き出し](Config/ExportOptions.plist) / [archive検査](scripts/verify_archive.py) / [設定詳細 §8](README.md#8-testflight-へのアップロードg0-のあとに人間がやること) / [APNs G1 §2](../scripts/g1/RUNBOOK.md) / [設計 §7](../../../docs/DESIGN.md)。

公式資料（2026-10-20確認）: [A: Apple Team API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/) / [B: Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates) / [C: 内部テスター・招待](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers) / [D: Supabase API keys](https://supabase.com/docs/guides/getting-started/api-keys)。署名・初回の1時間到達・配布の実測は本番実行時に別途確認する。
