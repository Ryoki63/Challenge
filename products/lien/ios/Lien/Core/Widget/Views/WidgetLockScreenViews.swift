// WidgetLockScreenViews.swift — ロック画面のウィジェット2種(issue #17 T17a / REQUIREMENTS §3.10・GROWTH §5.4)
//
//   円形(accessoryCircular): 相手の今日の状態 = 相手(右)の葉の開閉。ひらいている = 相手が今日チェックイン済み。
//     たたんでいる = まだ(眠っているだけ。薄く出す)。段階0 は葉の代わりに芽(光る / 閉じている)。
//     v1.0.1 で、進み具合のリングにして中央に葉を置く(GROWTH §5.4)。ソロ・データ無しは眠るタネの子
//   インライン(accessoryInline): ストリーク「🔥 23日」(SF Symbols の炎+日数)。ストリークが無いときはアプリ名
//
// ロック画面は、システムが全体を白系の単色(vibrant)に変換して描く。そこで**形で区別できる**ようにしてある
// (葉のひらく / たたむは色でなく形で見分けられる — GROWTH §9.5 の基準8)。円形の背景(AccessoryWidgetBackground)は、
// このビューには含めず、LienWidget が足す(テストの一覧画像では近似の円を敷く)。
// 眠るタネの子はダークモードの背面プレートを敷かない(単色化したときに、プレートが絵を塗りつぶすため。常にライトで描く)。

import SwiftUI
import WidgetKit

// MARK: - 円形

struct WidgetLockCircularView: View {
    let content: WidgetContent
    var imageStyle: PlantImageStyle = .plain

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                if let leaf = content.partnerLeaf {
                    WidgetPartnerLeafView(leaf: leaf, diameter: side)
                } else {
                    // ソロ・データ無し: 眠るタネの子(鉢+土の中の寝顔+zzz)
                    PlantCharacterView(state: content.plant, imageStyle: imageStyle)
                        .environment(\.colorScheme, .light)
                        .frame(height: side * 0.84)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// 相手(右)の葉だけを、円の中に大きく出す。葉の絵は他のレイヤーと同じ 240×320 のキャンバスに最終位置で描いてあるので、
/// キャンバス全体を拡大し、葉のある範囲(WidgetLeafFocus)の中心が円の中心に来るようにずらして、円で切り抜く
struct WidgetPartnerLeafView: View {
    let leaf: WidgetContent.PartnerLeaf
    /// 円の直径
    let diameter: CGFloat

    /// たたんだ葉(まだ)の濃さ。形でも区別できる(小さく・縦長に折れている)上で、少し落とす(罰ではなく、眠っているだけ)
    static let foldedOpacity = 0.55

    var body: some View {
        let focus = WidgetLeafFocus.focus(for: leaf)
        let scale = focus.scale(fittingDiameter: Double(diameter))
        let shift = focus.offset(scale: scale)
        WidgetImageStyle.fullColor(
            Image(PlantLayers.assetPrefix + leaf.layerName).renderingMode(.original).resizable()
        )
        .frame(width: CGFloat(PlantLayers.canvasWidth * scale), height: CGFloat(PlantLayers.canvasHeight * scale))
        // 絵は左のレイヤー。x=120 で左右反転して、相手(右)の葉にする(PlantCharacterView の layer.mirrored と同じ)
        .scaleEffect(x: -1, y: 1)
        .offset(x: CGFloat(shift.dx), y: CGFloat(shift.dy))
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .opacity(leaf.isOpen ? 1 : Self.foldedOpacity)
    }
}

// MARK: - インライン

struct WidgetLockInlineView: View {
    let content: WidgetContent

    var body: some View {
        if let text = content.inlineStreakText {
            Label(text, systemImage: "flame.fill")
        } else {
            Label(Strings.Widget.displayName, systemImage: "leaf.fill")
        }
    }
}
