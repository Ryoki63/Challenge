# G5 — ASC 質問票の回答表 (#115)

確認日: 2026-10-20 / 対象: 無料の Lien v1.0 / ASC操作なし。

これは**入力用回答案と適用条件**。質問票の実画面は未操作。ラベルが変わっていたら意味を照合し、未掲載の設問を一律Noにしない。提出可否は [G5-CHECKLIST.md](G5-CHECKLIST.md)。`null` は取得不能/未確認でありNoや0ではない。要件は変更しない。

## 1. 年齢レーティング

Appleの現行 [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/) と [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/) を参照。4+の固定選択ではなく質問票からAppleが算出する。旧OS/国・地域別の値も保存する。

| セクション / 設問 | 入力する回答案 | 根拠 / 適用条件 |
|---|---|---|
| In-App Controls / Parental Controls | No | 保護者専用の制限機能なし。通報/ブロックをこれと誤認しない |
| In-App Controls / Age Assurance | No | 年齢確認API・身分証確認なし |
| Capabilities / Unrestricted Web Access | No | 任意サイトを閲覧するブラウザなし。外部の規約等への限定リンク |
| Capabilities / User-Generated Content | Yes | 写真・ニックネーム・約束・植物名をペアと共有。Appleの定義は広範な配信も含むが、閉じた共有を非申告の理由にしない保守的回答 |
| Capabilities / Social Media | No | 公開フィード・発見・フォロー・拡散機能なし |
| Capabilities / Social Media Disabled for Users Under 13 | No / 非該当 | Social Mediaなし、年齢APIによる制御もなし。設問が分岐表示されない場合は入力しない |
| Capabilities / Messaging and Chat | Yes | 定型ナッジ/リアクション・写真による相手への直接通信。自由文チャットがないことだけでNoにしない |
| Capabilities / Advertising | No | アプリ内広告なし。アプリ外の告知/出稿とは別 |
| Mature Themes / Profanity or Crude Humor | None | 提供コンテンツに該当なし。UGCの対策適合は別ゲート |
| Mature Themes / Horror/Fear Themes | None | 同上 |
| Mature Themes / Alcohol, Tobacco, or Drug Use or References | None | 同上 |
| Medical or Wellness / Medical or Treatment Information | None | 診断・服薬・治療の助言なし |
| Medical or Wellness / Health or Wellness Topics | No | 提供者が健康/運動/食事の推奨を提供せず、利用者自身の約束を記録するだけという実装解釈。カテゴリ名だけを根拠にしない。実ビルド/説明文に推奨コンテンツがあればYesへ見直す |
| Sexuality or Nudity / Mature or Suggestive Themes | None | 提供コンテンツに該当なし |
| Sexuality or Nudity / Sexual Content or Nudity | None | 同上 |
| Sexuality or Nudity / Graphic Sexual Content and Nudity | None | 同上 |
| Violence / Cartoon or Fantasy Violence | None | 同上 |
| Violence / Realistic Violence | None | 同上 |
| Violence / Prolonged Graphic or Sadistic Realistic Violence | None | 同上 |
| Violence / Guns or Other Weapons | None | 同上 |
| Chance-Based / Simulated Gambling | None | 賭け事なし |
| Chance-Based / Gambling | No | 実金銭の賭け事なし |
| Chance-Based / Contests | None | 対戦・順位・報酬の競争なし。協力した日数の記録だけ |
| Chance-Based / Loot Boxes | No | 購入するランダム報酬なし |
| Made for Kids / Kids Category (表示時) | No | 子供専用アプリとして申告しない。低い年齢レーティングとKids Categoryは別 |
| Override / 高い年齢への上書き | なし | 算出値を恣意的に下げない。規約の年齢記載と異なれば提出停止・整合確認 |

