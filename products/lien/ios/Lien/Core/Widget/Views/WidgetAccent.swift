// WidgetAccent.swift — 「色合い(accented)」表示でも、植物が単色にならないようにする(issue #17 T17a)
//
// iOS 18 のホーム画面には、ウィジェットを1色に染める「色合い(accented)」表示がある。そのとき画像は、何もしないと
// 脱色されて単色になる(Image の widgetAccentedRenderingMode の既定)。植物は、葉の開閉・顔・花の色が絵で伝わるものなので、
// 各レイヤーの Image に widgetAccentedRenderingMode(.fullColor) を付けて、色を保つ(assets/plant/mapping.md §9)。
//
// PlantCharacterView は、シェア画像・アプリ本体でも使うので WidgetKit に依存させない。そこで Image に付ける装飾を
// PlantImageStyle として外から渡す。**ウィジェットが PlantCharacterView を作るときは、必ず imageStyle: .widgetFullColor を渡す**
// (WidgetSourceTests が、Widget/Views の中の PlantCharacterView(...) を1つずつ確かめる)。
// widgetAccentedRenderingMode は iOS 18 以降(最小は iOS 17 なので #available)。それより前では何もしない。
// 色合い表示そのものの見え方(花の着色・背面プレート・文字の色)は、実機でしか確かめられない(T20 の確認項目)。

import SwiftUI
import WidgetKit

extension PlantImageStyle {
    /// ウィジェット用: 各レイヤーの Image に widgetAccentedRenderingMode(.fullColor) を付ける
    static let widgetFullColor = PlantImageStyle { image in
        WidgetImageStyle.fullColor(image)
    }
}

enum WidgetImageStyle {
    /// Image を、色合い(accented)表示でも色を保つようにする(iOS 18 以降)。植物の葉の絵など、ウィジェットの Image はすべてこれを通す
    static func fullColor(_ image: Image) -> AnyView {
        if #available(iOS 18.0, macOS 15.0, *) {
            return AnyView(image.widgetAccentedRenderingMode(.fullColor))
        }
        return AnyView(image)
    }
}
