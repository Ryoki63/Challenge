# iOS 実描画の一覧画像(CI artifact の保存)

- 出どころ: lien-ios run 38296318464(commit 696a41f、#56 完了時)の artifact `plant-render-sheets`。SwiftUI の PlantCharacterView を ImageRenderer で描いたもの(シミュレータ iOS 26.5)
- 目的: GROWTH.md §9.5 の受け入れ基準10(iOS で描いた結果とプレビューの差がない)の証跡。artifact は 2026-11-11 に消えるためリポジトリに保存した
- 最新の画像は lien-ios の各 run の artifact から取れる: `gh run download <run-id> --repo Ryoki63/Challenge -n plant-render-sheets`

| ファイル | 内容 |
|---|---|
| plant_00_check_morning_strip.png | 朝の既定状態(葉を閉じる)の全段階 |
| plant_01_states_light.png / plant_02_states_dark.png | 全段階 × 今日の状態(ライト / ダーク) |
| plant_03_sizes_light.png / plant_04_sizes_dark.png | 40 / 60 / 80pt |
| plant_05_expressions_light.png / plant_06_expressions_dark.png | 表情6種 |
| plant_07_flower_colors.png | 花の色(自分 × 相手で別の色) |
