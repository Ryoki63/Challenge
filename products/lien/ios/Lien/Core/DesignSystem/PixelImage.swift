// PixelImage.swift — ドット絵の整数倍拡大ヘルパ(T13 / DESIGN §3.5)
//
// ドット絵は必ず `Image(...).resizable().interpolation(.none)` で**整数倍拡大**する(にじみ禁止)。
// 倍率は Int で受け取り、非整数倍のスケーリングを型レベルで防ぐ。

import SwiftUI

/// アセットカタログのドット絵を整数倍・ニアレストネイバーで表示する。
/// 原寸の既定値は植物スプライトの 16×24(PlantSprite が正本)
struct PixelImage: View {
    let assetName: String
    /// 整数倍率(1 = 原寸)
    var scale: Int = 1
    /// 原寸ピクセルサイズ(既定: 植物スプライト 16×24)
    var pixelWidth: Int = PlantSprite.pixelWidth
    var pixelHeight: Int = PlantSprite.pixelHeight

    var body: some View {
        Image(assetName)
            .resizable()
            .interpolation(.none) // ニアレストネイバー(にじみ禁止 — DESIGN §3.5)
            .frame(
                width: CGFloat(pixelWidth * scale),
                height: CGFloat(pixelHeight * scale)
            )
            .accessibilityHidden(true) // 装飾画像。意味はテキスト側で伝える
    }
}
