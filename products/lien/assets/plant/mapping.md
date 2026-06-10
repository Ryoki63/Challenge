# 植物スプライト v0 — 成長段階マッピングと運用ルール(T09 / issue #9)

G2(ドット絵承認)レビュー用の第1案。トーン確認は `preview/contact_sheet.png` を見る。
差し戻しは `tools/gen_sprites.py` のピクセル配列(パレット + 16文字幅の2次元配列)を
直接編集して再生成する。

## 1. 仕様の根拠

- REQUIREMENTS §0: ネオドット絵 16×24px相当、静止画12〜15枚で成立させる
- REQUIREMENTS §3.9: 成長は **ふたり達成日の累計** 種(0)→芽(3)→双葉(7)→若葉(14)→つぼみ(30)→開花(60)。**枯れない・後退しない**
- TASKPLAN T09: 13枚 = 土1 + 5段階×(通常/喜び) + しょんぼり2

## 2. 13枚の内訳と成長段階の対応

6成長段階に対して描画は5段階 + 土。**stage0(種)は「土に埋まっていて見えない」**ため
soil と同一見た目とし、専用スプライトを持たない(合理化の根拠: 種は植えた直後で
地上に何も出ていない。ソロ状態=鉢に土だけ、とも視覚的に連続する)。

| 累計達成日 | 成長段階 | normal | happy | sad(しょんぼり) |
|---|---|---|---|---|
| (ペア未成立) | ソロ: 土だけ | `soil` | — | — |
| 0〜2 | stage0 種(土の中) | `soil` | `soil` | `soil` |
| 3〜6 | stage1 芽 | `stage1_normal` | `stage1_happy` | `stage2_sad`(代用) |
| 7〜13 | stage2 双葉 | `stage2_normal` | `stage2_happy` | `stage2_sad` |
| 14〜29 | stage3 若葉 | `stage3_normal` | `stage3_happy` | `stage2_sad`(代用) |
| 30〜59 | stage4 つぼみ | `stage4_normal` | `stage4_happy` | `stage5_sad`(代用) |
| 60〜 | stage5 開花 | `stage5_normal` | `stage5_happy` | `stage5_sad` |

- sad は2枚のみ(v0)。**小さい株用 = `stage2_sad` / 大きい株用 = `stage5_sad`** を
  近い段階で代用する。静止画15枚の予算内に +2 枚の余地があるので、G2 通過後に
  段階別 sad を追加できる
- DESIGN §3.4 の `plantMood` は normal / happy / fidget / sad の4値。**fidget(そわそわ)は
  v0 では normal で代用**(差分はアプリ側の揺れアニメ=CSS的な揺れのみ、で表現する想定)
- sad でも植物は垂れるだけで、枯れ・縮小・骸骨等の罰表現はしない(後退して見えないよう、
  sad は同段階のシルエットを保つ)

## 3. デザインの約束事

- キャンバス: **16×24 px**、パレット **12色 + 透明**(`tools/gen_sprites.py` の `PALETTE` が正)
- 構図: 全段階で同じテラコッタ鉢(下9px)+ 中央の植物。鉢に顔があり、表情は
  normal(まる目)/ happy(にこにこ目+ほっぺ+口)/ sad(への字口)の3種
- happy 差分 = 表情 + 周囲のキラキラ(十字星)。sad 差分 = 表情 + 葉が垂れる + 汗ひとつぶ
- 拡大は**整数倍 + ニアレストネイバーのみ**(SwiftUI では `.interpolation(.none)`)

## 4. ファイルと生成フロー

```
tools/gen_sprites.py         # 13枚 + 8倍プレビュー + contact_sheet を決定論生成
tools/build_asset_catalog.py # png/ → PlantAssets.xcassets(plant_<name>.imageset)
tools/verify_assets.py       # 枚数・寸法・カタログ整合の自己検証(CI でも実行)
png/<name>.png               # 原寸 16×24(コミットする = 正本)
preview/                     # G2 レビュー用(8倍 + モンタージュ)
PlantAssets.xcassets/        # universal / single scale。Xcode への結線は T13
```

- imageset 名は `plant_soil` `plant_stage1_normal` … `plant_stage5_sad`(計13)
- ios/ には書き込まない。T13 で Xcode プロジェクトからこの xcassets を参照する
