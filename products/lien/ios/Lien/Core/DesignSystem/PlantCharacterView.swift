// PlantCharacterView.swift — 植物キャラクター「タネの子」の描画(SVG レイヤーの重ね合わせ / issue #56)
//
// PlantLayers.stack が返すレイヤーを、同じ 240×320 のキャンバス(3:4)に ZStack で重ねる。
// 旧ドット絵の PlantSprite / PixelImage(16×24 固定・interpolation(.none))の置き換え。
//
//   - 絵はベクター(PlantAssets.xcassets の SVG。preserves-vector-representation)なので、どんな大きさでも鮮明に拡大できる
//   - 右の葉・右の芽・右の花の塗りは、左のレイヤーを x 方向に反転して重ねる(layer.mirrored)
//   - 花の塗り(petal_sN)はアセットが元の色(既定の花色 #FFB3C7)のまま入っていて、template にして
//     自分の色(左)と相手の色(右)で着色する。v1.0 は両方とも既定色、v1.1 で各自が選べる
//   - のぞき(fx_peek)は、キャンバス座標の平行移動量 × (表示幅 ÷ 240) だけずらす
//   - ダークモードのときだけ、最背面に bg_plate を敷く(こげ茶の輪郭が暗い背景に沈まないように)
//   - **状態が変わっても、アニメーションは掛けない**。葉のひらく / たたむを自動でクロスフェードすると、
//     形の違う2枚が二重に見えるため(assets/plant/mapping.md §5)。変えたいときは回転・拡大縮小か、単純な差し替えにする
//
// このファイルは Lien / LienWidget の2ターゲットでソース共有される(project.yml 参照)。
// SwiftUI と Foundation 以外に依存させないこと(WidgetKit の API はウィジェット側で付ける)。
// 植物は装飾画像として扱う(accessibilityText が nil なら VoiceOver から隠す。意味は周囲のテキストで伝える)。

import SwiftUI

struct PlantCharacterView: View {
    let state: PlantCharacterState
    /// 自分の花(左)の色。v1.0 は既定色
    var meFlowerColor: Color = PlantCharacterView.defaultFlowerColor
    /// 相手の花(右)の色。v1.0 は既定色
    var partnerFlowerColor: Color = PlantCharacterView.defaultFlowerColor
    /// VoiceOver で読み上げる文。nil なら装飾画像として隠す
    var accessibilityText: String?

    @Environment(\.colorScheme) private var colorScheme

    /// v1.0 の既定の花色 #FFB3C7(SVG の petal_sN と同じ — PlantLayers.defaultPetalRGB)
    static let defaultFlowerColor = Color(rgb: PlantLayers.defaultPetalRGB)

    var body: some View {
        GeometryReader { proxy in
            // キャンバス座標(240 幅)→ 画面の長さ
            let unit = proxy.size.width / CGFloat(PlantLayers.canvasWidth)
            ZStack {
                ForEach(PlantLayers.stack(for: state, dark: colorScheme == .dark)) { layer in
                    layerImage(layer)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(x: layer.mirrored ? -1 : 1, y: 1)
                        .offset(x: CGFloat(layer.dx) * unit, y: CGFloat(layer.dy) * unit)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(CGFloat(PlantLayers.canvasAspect), contentMode: .fit)
        .animation(nil, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? "")
        .accessibilityHidden(accessibilityText == nil)
    }

    /// レイヤー1枚。花の塗りだけ template にして着色し、ほかは元の色のまま(template にしない)
    @ViewBuilder
    private func layerImage(_ layer: PlantLayer) -> some View {
        if let tint = layer.tint {
            Image(layer.assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint == .me ? meFlowerColor : partnerFlowerColor)
        } else {
            Image(layer.assetName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        }
    }
}

private extension Color {
    /// 0xRRGGBB から sRGB の色を作る
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }
}
