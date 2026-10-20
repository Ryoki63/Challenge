# Lien 紹介・プレス向け素材（Issue #94 / mkt M8）

公開日に出すための紹介素材の下書き。**事実だけ**を使い、v1.0 に無い機能は書かない。
このフォルダの作業では、外部送信・投稿・送付をしない。mkt-lead の承認と mkt-review のレビュー後に使う。

## 1. ファイル

| ファイル | 内容 |
|---|---|
| [`fact-sheet.html`](fact-sheet.html) | A4 1枚のファクトシート。機能・対象・価格・提供元・連絡先・画面3枚・出典を1ページに収める。ブラウザから印刷または PDF 保存できる |
| [`copy.md`](copy.md) | 紹介文 3 種（60 / 200 / 581 字）と、主張ごとの根拠・書かないことの一覧 |
| [`screenshots/`](screenshots/) | v4「タネの子」の実画面から作ったストア用画像 3 枚（6.7インチ）。ファクトシートにも埋め込んでいる |
| [`screenshots/README.md`](screenshots/README.md) | 3 枚の内容・キャプション・生成元・差し替え手順 |

## 2. 受入条件との対応（Issue #94）

| 受入条件 | 対応 |
|---|---|
| `products/lien/marketing/press/` にファクトシート 1 枚（機能・対象・価格・提供元・連絡先）と紹介文 3 種（60/200/600 字） | `fact-sheet.html` に6項目を用意。`copy.md` に 60 / 200 / 581 字の3種を用意（すべて上限以内） |
| v1.0 に無い機能を書かない。数値は `docs/KPI.md`・`docs/CONCEPT.md` の出典つきのものだけ | v1.0 の機能は `docs/REQUIREMENTS.md` §3.2–§3.13 の範囲だけ。市場・実績の数値は書かず、価格は「v1.0 は全機能無料」（利用規約 第3条）だけ。UI 仕様の表現は REQUIREMENTS の範囲。`tools/verify_press.py` が将来機能・価格案・実績値を機械で止める |
| スクショ 3 枚（v4 画風）を添える。mkt-review のレビューを通す | `screenshots/` に 6.7インチ（1290×2796）の3枚を同梱し、ファクトシートにも埋め込み。生成元は MK7（`../screenshots/`）の実画面。**v1.0 の 02 / 06 / 05 を使い、03 の M ウィジェット（v1.0.1）、04 のカレンダー（デモの10/13途切れが23日の記録と矛盾）、画像内コピーが本文と食い違う 01 は使わない**。mkt-review の正式レビューは PR で依頼する |

## 3. ファクト（2026-10-20 時点）

| 項目 | 値 | 出典 |
|---|---|---|
| アプリ名 | Lien（リアン） | `store_metadata/ja/name.txt` |
| 提供環境 | iOS アプリ | `docs/REQUIREMENTS.md` §4（対応OS） |
| 価格 | v1.0 は全機能無料 | `products/lien/marketing/legal/terms.html` 第3条、`docs/CONCEPT.md` §6 |
| 提供元 | `<OPERATOR_NAME>`（G4 #42 で確定） | `legal/CHECKLIST-G4.md` §1、`legal/terms.html` 冒頭 |
| 連絡先 | `<CONTACT_EMAIL>`（G4 #42 で確定） | `legal/CHECKLIST-G4.md` §1、`../../ios/Lien/Core/SupportLinks.swift` |
| 公開日 | 未確定（目標 2026-10-31。審査結果で動く） | `docs/TASKPLAN.md` §9.2 |
| 対象 | 恋人・夫婦・友達・家族など、習慣を一緒に続けたいふたり | `docs/CONCEPT.md` §2 |
| 画面 | v4「タネの子」の実画面 3 枚 | `../screenshots/README.md`（MK7 / issue #80） |

