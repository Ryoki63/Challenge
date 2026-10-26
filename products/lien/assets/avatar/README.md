# Lien アバターアイコンセット

Lien のマスコット「タネの子」を、パステル色の円形バッジに載せた 12 種のアバター。
顔・植木鉢・手は全員共通で、**頭の飾り・表情・背景色だけ**を変えた「着替え」のセットです。

## コンセプト

- 主役は既存の「タネの子」(クリーム色のドーム頭 + 植木鉢 + ほっぺ)。`assets/plant` と同じ線色 `#4A3428`・太めのアウトライン・グラデ + 光沢で揃えています。
- 小さく出ても見分けがつくよう、**飾りのシルエットを大きく**、隣り合う背景色が被らない並びにしています(56 / 44 px で判別可、28 px は飾りの輪郭で見分けるレベル)。
- `viewBox="0 0 120 120"` の円形。円の外は透明なので、アプリ側のマスクは不要です。
- SVG 内の id (`gradient` / `clipPath`) は `<avatar id>_` で始まる名前にしてあり、1 画面に何枚並べても衝突しません。

## 一覧(id・順番・ファイル名は固定。Swift から参照されています)

| # | id | 名前 | 頭の飾り | 表情 | 背景 |
|--:|----|------|----------|------|------|
| 1 | `sprout` | ふたば | 双葉 | ふつう | `#CFE8FB` |
| 2 | `cactus` | サボテン | 花つきのサボテン | にこにこ | `#F8E4C8` |
| 3 | `star` | ほし | 星 + きらきら | ウインク | `#D6DEFA` |
| 4 | `mushroom` | きのこ | 赤い水玉のきのこ帽 | ふつう | `#D4F1E0` |
| 5 | `clover` | クローバー | 四つ葉 | ウインク | `#FFE1D2` |
| 6 | `moon` | つき | 三日月のナイトキャップ | ねむり目 | `#E2DBFA` |
| 7 | `tulip` | チューリップ | チューリップ | にこにこ | `#FFF2C2` |
| 8 | `sunflower` | ひまわり | ひまわり | ふつう | `#EFDDF6` |
| 9 | `acorn` | どんぐり | どんぐりの帽子 | ふつう(ちょっと横目) | `#E6F2C6` |
| 10 | `sakura` | さくら | 桜の花 | にこにこ | `#C9EEEE` |
| 11 | `strawberry` | いちご | いちご | にこにこ | `#FFDCE6` |
| 12 | `drop` | しずく | 水のしずく + 葉 | ふつう | `#FFE4B8` |

## 中身

| パス | 内容 |
|------|------|
| `svg/avatar_<id>.svg` | 単体の SVG(120×120) |
| `AvatarAssets.xcassets/` | Xcode 用アセットカタログ。画像名は `avatar_<id>`(例: `Image("avatar_sprout")`)。ベクターのまま保持、テンプレート描画はオフ |
| `avatars.json` | 並び順つきの一覧 `[{"id", "name_ja"}]` |
| `preview/sheet.png` | 12 種の一覧(200 px・ラベルつき) |
| `preview/sheet_small.png` | 56 / 44 / 28 px を白背景とダーク背景で並べた確認用 |
| `tools/gen_avatars.py` | 上記すべてを作るジェネレーター(Python 3 標準ライブラリのみ) |

## 再生成

`products/lien/` で実行します。`svg/`・`AvatarAssets.xcassets/`・`avatars.json`・`preview/` はすべて生成物なので、手で直さずジェネレーターを直してください。

```sh
python3 assets/avatar/tools/gen_avatars.py                # SVG・xcassets・json・プレビュー PNG
python3 assets/avatar/tools/gen_avatars.py --no-preview   # Chrome なしで SVG・xcassets・json だけ
```

プレビュー PNG は Google Chrome(headless)で作ります。見つからない場合は PNG を飛ばして終わります。

## 追加するとき

`gen_avatars.py` の `AVATARS` の**末尾**に足します。既存の id・順番は変えないでください(Swift 側が使っているため)。
