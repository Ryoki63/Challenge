# プレス向けスクリーンショット 3 枚（v4「タネの子」）

Issue #94 のファクトシートに添える 3 枚。MK7（issue #80）で作った **6.7インチのストア用画像**から、
紹介内容に対応する 3 枚を複製したもの。画像は本物の SwiftUI View を CI のシミュレータで描き、
キャプションと合成している。手描きのモックや実在しない画面は入っていない。画面内の記録は固定のデモデータで、実在の利用者の記録ではない。

## 1. 3 枚

| # | ファイル | ピクセル | SHA-256 | 見せている画面 | 画像内のコピー |
|---|---|---|---|---|---|
| 1 | `01_home_both.png` | 1290×2796 | `08b2adda101e8fa0a38d42a8d77337778579f1e7a70abe8343fee2cc63b7503f` | ホーム（ふたり達成・植物・23日・チケット2枚） | 約束は、ひとつだけ。 |
| 2 | `02_home_waiting.png` | 1290×2796 | `3abf7503f664ca8e0ff36e401f83a2f3c7cdbdb8e7fe747bb8a76db7ed7ffcbd` | ホーム（相手だけ完了 →「ゆうきが待ってるよ」） | 相手の今日が、ひと目でわかる。 |
| 3 | `03_widget.png` | 1290×2796 | `c880b8b85330665dffd2605ad6f70d6cadcc319ed0fe77fa85af2f943f24664a` | ウィジェット（中・小）の実描画 | ホーム画面でも、ふたりの今日。 |

- 3 枚とも PNG・アルファなし（color type 2）。6.7インチのストア要件 1290×2796 を満たす。
- 元ファイルは [`../../screenshots/6.7in/`](../../screenshots/6.7in/) の同名ファイル。SHA-256 が一致することを `tools/verify_press.py` が検査する。
- 6.1インチ版（1179×2556）は [`../../screenshots/6.1in/`](../../screenshots/6.1in/) にある。本フォルダはファクトシート用に 6.7インチだけを持つ。

## 2. 生成元（MK7 / issue #80）

| 項目 | 値 |
|---|---|
| 画風 | v4「タネの子」 |
| 生成方法 | `LienTests/StoreScreenshotRenderTests` が本物の View を 430×932pt・3倍で `ImageRenderer` 描画 → キャプションと合成 |
| 生成 CI | `lien-ios` #39389661638（2026-10-20、attempt 2） |
| 生成 commit | `c308e5c`（`../../screenshots/manifest.json` の `provenance.commit`） |
| キャプションの正本 | [`../../screenshots/captions.json`](../../screenshots/captions.json) |
| 元の設計・手順 | [`../../screenshots/README.md`](../../screenshots/README.md) |

**描いていないもの**: ステータスバー・ナビゲーションバー（OS が描く）、壁紙・他のアプリのアイコン、
実装に無い画面・機能。表示される記録は固定のデモデータ（あおい / ゆうき、筋トレ / ランニング、記録23日、植物は段階3「みどり」）。

## 3. ファクトシートでの使い方

`fact-sheet.html` の「画面イメージ」に、次のキャプションで埋め込んでいる。

1. ホーム（ふたり達成）
2. ホーム（相手が待っている）
3. ウィジェット

画像の `alt` には、画面の内容を短く書く（`fact-sheet.html` を参照）。画像内のコピーと、`copy.md` の主張が矛盾しないことを mkt-review が確認する。

## 4. 差し替え手順

画面が変わったら、MK7 の手順で 6.7インチの画像を作り直してから、このフォルダへ複製する。

```bash
cd products/lien/marketing
# 1. MK7 の手順で 6.7in の画像を更新する（../../screenshots/README.md §4）
# 2. プレス用に複製する
cp screenshots/6.7in/01_home_both.png    press/screenshots/01_home_both.png
cp screenshots/6.7in/02_home_waiting.png press/screenshots/02_home_waiting.png
cp screenshots/6.7in/03_widget.png       press/screenshots/03_widget.png
# 3. 検査する（寸法・アルファなし・元画像との SHA-256 一致）
python3 tools/verify_press.py
```

- 画像だけ差し替えて `fact-sheet.html` のキャプションを変えないと、内容がずれる。キャプションも直す。
- 画像を加工（トリミング・色変更・文字の足し算）しない。ストア用の完成画像をそのまま使う。
