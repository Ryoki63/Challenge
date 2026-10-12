# アプリアイコン(T26 / issue #26 → 2026-10-13 に v4 へ差し替え / issue #28)

| ファイル | 内容 |
|---|---|
| `icon_1024.png` | **本番**: v4「タネの子」・**空色**(D1。ユーザー決定)。1024×1024・RGB(アルファなし)・角丸なし(Apple が適用する) |
| `icon_v4_sky.svg` | 本番アイコンの SVG 元(背景は空色。`assets/plant/v4_drafts/icon/icon_sky.svg` と同じ) |
| `icon_drafts/` | 旧ネオドット絵の 3 案(A 開花 / B 鉢の相棒 / C 双葉ハート)。**廃止**。履歴として残す(`marketing/aso.md` が contact_sheet を参照) |
| `tools/gen_icon.py` | 旧ネオドット絵のジェネレータ。**本番の `icon_1024.png` は書かない**(旧下書きだけを再生成する) |

## 使われ方

- アプリは `ios/Lien/Assets.xcassets/AppIcon.appiconset/icon_1024.png` を同梱する。これは **`icon_1024.png` のコピー**で、
  `ios/LienTests/ReleaseReadinessTests` が一致・1024×1024・アルファなし(PNG カラータイプ 2)を検査する
- App Store Connect のマーケティングアイコンも同じ 1024×1024(アルファチャンネル・角丸は不可)

## 差し替え方法

1. 新しい 1024×1024 の PNG(**アルファチャンネルなし**)を `icon_1024.png` に置く
2. `cp icon_1024.png ../../ios/Lien/Assets.xcassets/AppIcon.appiconset/icon_1024.png`
3. `ReleaseReadinessTests` が緑であることを確認する(lien-ios)

v4 の背景色違い(杏 `icon_apricot` / 若葉 `icon_mint`)は `assets/plant/v4_drafts/icon/` にある。
再生成は `assets/plant/v4_drafts/gen_icon_v4.py`(Chrome の headless で SVG を PNG にする)。
