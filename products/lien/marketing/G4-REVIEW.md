# G4 #42 — 承認返信の照合と残る人間ゲート

確認日時: 2026-10-20 21:20 JST / 担当: eng-exec

**状態: 一部承認を確認。G4 全体は承認待ち。** ストア申請・公開・ドメイン購入は行っていない。
対象スナップショットは `13f057030a1e63fefe295bb0fc5e6519b343e652`。この記録では素材・法務原稿・実装を変更しない。

## 1. 承認の根拠と適用範囲

- [承認依頼](https://github.com/Ryoki63/Challenge/issues/42#issuecomment-6118146456): 2026-10-12 14:10 JST。文言6ファイルの候補と「Pairy 系キーワード不採用」「新年訴求への切り替え」の2方針を提示。
- [オーナー返信](https://github.com/Ryoki63/Challenge/issues/42#issuecomment-6288190684): 2026-10-20 18:48 JST。GitHub login `Ryoki63`、authorAssociation `OWNER`、本文「それでOK!」。エージェント用マーカー無し。
- [自動再開コメント](https://github.com/Ryoki63/Challenge/issues/42#issuecomment-6290623618): 2026-10-20 21:16 JST。`<!-- lien-agent -->` 付きなので、追加の人間承認ではない。

返信は直前の承認依頼への承認として扱う。現在の branch の全ファイルや、依頼に含まれていないスクショ・法務事項の承認には拡張しない。

### 現物との照合

承認依頼時の素材コミット `37e12ed` と対象スナップショットを `git diff` と Git blob ID で比較した。

| 対象 | 確認結果 | 承認の扱い |
|---|---|---|
| `store_metadata/ja/name.txt` | 依頼時と同一: `Lien(リアン)- ふたりの約束` | 承認済み |
| `store_metadata/ja/subtitle.txt` | 依頼時と同一: `約束はひとつだけ。静かに続く習慣アプリ` | 承認済み。「約束」の重複を理由に独断で変更しない |
| `store_metadata/ja/release_notes.txt` | 依頼時と Git blob ID が同一 | 承認済み。ASC への入力は未実施 |
| Pairy 系の不採用 | 現行6ファイルにも競合名無し(機械検査) | 方針は承認済み。他社サービスの現況・商標登録の有無は本作業で断定しない |
| `store_metadata/ja/keywords.txt` | 依頼は新年・正月入り81字、現行は通年99字。`d7983d3`(#90)で変更 | **現行値は再確認待ち** |
| `store_metadata/ja/promotional_text.txt` | 依頼の新年版から通年版へ変更。成長説明も「ふたりそろった日の数」に更新 | **現行値は再確認待ち** |
| `store_metadata/ja/description.txt` | 成長・休息・ウィジェットの記述と末尾の季節訴求が依頼時と異なる | **現行値は再確認待ち** |

現行の通年案は `store_metadata/alternatives.md` §8 に経緯がある。しかし返信本文には通年案への明示的な言及が無いため、返信時刻が #90 のマージ後であることだけで現行値を承認済みにしない。
逆に、承認依頼の旧文言へ戻すと現行仕様との不整合を復活させるため、素材は変更せずオーナーに差分を提示する。
文言の正本は引き続き `store_metadata/ja/*.txt` とし、再承認時は `python3 tools/verify_metadata.py --print` の出力を使う。

### 現行文言6ファイルの SHA-256

承認後の変更を識別するための観測値。これらの hash の記録自体は人間承認を意味しない。

| ファイル(`store_metadata/ja/` 配下) | SHA-256 |
|---|---|
| `name.txt` | `ce27a28933d1bfc52fb4ec17bdcbc99b27e393e4b67dc2da5b8ba8edfd52393a` |
| `subtitle.txt` | `393c4ab513e69218c3eb6c00d46ae85427c247953fa3f556864cc9f25aca5413` |
| `keywords.txt` | `595a0f28031508141f0f8ea06e60f1754460c2b46add3ae3424bb7cccd9e41a7` |
| `promotional_text.txt` | `5d9cbd03d962dfbd36ee756dea36e7d49af9333de06228a65636418d70a5682c` |
| `description.txt` | `c7942e5139237b9942ff24bcb292199d2655cdbd4450705504af1095c8680d30` |
| `release_notes.txt` | `d071f0ec7acd47ba6651d3584a4a0b6a18241a38c8703a4522f8f9e8c2f279dd` |

## 2. Issue 本文の各項目

| Issue 本文の項目 | 直接確認の結果 | 人間ゲート |
|---|---|---|
| 表示名最終確認 | §1 のとおり依頼時の値と一致 | 承認済み |
| スクショ最終確認 | 6.7in / 6.1in 各6枚を機械検査。6.7in の一覧画像は目視で見出し・6場面・植物・記録を確認 | オーナーの最終確認は未取得。機械検査やエージェントの目視とは別 |
| 説明文最終確認 | §1 の3ファイルが承認依頼時から変更済み | 現行値の再確認待ち |
| プライバシーポリシー/利用規約の最終確認 | 原稿2ファイルと生成HTMLを確認。公開用の必須4項目が未記入 | 記入値と最終内容の確認待ち。法的な適合性を保証するレビューではない |
| 独自ドメイン取得の判断(任意) | 返信・承認依頼には判断無し。既存の公開先候補は `legal/CHECKLIST-G4.md` §3 | 判断値は `null`(理由: 意思表示無し)。必須ゲートには追加しない。購入・契約無し |

### スクショの対象版

- 対象: `screenshots/6.7in/*.png` / `screenshots/6.1in/*.png`、各6枚。
- オーナー確認用一覧: [contact-sheet-6.7in.png](screenshots/contact-sheet-6.7in.png)。6.1in の各画像も `screenshots/6.1in/` で確認する。
- `screenshots/manifest.json`: 生成日時 `2026-10-20T17:28:46+09:00`、描画コミット `c308e5c83f5d4672755100f23aa277130fa04677`、`lien-ios` run `39389661638` / attempt `2`。
- 12枚は本物の View を描いた画像で、OS のステータスバー等を含まない(`screenshots/README.md` §6)。実機 Safari / 実機ストア / App Store Connect の表示確認は本作業では未実施。
- `manifest.json` SHA-256: `2016c1fd30cdea2028b6731eb5ac86f2b6032bb6975872fa3730fff015523f93`。
- 一覧画像 SHA-256: `824f6f576631b877c85011c183851ce5cbfa2c01ec4d511e8b378d96a7de8194`。

### 法務の未記入事項

| 項目 | 値 | 理由 |
|---|---|---|
| 制定日 | `null` | 原稿の G4 プレースホルダが未記入。公開目標日から推測しない |
| 事業者表記 | `null` | 原稿の G4 プレースホルダが未記入。GitHub の表示名・ローカルユーザー名を流用しない |
| 問い合わせメール | `null` | 原稿の G4 プレースホルダが未記入。`SupportLinks.contactEmail` も空 |
| 管轄裁判所 | `null` | 利用規約の G4 プレースホルダが未記入。所在地を推測しない |

`legal/CHECKLIST-G4.md` §2 の内容確認、App Privacy 回答との照合、Supabase リージョン、提供地域は未確認のまま残す。アカウント設定・本番環境・秘密は読んでいない。
原稿は Markdown が正本であり、HTML を直接編集しない。必須値が決まるまでは公開前チェックの失敗を解除しない。

## 3. 検証証拠

以下は 2026-10-20 に対象 worktree で実行した結果。コマンドの作業ディレクトリは表のとおり。

| 作業ディレクトリ | コマンド | 結果 |
|---|---|---|
| `products/lien/marketing` | `python3 tools/verify_metadata.py --print` | PASS: 6ファイル。キーワード99/100字、禁止語・競合名・重複検査 |
| 同上 | `python3 tools/verify_screenshots.py` | PASS: 2サイズ各6枚、寸法・アルファなし・manifest・キャプション一致 |
| 同上 | `python3 -m unittest discover -s tools -p 'test_*.py' -v` | PASS: 36 tests / 0 failures |
| `products/lien/web` | `python3 tools/build_site.py --check` | PASS: 生成物11件がコミット済みの内容と一致 |
| 同上 | `python3 -m unittest discover -s tools -p 'test_*.py' -v` | PASS: 47 tests / 0 failures |
| 同上 | `python3 tools/build_site.py --check-publishable` | **FAIL / 公開不可**: 法務HTML4件に G4 プレースホルダ、`site.json` の `xUrl` 未設定。計5件の指摘を確認 |

公開前チェックの失敗は既存の未記入値によるもので、今回の文書変更の回帰ではない。成功扱い・検査回避・外部配信はしない。`xUrl` は #76 の既存公開ゲートであり、G4 の新しい受入条件には追加しない。
差分検査・hash/相対リンク照合・独立レビュー・PR/CI の結果は `progress/JOURNAL.md` の「G4 #42 承認返信の反映」と本 PR に追記する。
対象は文書だけなので iOS の型チェック・lint・バイナリビルドは対象外(アプリ・設定・画像・生成器を変更しない)。
ストア素材の既存テスト、HTML 生成物照合、公開前ゲート、独立レビューは別々に結果を記録する。G4 の完了判定は Issue #42 本文の必須確認・承認に限定し、現時点ではそれらが揃っていないため承認待ちとする。#76 の `xUrl` 未設定による公開不可は別状態として保持し、G4 の完了条件には加えない。

## 4. オーナーへの判断依頼(1件に集約)

**現行の通年文言3ファイルとスクショ12枚を採用し、法務の必須4項目を提示して最終確認へ進めてよいですか。**

1. **推奨: 現行案を確認して採用**。必須4項目の値と、法務本文・`legal/CHECKLIST-G4.md` §2 の確認結果を返信する。独自ドメインは任意で「今回は取得しない」または取得希望のドメインを指定する(契約・購入承認は別途必要)。
2. 修正箇所を指定する。新年訴求を選ぶ場合も、旧版へ一括で戻さず現行の成長ルール等と整合する文言を確認する。

返信が来るまで Issue #42 は open / human-gate / needs-approval。PR は証拠と引継ぎの提出用であり、マージ・ストアへの入力・審査提出・公開の承認を代替しない。
