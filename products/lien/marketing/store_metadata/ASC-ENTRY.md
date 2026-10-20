# App Store Connect 投入・提出手順 (T32 / G5 #115)

対象: 無料の Lien v1.0。更新: 2026-10-20 JST。**エージェントはASCを操作・提出・公開しない。本書はオーナー用。**

**現在は提出不可。** [G5-CHECKLIST.md](G5-CHECKLIST.md) の最終ゲートに404・法務実値・提出ビルド・データ申告の未整合がある。以下の30分は、これらを解消し、アプリレコード/ビルド処理が完了した後の入力・再確認の目安。開発、署名、アップロード、処理待ち、URL公開、審査待ちの時間を含まない。提出期限は**2026-10-27(火)**、準備期限は**10-26(月)** (Issueの「日」は曜日誤記)。公開は10/30–31、手動公開のまま人間が確定する。

値の正本は `ja/*.txt`。本文を重複転記しない。質問票は [ASC-ANSWERS.md](ASC-ANSWERS.md)、審査員への本文は [review-notes.md §0](../review-notes.md#0-notes-for-review-に貼る本文)。Appleの画面名/表示順が違う場合は項目名で照合し、未知の設問を推測でNoにしない。

## 0. 開く前のゲート (2分)

| オーナーが用意するもの | 合格条件 |
|---|---|
| G0 / 正しいASCチーム・Lienアプリレコード | Developer登録・契約・権限が有効。アプリ名だけで判断せず、Bundle IDを提出archiveと照合。現在の証跡は `null` |
| G4 | #42の2026-10-20 21:40 JSTの承認あり。ただし未記入の公開法務4値を承認済み実値と取り違えない |
| 提出候補 | G5最終ゲートのビルド番号・commit・署名/アップロード・対象端末検証がすべて実値。ローカル既定値 `1` はASC実値ではない |
| 素材・公開ページ | 12枚の検査成功と候補ビルドとの整合。Privacy/Support/Termsの公開実値・200・本文表示。404なら停止 |
| データ/UGC | App Privacy・manifest・ポリシーの整合と通報窓口/監視/フィルタリングの検証。警告を説明文だけでPASSにしない |
| 私的な審査連絡先 | 氏名・電話・メールの実値をオーナーがASCに直接入力。repo/Issue/PRへ転記しない |

リポジトリルートから:

```bash
python3 products/lien/marketing/tools/verify_metadata.py --print
python3 products/lien/marketing/tools/verify_screenshots.py
python3 products/lien/web/tools/build_site.py --check-publishable
```

すべて成功し、G5提出必須ゲートの⚠️/❌が解消した時だけ次へ。**#32の承認済みメタデータを保存するだけの作業と、G5の審査提出可否は別**。本書は前者の追加受入条件を変更しない。

## 1. マイApp → Lien → App情報 (2分)

1. 正しいチーム・Bundle ID・iOS・日本語のローカライズを確認する。
2. 下表の欄を入力。権利関係の質問は、第三者素材も含め権利を確認した範囲だけ回答する。未確認なら進まない。
3. **保存 → 再読み込み**し、名前とサブタイトルを正本と比較する。

| 欄 | 貼付元 / 選択 |
|---|---|
| 名前 | `ja/name.txt` (30文字以内) |
| サブタイトル | `ja/subtitle.txt` (30文字以内) |
| プライマリカテゴリ | ライフスタイル (`../aso.md` §7の承認済み案) |
| セカンダリカテゴリ | ヘルスケア/フィットネス (同上。これだけで医学的助言ありとは申告しない) |
| コンテンツ配信権 | 自作/利用許諾の実物を確認して回答。権利確認の証拠がなければ `null` |

## 2. App情報 → 年齢レーティングの質問票 (3分)

1. [ASC-ANSWERS.md §1](ASC-ANSWERS.md#1-年齢レーティング) の全行を設問と照合し入力する。UGC **Yes**、Messaging and Chat **Yes**。自由文チャットがないことだけで後者をNoにしない。
2. 各回答の適用条件と候補ビルドが一致するか確認。特に健康/ウェルネスの提供コンテンツがあれば回答を再判定する。
3. 算出された年齢、国・地域別/旧OS別表示を保存・再読み込みして記録する。**4+を保証しない**。年齢上書きやKids Categoryを独断で追加しない。

## 3. 価格および配信状況 (2分)

1. v1.0は**無料**。既存設定の通貨・販売地域と承認済み公開範囲を確認する。未決定地域を全世界と推定しない。
2. v1.1向けのサブスクリプションを今回の販売物として追加しない。RevenueCatコードが存在しても、有料表示/通信がない候補ビルドの証拠が必要。
3. 保存・再読み込み。契約や課金の同意を求められたら内容と権限をオーナーが確認する。本手順は新しい契約の代理承認ではない。

## 4. iOS App → バージョン1.0.0 → 日本語の説明欄 (3分)

`verify_metadata.py --print` の本文だけを貼る。見出し/文字数/OK表示は貼らない。

| 欄 | 正本 | 上限 / 検査 |
|---|---|---|
| キーワード | `ja/keywords.txt` | 100文字。末尾改行・空白を入れない |
| 説明 | `ja/description.txt` | 4000文字。見出し・空行を保持 |
| プロモーションテキスト | `ja/promotional_text.txt` | 170文字 |
| このバージョンの新機能 | `ja/release_notes.txt` | 4000文字。初回バージョンで欄がなければ入力不要 |
| サポートURL | `https://ryoki63.github.io/Challenge/` | 現在404。`web/site/index.html` のサポート節に実連絡先が入り、200/本文が確認できた場合のみ使用。専用support.htmlは未実装 |
| マーケティングURL (任意) | `https://ryoki63.github.io/Challenge/` | 同じトップ。現在404。公開前は貼らず、任意欄を捏造で埋めない |

保存・再読み込みで一致を確認する。Privacy Policy URLはこの欄ではなく**Appプライバシー側** (画面6) に入力する。#32の確認証跡は私的情報を除いた欄の一致と日時のみでよい。human-gate Issueをエージェントはcloseしない。

## 5. バージョン1.0.0 → Appプレビューとスクリーンショット (4分)

1. `../screenshots/manifest.json` と `../screenshots/README.md` の順番1〜6を確認し、6.7インチの **1290×2796** の6枚を、現在のASCが受け付ける対応スロットに投入する。
2. 6.1インチの **1179×2556** の6枚は、対応する入力欄がある場合のみ使用する。6.9インチなど別寸法の画像と偽らない。ASCが追加寸法を要求したら、生成/検査タスクへ戻す (無検証の拡大縮小をしない)。
3. 順番、文字切れ、実UIと説明の一致、端末プレビューを確認。今回iPadを配信対象に増やさない。動画は未提供なら追加しない。
4. 保存・再読み込みで全画像を確認し、どのスロットに何枚保存したか記録する。素材検査の成功はASCへの掲載成功ではない。

Apple正本: [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)。現行スロットを未操作のため、特定スロットへの互換受理は保証しない。

## 6. Appプライバシー → データ収集 / プライバシーポリシー (4分)

1. **GATE-10が未解決なら入力/確定しない**。[ASC-ANSWERS.md §2](ASC-ANSWERS.md#2-app-privacy) の候補は現行manifestの5型だけでは不足し得る。収集/用途の最終整合を先に確認する。
2. 決定済みのデータ型ごとに、用途・本人との紐付け・追跡を表どおり設定する。匿名認証を「紐付かない」の理由にしない。RevenueCatが有効なら無料版用回答を流用しない。
3. ポリシーURLに `https://ryoki63.github.io/Challenge/lien/legal/privacy.html` を入力 (現状404につき不可)。Privacy Choices URLが任意なら、実在しないURLを作らない。
4. プレビューのデータ型/用途/追跡と公開本文が一致することを確認する。ASCに「公開」等の確定ボタンがある場合はオーナーだけが行う。本タスクのエージェントは押さない。

## 7. バージョン1.0.0 → ビルド / 輸出コンプライアンス (3分)

1. 対象バージョン・**実際のビルド番号**を最終ゲートと照合して選択する。現状は `null`。処理中/輸出未回答/署名未確認なら停止する。
2. [ASC-ANSWERS.md §3](ASC-ANSWERS.md#3-輸出コンプライアンス) の分岐に従う。「暗号を使用」と「非免除暗号を使用」は別。OS提供TLSのみというarchiveの検証が成立する時だけ該当回答を使う。
3. IDFA/広告識別子の設問があれば同 §4 の **No** を適用条件と照合する。設問がなければ入力しない。別地域の証明/書類を求められたら架空の登録番号を作らない。
4. 選択後のビルド番号・バージョン・コンプライアンス状態を再確認する。旧CIのunsigned dry-runを配信済みビルドの証明にしない。

## 8. バージョン1.0.0 → App Review情報 (2分)

1. 審査連絡先はオーナーの実際に連絡可能な氏名/電話/メールを直接入力する (公開サポート連絡先とは別)。私的情報を本リポジトリに保存しない。
2. **Sign-in required / サインインが必要: No**。ユーザーが既存アカウントの資格情報を入力する方式ではないため。匿名セッション自動作成は [review-notes.md §0](../review-notes.md#0-notes-for-review-に貼る本文) で説明する。デモ用メール/パスワードを捏造しない。
3. Notes for Reviewには同 §0 の**英語コードブロックの中身だけ**を貼る。内部チェック表や未解決の警告を審査員向け本文と混ぜない。本文の動作が候補ビルドで確認できなければ修正・再検証してから貼る。
4. 1台でペア機能を試す補助運用を採用する場合のみ、実際に発行した2枠の招待コード・発行/失効日時(JSTとUTC offset)・運用可能な連絡方法をASCに私的に追記する。**現在未発行**。72時間/1回限りなので10/26準備時のコードを10/27提出後も有効と決めつけない。常時稼働を約束しない。
5. 失効後は人間が審査の状態に応じNotes編集またはApp Reviewのメッセージで更新する。編集不可でも可能と約束しない。未ペア相手枠だけの再発行と、既ペアの別枠新設を区別し、審査員の既存ペアを解除しない。

## 9. バージョン1.0.0 → リリース方法 (1分)

**Manually release this version / このバージョンを手動でリリース**を選ぶ。自動公開・日付指定の自動公開に変えない。承認後の公開確定はオーナーのみ (10/30–31の判断)。保存して選択状態を再読み込みする。

## 10. 提出直前の一覧・警告確認 (1分)

- [ ] 正しいアプリ/バージョン/ビルド番号。署名・提出候補commit・端末検証と一致
- [ ] 画面1〜9の保存内容が再読み込み後も残り、提出に必要な警告がゼロ
- [ ] スクリーンショットが候補と一致し、全公開URLの200/実本文/連絡先を確認
- [ ] 回答表とmanifest/Privacy本文が一致。通報/ブロック/削除/通知拒否を対象候補で確認
- [ ] App Review本文、必要な補助コードの有効期限/運用担当、連絡先が実在
- [ ] 手動リリースが維持されている。G5最終ゲートに確認日時/担当を記録

証拠画像にApple ID、私的連絡先、招待コード、ユーザーIDを含めない。⚠️/❌や不明設問が残れば提出せず担当へ戻す。30分を超えても省略しない。

## 11. 人間だけが行う提出 (入力予算外・最終意思確認)

Appleの [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/) に従い、必要な項目を **Add for Review / 審査用に追加**して提出内容を確認し、オーナーが **Submit to App Review / App Reviewに提出**を実行する。「追加」と「提出」は別で、表示された場合は両方の完了を確認する。エージェントはどちらも実行しない。

オーナーは提出日時・ビルド番号・実際の状態 (Waiting for Review等) を記録する。保存やReady for Reviewを提出成功と呼ばない。Pending Developer Releaseになっても自動公開せず、公開確定は別の人間操作。

## 12. リジェクト受信時の一次返信 (#107連携)

返信は**下書き**。オーナー/許可された担当が実際の指摘全文・条項・対象ビルド・再現条件を読み、証拠と対応を確認してからApp Reviewのメッセージで送る。本エージェントは送信しない。

まず受信を伝える必要があり、修正/再現が未確認のとき:

```text
Hello App Review Team,

Thank you for reviewing Lien. We have received your feedback and are investigating the reported issue on the submitted build. We will follow up with verified reproduction steps, supporting evidence, and any required changes. We will not treat an unverified change as resolved.

Thank you.
```

本回答の直前に確認するもの: 条項/原文、対象build/OS/端末、問題画面までの手順、再現したか否か、修正の有無と新build、添付の私的情報除去。「修正済み」「削除済み」「24時間対応済み」を未確認のまま加えない。

条項別テンプレと証拠の正本は **#107 / PR #130** (作成時OPEN)。重複ファイルは作らず、次を参照する:
- [review-rejection-playbook.md (PR #130の固定commit)](https://github.com/Ryoki63/Challenge/blob/94076efc4a86d23474e5c324d2951223e64707ff/products/lien/marketing/review-rejection-playbook.md): §3.1=2.1完了度、§3.2=5.1.1権限/データ、§3.3=1.2 UGC、§3.4=3.1.1課金、§3.5=4.0デザイン、§4=再提出前10項目。
- [review-quick-reference.md (同commit)](https://github.com/Ryoki63/Challenge/blob/94076efc4a86d23474e5c324d2951223e64707ff/products/lien/marketing/review-quick-reference.md): 一覧から該当条項へ移動する。

PR #130がmainに入った後は同ファイルのマージ済み版を使う。ただし本PRも `review-notes.md` を触るため、競合解消で審査本文・デモ有効期限の条件と#107のリンクを両方保持する。再提出ボタンもオーナーのみ。未改善のまま同じbuildを再送しない。

## 13. メタデータを変更する場合

`ja/*.txt` を先に直し、`verify_metadata.py` と `python3 -m unittest discover -s products/lien/marketing/tools -p 'test_*.py'`、関連CIを通してから人間が再投入する。採用判断は `alternatives.md` §8.5/§9 (通年訴求・99字・名前とサブタイトルの「約束」重複維持)。プロモーションテキストの変更と、審査対象のバージョン情報の変更は同じ保存/審査制約ではない。

一次資料: [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)、[App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)、[Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)。本書はASC画面の実操作検証ではなく、公式手順とリポジトリの現物の照合である。