- **実績値は無い**。利用者数・ダウンロード数・順位・受賞は、公開前で取得できないため未取得（0 ではない）。紹介文にもファクトシートにも書かない。
- 将来の価格案（月700円 / 年2,400円）は v1.1 の `docs/CONCEPT.md` §6 の案であり、v1.0 の紹介素材には使わない。
- 公開日は審査結果で動くため、本文では断定しない。

## 4. G4 の未確定値（推測で埋めない）

`<OPERATOR_NAME>` と `<CONTACT_EMAIL>` は **G4（#42）で人間が決める値**。このフォルダでは決めない。
2026-10-20 時点で `SupportLinks.contactEmail` は空で、アプリ内「お問い合わせ」も宛先なしの下書きになる。
そのため、確定前は「アプリ内から連絡できます」とは書かず、確定後の設定先だけを書いている。

置換するときは、次の2つを同じ値にする（法務ページ・アプリ・本資料で一致させる）。

```bash
# 置換漏れの確認（G4 確定後は 0 件にする）
grep -rn '<OPERATOR_NAME>\|<CONTACT_EMAIL>' products/lien/marketing/press/

# 置換後に検査
cd products/lien/marketing && python3 tools/verify_press.py
```

- 提供元は App Store の販売者名と一致させる（`legal/CHECKLIST-G4.md` §1）。
- 連絡先は私用アドレスを避け、専用アドレスにするのが推奨（公開リポジトリに出すため）。
- 値はリポジトリに書かない判断もありうる。その場合は送付直前に手元で埋め、この文書にはトークンを残す。判断は mkt-lead。

## 5. スクリーンショット 3 枚

| # | 画像 | 見せている画面 | ファクトシートのキャプション |
|---|---|---|---|
| 1 | [`02_home_waiting.png`](screenshots/02_home_waiting.png) | ホーム（相手だけ完了 →「ゆうきが待ってるよ」） | ホーム（相手が待っている） |
| 2 | [`06_home_solo.png`](screenshots/06_home_solo.png) | ソロのホーム（ペア前。相手を招待するボタンと自分の約束） | ペアのはじめかた（招待） |
| 3 | [`05_share.png`](screenshots/05_share.png) | シェア画像（9:16）の実描画 | シェア画像 |

- 3 枚とも 1290×2796（6.7インチ）の PNG。元の `../screenshots/6.7in/` と SHA-256 が一致する。
- 画像は本物の SwiftUI View を CI のシミュレータで描いたもの。手描きのモックや実在しない画面は入っておらず、画面内の記録は固定のデモデータで、実在の利用者の記録ではない（[`../screenshots/README.md`](../screenshots/README.md) §2）。
- 3 枚とも v1.0 の画面。03_widget.png は v1.0.1 の M ウィジェットを含むため、このフォルダでは使わない（`docs/REQUIREMENTS.md` §3.10）。
- 04_history.png は v1.0 の画面だが、デモデータの 10/13 が途切れている一方で、02 / 05 は 23日のストリークを表示しており、3枚組で事実が矛盾する。このためプレスでは使わない（MK7 のデモデータを直す場合は `../screenshots/README.md` §2 と `StoreScreenshotRenderTests` を更新して再生成する）。
- 01_home_both.png は v1.0 の画面だが、画像内のサブコピー「ふたりで決めて、毎日つづける習慣アプリ」が本文の「ふたりがそれぞれ」と食い違うため、プレスでは使わない。MK7 の完成画像を加工せず、直す場合は `../screenshots/captions.json` を更新して再生成する。
- 画面の文言は `../screenshots/captions.json` が正本。画像を差し替えるときは MK7 の手順で作り直す。

## 6. mkt-review に見てほしいこと

