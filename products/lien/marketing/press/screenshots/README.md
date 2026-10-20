# プレス向けスクリーンショット 3 枚（v4「タネの子」）

Issue #94 のファクトシートに添える 3 枚。MK7（issue #80）で作った **6.7インチのストア用画像**から、
紹介内容に対応する 3 枚（02 / 06 / 05）を複製したもの。画像は本物の SwiftUI View を CI のシミュレータで描き、
キャプションと合成している。手描きのモックや実在しない画面は入っていない。画面内の記録は固定のデモデータで、実在の利用者の記録ではない。
03_widget.png は v1.0.1 の M ウィジェットを含むため、このフォルダでは使わない（`docs/REQUIREMENTS.md` §3.10）。
04_history.png は v1.0 の画面だが、デモデータの 10/13 が途切れている一方で、02 / 05 は 23日のストリークを表示しており、3枚組で事実が矛盾するため使わない。
01_home_both.png は v1.0 の画面だが、画像内のサブコピー「ふたりで決めて、毎日つづける習慣アプリ」が本文の「ふたりがそれぞれ」と食い違うため使わない（完成画像を加工せず、直すなら captions.json を更新して再生成する）。

## 1. 3 枚

| # | ファイル | ピクセル | SHA-256 | 見せている画面 | 画像内のコピー |
|---|---|---|---|---|---|
| 1 | `02_home_waiting.png` | 1290×2796 | `3abf7503f664ca8e0ff36e401f83a2f3c7cdbdb8e7fe747bb8a76db7ed7ffcbd` | ホーム（相手だけ完了 →「ゆうきが待ってるよ」） | 相手の今日が、ひと目でわかる。 |
| 2 | `06_home_solo.png` | 1290×2796 | `4436a71fe8783ef4f4b67605d2fa87033de9dc6b5a4d04250bde729e4256102d` | ソロのホーム（ペア前。相手を招待するボタンと自分の約束） | はじめるのは、ふたりで。 |
| 3 | `05_share.png` | 1290×2796 | `20d5eda9a6adf1ff3032557023d5856d3fe7c2b0bbf1c8a1c96a1f5b57f06e4a` | シェア画像（9:16）の実描画 | 記録は、かたちに残せる。 |

- 3 枚とも PNG・アルファなし（color type 2）。6.7インチのストア要件 1290×2796 を満たす。
- 元ファイルは [`../../screenshots/6.7in/`](../../screenshots/6.7in/) の同名ファイル。SHA-256 が一致することを `tools/verify_press.py` が検査する。
- 6.1インチ版（1179×2556）は [`../../screenshots/6.1in/`](../../screenshots/6.1in/) にある。本フォルダはファクトシート用に 6.7インチだけを持つ。

## 2. 生成元（MK7 / issue #80）

| 項目 | 値 |
|---|---|
| 画風 | v4「タネの子」 |
| 生成方法 | `LienTests/StoreScreenshotRenderTests` が本物の View を 430×932pt・3倍で `ImageRenderer` 描画 → キャプションと合成 |
| 生成 CI | `lien-ios` #39389661638（2026-10-20、attempt 2） |
| 生成 commit | `c308e5c`（`../../screenshots/manifest.json` の `provenance.commit`）。PR ブランチ上の生成時 commit で、main には squash マージのため含まれない。画像は `13f0570` の元画像と SHA-256 が一致する |
| キャプションの正本 | [`../../screenshots/captions.json`](../../screenshots/captions.json) |
| 元の設計・手順 | [`../../screenshots/README.md`](../../screenshots/README.md) |

**描いていないもの**: ステータスバー・ナビゲーションバー（OS が描く）、壁紙・他のアプリのアイコン、
実装に無い画面・機能。表示される記録は固定のデモデータ（あおい / ゆうき、筋トレ / ランニング、記録23日、植物は段階3「みどり」）。
本フォルダの3枚は v1.0 の画面だけで、M ウィジェット（v1.0.1）は使わない。04 のカレンダーは、このデモデータの
10/13 途切れと 23日のストリークが両立しないため使わない（10/13 で途切れれば、10/20 が未完了の時点で現在は6日。完了すれば7日）。

## 3. ファクトシートでの使い方

`fact-sheet.html` の「画面イメージ」に、次のキャプションで埋め込んでいる。

1. ホーム（相手が待っている）
2. ペアのはじめかた（招待）
3. シェア画像

画像の `alt` には、画面の内容を短く書く（`fact-sheet.html` を参照）。画像内のコピーと、`copy.md` の主張が矛盾しないことを mkt-review が確認する。

## 4. 差し替え手順

画面が変わったら、MK7 の手順で 6.7インチの画像を作り直してから、このフォルダへ複製する。

```bash
cd products/lien/marketing
# 1. MK7 の手順で 6.7in の画像を更新する（../../screenshots/README.md §4）
# 2. プレス用に複製する
cp screenshots/6.7in/02_home_waiting.png press/screenshots/02_home_waiting.png
cp screenshots/6.7in/06_home_solo.png    press/screenshots/06_home_solo.png
cp screenshots/6.7in/05_share.png       press/screenshots/05_share.png
# 3. 検査する（寸法・アルファなし・元画像との SHA-256 一致）
python3 tools/verify_press.py
```

- 画像だけ差し替えて `fact-sheet.html` のキャプションを変えないと、内容がずれる。キャプションも直す。
- 画像を加工（トリミング・色変更・文字の足し算）しない。ストア用の完成画像をそのまま使う。
- `03_widget.png` は v1.0.1 の M を含むため複製しない。v1.0 で使うのは S ウィジェットだけで、プレス3枚は 02 / 06 / 05。
- `04_history.png` は 10/13 途切れと 23日のストリークが矛盾するため複製しない。使う場合は `StoreScreenshotRenderTests` のデモデータを直し、MK7 の手順で画像を作り直す。
- `01_home_both.png` は画像内のサブコピーが本文と食い違うため複製しない。使う場合は `captions.json` の `01_home_both` の `sub` を直し、MK7 の手順で画像を作り直す。
