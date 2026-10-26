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
//   - 葉の下の約束の絵文字は**出さない**(2026-10-26 オーナー判断で、約束の絵文字は UI から廃止)。
//     誰の葉か(左 = 自分・右 = 相手)は、葉の位置と開閉、ホームの文(約束のタイトル・名前)で伝わる
//   - 小さな揺れ(片方だけ完了のそわそわ): 鉢の底を支点に、**プレート以外**の絵を回す。
//     ダークモードのプレートまで回ると、背景の四角が一緒に傾いてしまう(PA の手直し — #57)
//   - 各レイヤーの Image に付ける装飾 imageStyle(T17a #17): ウィジェットが、iOS 18 の「色合い(accented)」表示でも植物が単色に
//     ならないよう widgetAccentedRenderingMode(.fullColor) を付けるのに使う。WidgetKit の API はここには持ち込まず、
//     描き手(ウィジェット。Lien/Core/Widget/Views/WidgetAccent.swift)が注入する。既定は何もしない
//
// このファイルは Lien / LienWidget の2ターゲットでソース共有される(project.yml 参照)。
// SwiftUI と Foundation 以外に依存させないこと(WidgetKit の API はウィジェット側で付ける)。
// 植物は装飾画像として扱う(accessibilityText が nil なら VoiceOver から隠す。意味は周囲のテキストで伝える)。

import SwiftUI

/// 各レイヤーの Image(`.resizable()` まで済ませたもの)に、描き手が付ける装飾。
/// 例: ウィジェットは widgetAccentedRenderingMode(.fullColor) を付けて、色合い(accented)表示でも色を保つ。
/// Image にしか付けられない API(Image のメソッド)のために、Image の段階で渡す
struct PlantImageStyle: Sendable {
    let apply: @Sendable (Image) -> AnyView

    /// 何もしない(アプリ本体・シェア画像)
    static let plain = PlantImageStyle { AnyView($0) }
}

struct PlantCharacterView: View {
    let state: PlantCharacterState
    /// 自分の花(左)の色。v1.0 は既定色
    var meFlowerColor: Color = PlantCharacterView.defaultFlowerColor
    /// 相手の花(右)の色。v1.0 は既定色
    var partnerFlowerColor: Color = PlantCharacterView.defaultFlowerColor
    /// 小さな揺れの角度(度)。鉢の底を支点に、プレート以外を回す。0 なら揺れない
    var swayDegrees: Double = 0
    /// VoiceOver で読み上げる文。nil なら装飾画像として隠す
    var accessibilityText: String?
    /// 各レイヤーの Image に付ける装飾(ウィジェットの色合い表示への対策 — PlantImageStyle)。既定は何もしない
    var imageStyle: PlantImageStyle = .plain

    @Environment(\.colorScheme) private var colorScheme

    /// v1.0 の既定の花色 #FFB3C7(SVG の petal_sN と同じ — PlantLayers.defaultPetalRGB)
    static let defaultFlowerColor = Color(rgb: PlantLayers.defaultPetalRGB)

    var body: some View {
        GeometryReader { proxy in
            // キャンバス座標(240 幅)→ 画面の長さ
            let unit = proxy.size.width / CGFloat(PlantLayers.canvasWidth)
            let layers = PlantLayers.stack(for: state, dark: colorScheme == .dark)
            ZStack {
                // 背面のプレートは揺らさない
                ForEach(layers.filter { $0.slot == .backPlate }) { layer in
                    layerView(layer, size: proxy.size, unit: unit)
                }
                ZStack {
                    ForEach(layers.filter { $0.slot != .backPlate }) { layer in
                        layerView(layer, size: proxy.size, unit: unit)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .rotationEffect(.degrees(swayDegrees), anchor: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(CGFloat(PlantLayers.canvasAspect), contentMode: .fit)
        .animation(nil, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? "")
        .accessibilityHidden(accessibilityText == nil)
    }

    /// レイヤー1枚(同じ大きさの枠に重ね、右は反転し、のぞきはずらす)
    private func layerView(_ layer: PlantLayer, size: CGSize, unit: CGFloat) -> some View {
        layerImage(layer)
            .frame(width: size.width, height: size.height)
            .scaleEffect(x: layer.mirrored ? -1 : 1, y: 1)
            .offset(x: CGFloat(layer.dx) * unit, y: CGFloat(layer.dy) * unit)
    }

    /// 花の塗りだけ template にして着色し、ほかは元の色のまま(template にしない)
    @ViewBuilder
    private func layerImage(_ layer: PlantLayer) -> some View {
        if let tint = layer.tint {
            imageStyle.apply(Image(layer.assetName).renderingMode(.template).resizable())
                .scaledToFit()
                .foregroundStyle(tint == .me ? meFlowerColor : partnerFlowerColor)
        } else {
            imageStyle.apply(Image(layer.assetName).renderingMode(.original).resizable())
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