回答案の主たる想定は4+だが、**算出結果は `null` (ASC未操作)**。Health or WellnessがYesなら9+要因になる。実際の表示結果を [最終ゲート](G5-CHECKLIST.md#3-最終ゲート表)へ記録する。

## 2. App Privacy

Apple [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/) が正本。匿名認証でもアカウント/端末に紐づくデータは「本人に紐づく」。**分析SDKがないことはAnalytics用途がない証明ではない**。REQUIREMENTS §7では保存データから継続・行動をSQLで集計する。

### 2.1 共通の入口

| 設問 | 回答案 |
|---|---|
| Do you or your third-party partners collect data from this app? | Yes, we collect data from this app |
| Tracking / 他社データと結合した広告追跡 | No (全型。広告連携なしを提出archiveでも確認) |
| Privacy Policy URL | `https://ryoki63.github.io/Challenge/lien/legal/privacy.html` (現在404、公開後のみ入力可) |
| Privacy Choices URL (任意) | 空欄。未提供のページを捏造しない |

### 2.2 種別ごとの入力

用途名: **App Functionality = アプリの機能 / Analytics = アナリティクス**。表の「追加」は現行マニフェスト5型に未反映という意味で、既に適合済みという意味ではない。

| データ種別 | 選択 | 用途の回答案 | 本人に紐づく | Tracking | 根拠 / 残ゲート |
|---|---|---|---|---|---|
| Contact Info / Name | Yes | App Functionality | Yes | No | ニックネーム。現行 `NSPrivacyCollectedDataTypeName` |
| User Content / Photos or Videos | Yes | App Functionality | Yes | No | 任意添付でも主機能の写真共有、常設収集なので申告。`NSPrivacyCollectedDataTypePhotosorVideos` |
| User Content / Other User Content | Yes | App Functionality + Analytics | Yes | No | 約束・アイコン・植物名・チェックイン記録。`NSPrivacyCollectedDataTypeOtherUserContent`。日次記録の集計用途は現行manifestのAppFunctionalityだけと不一致 |
| Identifiers / User ID | Yes | App Functionality + Analytics | Yes | No | Supabaseの匿名ユーザー/ペアに紐づくID。`NSPrivacyCollectedDataTypeUserID`。継続集計でIDを使うためAnalytics用途も照合 |
| Identifiers / Device ID | Yes | App Functionality | Yes | No | APNsトークン、`NSPrivacyCollectedDataTypeDeviceID`。IDFAではない |
| Other Data / Other Data Types | Yes (追加案) | App Functionality | Yes | No | `users.timezone`はユーザー生成コンテンツではない。日付境界のため保存する。現行manifestに未宣言、OtherUserContent包含の旧案は採用保留 |
| User Content / Customer Support | Yes (追加案) | App Functionality | Yes | No | ReportComposerはペアID/対象/日付/版をメールへ添える。任意サポート申告免除の全条件(表示名等)を満たす証跡なしのため、免除と断定しない |
| Contact Info / Email Address | Yes (サポート受信時の追加案) | App Functionality | Yes | No | 運営が受ける問い合わせ/通報の返信先。通常オンボでは取得しない。ASCの説明とポリシーの収集表へ反映が必要 |
| Usage Data / Product Interaction | Yes (追加案) | Analytics | Yes | No | 保存されたcheckin/nudge/invite等からD1/D7や転換を評価する実運用(§7)。分析イベントの専用送信はしないが、未収集/用途なしとは扱わない |
| Purchases / Purchase History | No **条件付き** | — | — | — | 無料ビルドでRevenueCat非初期化・非通信・購入入口なしを実測できた場合だけ。有効なら下の分岐 |
| Location / Health & Fitness / Contacts / Audio / Browsing History / Search History / Financial Info / Sensitive Info / Diagnostics / Advertising Data / Surroundings / Body | No **棚卸し条件付き** | — | — | — | 自前コードに取得APIなし。約束/写真を医療情報として解析しない。サーバーログ・SDKの実保持が判明した型は追加し、未掲載のものを一律Noにしない |

**重要な未整合**: 現行 `Lien/PrivacyInfo.xcprivacy` はName/Photos/OtherUserContent/UserID/DeviceIDの5型・機能用途だけ、現行ポリシーは「利用状況を収集しない」。上記の保守的な回答案をそのままASCだけへ入れて整合済みにはできない。eng/法務担当が実データ用途・保持/SDKを照合し、manifest/ポリシー/ASCの3点を同じ実態へ直すことを提出前ゲートにする。本タスクではコード/ポリシーや運用を独断で変えない。

サポート申告を省く場合はAppleのOptional disclosureの**全条件**の証拠が必要。「任意」だけでは足りない。サーバーログの保持期間/識別用途/診断情報は本タスクで管理画面を開いておらず `null`。これも担当者が照合する。

### 2.3 RevenueCat が有効だった場合

T33でSDKは依存追加済み。`AppServices+Live.swift` は設定の有無でクライアントを切り替え、SDKクライアントは初回利用時にconfigureする。設定キーそのものは本タスクで読まない。

- 無料v1.0 (REQUIREMENTS §3.14)は購入入口/購読不要が前提。**「非初期化・非通信・ペイウォールなし」を実ビルドで証明できなければ提出不可**。
- 有効なら [RevenueCat公式 Apple App Privacy](https://www.revenuecat.com/docs/platform-resources/apple-platform-resources/apple-app-privacy) に従いPurchase Historyへ **App Functionality + Analytics**、独自App User IDへUser IDを申告。Supabaseユーザーと結合するのでLinked=Yes、広告連携なしならTracking=No。他SDK/連携/Customer Attributesも棚卸しする。
- 有効なまま「課金なし」の文面・申告を使わない。v1.1の価格/IAP/復元/規約表示を仕上げる承認と別タスクが必要。ここで課金導入を決定しない。

## 3. 輸出コンプライアンス

参照: Apple [Overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)、[Encryption documentation](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption)、[Determine and upload](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/)。これは技術的回答の準備で、法的輸出適合の認定ではない。

| 表示される意味 / 設問 | 入力する回答案 | 条件 |
|---|---|---|
| Does your app use encryption? (広義) | Yes | HTTPS/TLSを使う。「暗号化なし」とはしない |
| 暗号化の種類: 独自/非標準アルゴリズム | No | 自前なし、SDKを含むarchive棚卸し後のみ確定 |
| 標準アルゴリズムをApple OS暗号化以外で/併用して実装 | No | OSのHTTPS/TLS/Keychain等だけと確認できた場合 |
| 上2種のいずれでもない (None of the algorithms mentioned above) | 選択 | OS内暗号化だけの分岐。画面がこの選択式の場合 |
| Only encryption provided by Apple's operating system? | Yes | 上と同じ条件。設問の反転に注意 |
| Uses non-exempt encryption? | No | ソースの `ITSAppUsesNonExemptEncryption=false` と対応。必ずarchiveの値と一致させる |
| Upload encryption documents / code | 不要の分岐 | Appleの判定が免除の場合だけ。書類や承認番号を作らない |

falseは「免除対象外の暗号化を使わない」という意味。ソースでfalseでもarchiveの値/SDK確認の代わりにはならない。書類/フランス等の追加設問が出たら、実際の提供地域・実装をもとに担当へ確認し、上表から根拠なくNoを流用しない。

## 4. 広告識別子 (IDFA)

| 設問 | 回答案 | 根拠 |
|---|---|---|
| Does this app use the Advertising Identifier (IDFA)? (表示時) | No | 自前ソースにASIdentifierManager/ATT要求なし、アプリ内広告なし。APNsトークンとは別 |
| ATT許可 / 追跡用途 | 要求しない | IDFAを要求しないアプリにATT用途文を追加しない |

この欄が現行ASCに表示されない場合は省略で、独自に入力画面を作らない。SDKの広告連携を足したらNoを再使用しない。

## 5. 保存時の確認

入力主体はオーナーのみ。保存→再読込後、型/用途/Linked/Tracking/年齢の算出値/暗号化結果を、個人情報を除いた証跡で残す。**本タスクではASCを開かず、回答・保存・Publish・Submitは一度も行っていない**。
