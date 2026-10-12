# 植物キャラクター「タネの子」— SVG レイヤーの規則(重ね順・状態対応・のぞき・左右反転)

- 状態: **取込済み(2026-10-13、issue #56)**。v4「タネの子」(D1 で採用)の SVG レイヤー34点を、`svg/` と `PlantAssets.xcassets` に取り込んだ。旧ドット絵(16×24px・13枚)・`gen_sprites.py`・`png/`・`preview/` は廃止した
- **このファイルが、レイヤー名・重ね順・状態との対応・のぞきの位置・左右反転・ダークモードの正本**(承認前の下書き `v4_drafts/README.md` から移した。下書きのフォルダは承認時点の記録で、更新しない)
- 成長ルール: [docs/GROWTH.md](../../../../docs/GROWTH.md) §4・§9 / 仕様: [docs/REQUIREMENTS.md](../../../../docs/REQUIREMENTS.md) §3.9 / iOS の実装: `ios/Lien/Core/DesignSystem/PlantLayers.swift`・`PlantCharacterView.swift`
- 確定後の変更は、**レイヤー名を変えない範囲**に限る(GROWTH.md §9.5)。名前を変える・足す・減らすときは、このファイルと `tools/verify_assets.py` の期待一覧、`PlantLayers.swift` をそろえて直す

## 1. ファイルと生成のフロー

```
tools/gen_v4.py            部品ライブラリ(パレット・体・顔・鉢・葉・花の描画関数)。単体では実行しない
tools/gen_layers.py        レイヤー SVG の生成と検査(決定論・標準ライブラリだけ)。重ね順の実装 stack() もここ
tools/svg_geom.py          塗りを走査する小さな幾何ライブラリ(左右の花の塗りの重なり検査。Chrome も Pillow も不要)
tools/build_asset_catalog.py   svg/ → PlantAssets.xcassets
tools/verify_assets.py     自己検証(CI でも実行)
tools/test_plant_tools.py  上記の単体テスト(CI でも実行)
svg/<レイヤー名>.svg        ★生成物・コミットする(34点)。カタログの元
PlantAssets.xcassets/      ★生成物・コミットする。plant_<レイヤー名>.imageset が34個。Xcode からは project.yml が参照する
peek_offsets.json          ★生成物。のぞき(fx_peek)の平行移動量(段階ごと)
layer_stacks.json          ★生成物。重ね順の基準(状態 → レイヤー名の並び)。iOS の PlantLayersTests が読む
v2_drafts/ v3_drafts/ v4_drafts/   下書きの記録(履歴。更新しない)
```

```bash
python3 tools/gen_layers.py             # svg/・peek_offsets.json・layer_stacks.json を書き出す(検査つき)
python3 tools/build_asset_catalog.py    # PlantAssets.xcassets を作り直す
python3 tools/verify_assets.py          # 検証
python3 -m unittest discover -s tools -p 'test_*.py'
python3 tools/gen_layers.py --previews  # ローカル用: 合成プレビュー(PNG の一覧)を _preview/ に出す(Chrome と Pillow が要る。git には入れない)
```

- **CI(lien-ci の plant-assets ジョブ)**: 再生成して `git diff --exit-code`(コミット済みの生成物と一字一句同じ)→ verify → 単体テスト → Contents.json の数(ルート1 + imageset 34 = 35)。SVG・カタログ・JSON は**同じコミットで直す**
- 決定論: 三角関数・べき乗の結果は 1e-10 に丸め、符号つきのゼロは `0` にそろえてある。ubuntu(CI)と macOS(ローカル)・Python 3.9 と 3.12 で同じ出力になる(`test_plant_tools.py` が ±1ulp の揺れでも変わらないことを確かめる)
- 生成時と verify の機械チェック
  - 使う SVG 要素は **path・基本図形・linearGradient / radialGradient・opacity・transform のみ**。filter・mask・clipPath・text・style・use・image・stop-opacity・外部参照は使わない(iOS の SVG 描画で崩れるのを避けるため)
  - 全レイヤーが XML として妥当で、`viewBox="0 0 240 320"`(width / height も 240 / 320)
  - 光(芽・土・のぞき・ハートのタネ)は stop-opacity を使わず、不透明度の低い同心円を重ねて描く
  - **左右の花の塗り(`petal_sN` とその左右反転)が1画素も重ならない**(塗りと線を別レイヤーにしても輪郭が透けない条件)
  - 花の塗り(`petal_sN`)は既定の花色 `#FFB3C7` の単色

## 2. キャンバスと約束

- 全レイヤーは同じ `viewBox="0 0 240 320"`(**3:4**)に**最終位置で描いてある**。iOS は重ねるだけで、座標を持たない。体・顔・鉢・ふたりの葉は全段階で同じ位置・同じ大きさ
- 例外は3つだけ
  1. **右の葉・右の芽・右の花の塗り** = 左のレイヤー(`leaf_*` / `nub_*` / `petal_sN`)を **x=120 で左右反転**して使う。花の塗りを左右別に持つので、v1.1 で2人が別々の花の色を選べる
  2. **のぞき(`fx_peek`)** = 中心 (120, 160) に描いてあり、段階ごとに §6 の表の分だけ平行移動する
  3. **`bg_plate`** = ダークモードのときだけ最背面に敷く
- 自分の画面では、いつも**左が自分・右が相手**(GROWTH.md §4.5)
- 鉢のふちの寸法(y=222〜246、x=44〜196)は手・寝顔・土の光が依存するので固定。v1.1 の鉢の着せ替えは `pot_back` / `pot_front` の2枚を差し替える

## 3. レイヤー(34点)

imageset 名は **`plant_` + レイヤー名**(例: `plant_pot_back`)。iOS の `PlantLayers.assetPrefix` と一致させる。

| 種類 | レイヤー | 点数 |
|---|---|---|
| 鉢 | `pot_back`(地面の影+鉢の口の土)/ `pot_front`(ふち+本体) | 2 |
| 体 | `body` / `hands_rim`(ふちに掛けた手)/ `arms_up`(喜びのミトン型の腕)/ `solo_seed`(ソロ: 土の中で眠る。顔込み) | 4 |
| 顔 | `face_normal` / `face_happy` / `face_look_l`(ひらいた自分の葉を見る)/ `face_look_r`(ひらいた相手の葉を見る)/ `face_sleep`(すやすや)/ `face_wow`(段階アップ・はじめまして・おかえり) | 6 |
| ふたりの葉 | `nub_closed`(段階0: 閉じた芽)/ `nub_lit`(段階0: 背が伸びて先がひらき光る — 形でも区別)/ `leaf_open` / `leaf_folded`(段階1〜9共通) | 4 |
| 頭の植物 | `head_s2`〜`head_s9`(段階ごとに1枚。茎・葉・つぼみ・花の線と陰影。左右両方を含む) | 8 |
| 花の塗り | `petal_s6`〜`petal_s9`(**左の花だけ**・単色 `#FFB3C7`) | 4 |
| 背面 | `bg_plate`(ダークモード用のクリーム色プレート) | 1 |
| 効果 | `fx_sparkle` / `fx_zzz` / `fx_celebrate` / `fx_soil_glow` / `fx_peek` | 5 |
| **合計** | | **34** |

## 4. 重ね順(下から。これを正とする)

| 順 | 通常 | ソロ |
|---|---|---|
| 0 | `bg_plate`(ダークモードのみ) | `bg_plate`(ダークモードのみ) |
| 1 | `pot_back` | `pot_back` |
| 2 | 左: `leaf_open` か `leaf_folded`(段階0は `nub_lit` か `nub_closed`) | `fx_soil_glow`(自分がチェックインしたとき) |
| 3 | 右: 同上を**左右反転** | `solo_seed` |
| 4 | `petal_sN`(自分の花の色)→ `petal_sN` を**左右反転**(相手の花の色)。段階6〜9のみ | `pot_front` |
| 5 | `head_sN`(段階2以上) | `fx_zzz` |
| 6 | `arms_up`(顔が happy / wow のとき) | |
| 7 | `body` | |
| 8 | `face_*` | |
| 9 | `pot_front` | |
| 10 | `hands_rim`(顔が happy / wow 以外のとき) | |
| 11 | `fx_peek`(のぞき。平行移動して)→ `fx_*`(顔と対の効果) | |

- 頭の植物を**ふたりの葉より上**に置く(たたんだ葉が段階2〜4の植物を隠さない)。どちらも体の背後(頭から生えて見える)
- ソロは段階に関係なく同じ絵(段階の入力は無視する)。`fx_zzz` は常に出る(土の中で眠っている)
- 顔と対の効果: `face_happy` → `fx_sparkle` / `face_sleep` → `fx_zzz` / `face_wow` → `fx_celebrate`。ほかの顔には効果が付かない
- 段階が 0〜9 の範囲外のとき、iOS は**知っている最大の段階(9)として描く**(古いアプリがサーバーの新しい段階を受け取っても壊れない。負は 0)
- この表は `tools/gen_layers.py` の `stack()` と `ios/.../PlantLayers.swift` の両方が実装していて、`layer_stacks.json`(全段階 × 葉の4通り × 顔6種ほか)で一致を確かめる

## 5. 状態との対応(GROWTH.md §4.1)

| 今日の状態 | 左の葉(自分) | 右の葉(相手) | 顔 | 効果 | 使う snapshot の値 |
|---|---|---|---|---|---|
| ふたりともまだ(朝の既定) | folded | folded | `face_normal` | — | 両方 false(normal) |
| 自分だけ完了 | open | folded | `face_look_l` | — | todayMeDone のみ true(fidget) |
| 相手だけ完了 | folded | open | `face_look_r` | — | todayPartnerDone のみ true(fidget) |
| ふたりそろった | open | open | `face_happy` | `fx_sparkle` | 両方 true(happy) |
| すやすや(API の `sad`) | folded | folded | `face_sleep` | `fx_zzz` | plantMood が sad で、どちらも未完 |
| 段階アップの演出 | open | open | `face_wow` | `fx_celebrate` | アプリ側の演出(PB。snapshot の値ではない) |
| ソロ(ペア未成立) | — | — | 土の中で眠る(`solo_seed`) | 常に `fx_zzz`。自分がチェックインすると `fx_soil_glow` | pairId が null |
| 段階0(たね) | 芽(`nub_closed` / 光る `nub_lit`) | 同左 | 上の行と同じ | — | plantStage が 0 |

- **葉は完了のフラグから決める**(サーバーの `derivePlantMood` と同じ規則)。楽観更新で mood が古いまま `todayMeDone` が立った瞬間にも、自分の葉がすぐにひらく。`sad` が効くのは「どちらも未完」のときだけ
- 葉をたたむのは、眠っているだけの元気な形: **色(`#82C95C`)と長さ(44)はひらいた葉と同じで、形だけが違う**(2つ折りのふっくらした形。見える緑の面積はひらいた葉より小さい)。しおれない・垂れない・茶色くならない
- **ひらく / たたむの切り替えは、クロスフェードにしない**(形の違う2枚が二重に見えるため)。単純な差し替え、または回転・拡大縮小で見せる。`PlantCharacterView` は状態の変化にアニメーションを掛けない

## 6. のぞきの位置(`peek_offsets.json`)— 次の段階で何かが出てくる場所

`fx_peek` は中心 (120, 160) に描いてあり、下の量だけ平行移動して重ねる(キャンバス座標。iOS は表示幅 ÷ 240 を掛ける)。

| 段階 | 位置(キャンバス) | dx | dy | 意味 |
|---|---|---|---|---|
| s3 わかば | (120, 76) | 0 | −84 | 2本の茎の間 |
| s4 よりそい | (120, 34) | 0 | −126 | 触れ合う先端の上 |
| s5〜s7 | (120, 52) | 0 | −108 | 2つのつぼみの間 |
| s8 ふたりざき | (120, 76) | 0 | −84 | みのりでハートのタネが出る場所 |

- 位置が無い段階(0〜2、9)では、のぞきを指定されても出さない
- いつ出すか(進み具合が半分を超えたら)は PB(GROWTH.md §3.4。P1)が決める。PA の描画は「出す / 出さない」の入力を受けるだけ

## 7. 花の色(着色はコード側)

- `petal_sN` は**左の花だけ**・単色 `#FFB3C7`(v1.0 の既定の花色)。アセットは**元の色のまま**入れ(template にしない)、iOS のコード側で `Image.renderingMode(.template)` + foregroundStyle で着色する。着色し忘れても黒くならない
- 左のレイヤーに**自分の色**、それを左右反転したものに**相手の色**を重ねる(v1.0 は両方とも既定色。v1.1 で各自が自分の側の色を選ぶ)
- 花芯は琥珀色 `#F6A94E` で `head_sN` 側に描いてある(どの花色とも見分けられる)

## 8. ダークモード

- 暗い背景では、こげ茶の輪郭が沈む。**最背面に `bg_plate`(クリーム色の角丸プレート)を敷く方式**に決定した(下書き `v4_drafts/preview_dark.png`)
- iOS は `@Environment(\.colorScheme)` が `.dark` のときだけ `bg_plate` を重ねる(ウィジェットも同じ)
- 色: 輪郭 `#4A3428` / 葉 `#82C95C` / 鉢 `#E6895C` / 土 `#7E5539` / プレート `#FFF7EA`(パレットは `tools/gen_v4.py`)

## 9. iOS 側の対応

| ファイル | 役割 |
|---|---|
| `ios/Lien/Core/DesignSystem/PlantLayers.swift` | 状態(段階・自分と相手の完了・表情・ソロ・のぞき・ダーク)→ 重ねるレイヤーの並びを返す純粋関数。snapshot からの状態の導出(§5)もここ。Foundation だけに依存(ウィジェットとシェア画像でも使う) |
| `ios/Lien/Core/DesignSystem/PlantCharacterView.swift` | ZStack で全レイヤーを同じキャンバスに重ねる。右は x 方向反転・花は着色・のぞきは offset・3:4 を保つ。SwiftUI と Foundation だけ |
| `ios/LienTests/PlantLayersTests.swift` | 全段階 × 葉の4通り × 表情・ソロ・ダーク・知らない段階。`layer_stacks.json`・`peek_offsets.json` との突き合わせ。カタログに34点が実在することも確かめる |
| `ios/LienTests/PlantRenderTests.swift` | ImageRenderer で全組み合わせの一覧画像を描き、XCTAttachment で保存する。lien-ios が xcresult から PNG を取り出して artifact(`plant-render-sheets`)にする |

- ウィジェット(LienWidget)も同じ `PlantAssets.xcassets` と上の2ファイルをソース共有する(project.yml)
- **ウィジェットのメモリ**: S サイズで1レイヤーあたり約1MB・10枚前後が目安(GROWTH.md §9.5)。収まらないときの代わりの案は、ウィジェット用だけ「段階 × 葉の状態」をあらかじめ1枚に合成した画像を持つこと(T17a で実機確認)
- ウィジェットの「色合い(accented)」表示では画像が単色に変わる。T17a で `widgetAccentedRenderingMode(.fullColor)` を各 Image に付ける(PlantCharacterView は WidgetKit に依存させない)

## 10. 受け入れ基準(GROWTH.md §9.5)の状態

| # | 基準 | 状態 |
|---|---|---|
| 1〜8 | 40pt で段階を見分けられる / 段階0と段階1の朝 / たたんだ葉 / 顔 / 2本・2つ・2輪 / 汗・涙なし / ダーク / 形での区別 | 下書き(`v4_drafts/README.md`)で自己チェック済み。**iOS で実際に描いた一覧画像(CI の artifact `plant-render-sheets`)で承認をもらう** |
| 9 | 許可した SVG の要素だけ | CI で自動チェック(`tools/verify_assets.py`) |
| 10 | iOS の描画と下書きのプレビューに目立つ差がない | CI の実描画一覧で確認。重ね順は `layer_stacks.json` で機械的に一致を確かめる |