- **v1.0 の範囲**: 課金・プレミアム・写真アルバム・Sign in with Apple・Android・複数ペア・花壇・おきゃくさん・ストリーク保険・M ウィジェット（v1.0.1）を書いていないこと。
- **事実との一致**: 約束は1人1つ、チェックインは1日1回、写真はペア成立後、植物は「ふたり達成日」の累計で育つ、通知は相手の名前、という説明が `docs/REQUIREMENTS.md` §3.2–§3.13 と一致すること。
- **文字数**: 60 / 200 / 581 字。60 字は上限ちょうど、200 字も上限ちょうどなので、数え方（空白・改行を除く）を含めて確認すること。
- **提供元・連絡先**: G4 #42 で確定するまで `<OPERATOR_NAME>` / `<CONTACT_EMAIL>` のままであること。確定前に推測で埋めないこと。
- **画面**: 3 枚が紹介内容に対応し、v4 画風であること。画像とキャプションのずれがないこと。3 枚とも v1.0 の画面で、M ウィジェット（v1.0.1）が写っていないこと。04 のカレンダーは 23日のストリークと矛盾するため使っていないこと。
- **表現**: 罰・恥・誇大表現（No.1 / 最強 / 絶対 / 必ず など）がないこと。

## 7. 検証

```bash
# 紹介文の文字数・必須項目・v1.0 の範囲・スクショ3枚を機械で検査
cd products/lien/marketing && python3 tools/verify_press.py

# 検査ロジックの単体テスト（既存の marketing tools と一緒に走る）
cd products/lien/marketing && python3 -m unittest discover -s tools -p "test_*.py"

# ファクトシートが A4 1ページに収まることを確認（Chrome がある環境）
cd products/lien/marketing/press
'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  --headless --disable-gpu --no-sandbox --user-data-dir=/tmp/chrome-press \
  --no-pdf-header-footer --print-to-pdf=/tmp/fact-sheet.pdf \
  "file://$PWD/fact-sheet.html"
```

2026-10-20 の確認: ファクトシートは Chrome headless の印刷で **A4 1ページ**（595×842pt、`/Count 1`）。3 枚の画像は 1290×2796・アルファなし。

## 8. 出典

- 機能・対象・画面: [`docs/REQUIREMENTS.md`](../../../../docs/REQUIREMENTS.md) §3.2–§3.13、[`docs/CONCEPT.md`](../../../../docs/CONCEPT.md) §2（対象）・§5（設計原則）
- 価格: [`../legal/terms.html`](../legal/terms.html) 第3条、[`docs/CONCEPT.md`](../../../../docs/CONCEPT.md) §6
- 提供元・連絡先の未確定: 提供元は [`../legal/CHECKLIST-G4.md`](../legal/CHECKLIST-G4.md) §1・[`../legal/terms.html`](../legal/terms.html) 冒頭、連絡先は同チェックリスト §1・[`../../ios/Lien/Core/SupportLinks.swift`](../../ios/Lien/Core/SupportLinks.swift)
- 画面: [`../screenshots/README.md`](../screenshots/README.md)（MK7 / issue #80）、[`../screenshots/captions.json`](../screenshots/captions.json)
- 公開目標: [`docs/TASKPLAN.md`](../../../../docs/TASKPLAN.md) §9.2

## 9. レビュー記録

- 2026-10-20 23:14 JST: mkt-review 観点の独立レビュー（読み取り専用）**FAIL**。Blocker 3件 = ①`04_history.png` の10/13途切れと02/05の23日ストリークの矛盾、②200/600字の「ウィジェットでふたりの記録」が REQUIREMENTS §3.10 を超える、③提供元・連絡先が G4 未確定のトークン。Minor = 対象の出典（CONCEPT §2 が正）、`（null）` の内部用語。
- 2026-10-20 23:17 JST: 修正版の再レビュー **PASS（条件付き）**。Blocker ①は 04 を 06_home_solo に差し替えて解消、②は「今日の状態とストリーク」に限定して解消。残る条件は ③ G4 #42 の提供元・連絡先の実値確定のみ。
- したがって、この資料は **G4 #42 の値が入るまで外部掲載・送付しない**。確定後に §4 の手順でトークンを置換し、mkt-lead の承認を得る。
