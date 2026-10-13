// WidgetMetrics.swift — ウィジェットの寸法(純粋な計算 / issue #17 T17a)
//
// 大きさの決め方を、見た目のコード(Views/)から切り離して、テストできるようにしたもの。入力は「ウィジェットの内側」の大きさ
// (システムの内側の余白 16pt を除いた、描ける範囲)。実機の大きさの目安(ポイント。余白込み):
//   S:  iPhone SE 141×141 / 標準 158×158 / Pro Max 170×170   M: 292×141 / 338×158 / 364×170
//   ロック画面・円形: 約 76×76(機種で少し違う)
// 植物は 3:4(PlantLayers.canvasAspect)。ここに出る寸法は、そのまま frame に渡せる(植物の絵は、重ねるだけで座標を持たない)。
//
// このファイルは Lien / LienWidget の2ターゲットでソース共有される(project.yml 参照)。Foundation だけに依存させること。

import Foundation

// MARK: - ホーム S

/// ホーム S: 上の段(植物+ストリーク・2人の状態)+ 一言(「(相手)が待ってるよ」)の行 + 細い進み具合のバー
struct WidgetSmallMetrics: Equatable {
    /// 進み具合のバーの太さ
    static let barHeight: CGFloat = 5
    /// 上の段と一言の行・一言の行とバーの間
    static let gap: CGFloat = 6
    /// 植物と右の列の間
    static let columnGap: CGFloat = 8
    /// 植物の幅の上限(内側の幅に対する割合)
    static let plantWidthShare: CGFloat = 0.54
    /// 右の列(ストリーク「🔥 128日」と、2人の絵文字+チェックを並べたもの)に確保する最小の幅。狭い機種(iPhone SE の内側は 109pt)でも
    /// 絵文字が欠けないよう、足りないぶんは植物の幅から削る(これより狭いと、絵文字は縮めて収める — WidgetStatusChip)
    static let minColumnWidth: CGFloat = 46
    /// 一言の行の高さ(.caption2 の1行。出ないときも空けておく — 植物の大きさを状態で変えない)
    static let captionHeight: CGFloat = 14

    /// 上の段の高さ
    let rowHeight: CGFloat
    /// 植物(3:4)
    let plantSize: CGSize
    /// 右の列の幅
    let columnWidth: CGFloat

    init(size: CGSize) {
        let row = max(size.height - Self.barHeight - Self.captionHeight - 2 * Self.gap, 0)
        let maxPlantWidth = max(min(size.width * Self.plantWidthShare, size.width - Self.columnGap - Self.minColumnWidth), 0)
        let plantHeight = min(row, maxPlantWidth / CGFloat(PlantLayers.canvasAspect))
        rowHeight = row
        plantSize = CGSize(width: plantHeight * CGFloat(PlantLayers.canvasAspect), height: plantHeight)
        columnWidth = max(size.width - plantSize.width - Self.columnGap, 0)
    }
}

// MARK: - ホーム M

/// ホーム M: 植物を高さいっぱいに大きく(3:4)+ 右の列(ストリーク・2人の状態・バー・一言)
struct WidgetMediumMetrics: Equatable {
    /// 植物と右の列の間
    static let columnGap: CGFloat = 14

    let plantSize: CGSize
    let columnWidth: CGFloat

    init(size: CGSize) {
        let plantHeight = size.height
        let plantWidth = min(plantHeight * CGFloat(PlantLayers.canvasAspect), size.width)
        plantSize = CGSize(width: plantWidth, height: plantHeight)
        columnWidth = max(size.width - plantWidth - Self.columnGap, 0)
    }
}

// MARK: - ロック画面・円形

/// ロック画面・円形の「相手の葉」を、円のどの範囲で見せるか。葉の絵は他のレイヤーと同じ 240×320 のキャンバスに最終位置で
/// 描いてあるので、葉のある範囲(キャンバス座標。**左右反転したあとの右側の位置**)を決め、その中心が円の中心に来るよう
/// 拡大してずらす。値は、4つのレイヤー(leaf_open / leaf_folded / nub_lit / nub_closed)を実際に描いて測った塗りの範囲に、
/// 少し余白を足したもの(LienTests の WidgetRenderTests が、実描画の塗りがこの範囲に収まることを確かめる)
struct WidgetLeafFocus: Equatable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var midX: Double { (minX + maxX) / 2 }
    var midY: Double { (minY + maxY) / 2 }

    /// 葉(leaf_open / leaf_folded)。茎から先まで: 反転後 x 113.5〜164 / y 79〜148.5(測った値)
    static let leaf = WidgetLeafFocus(minX: 112, minY: 77, maxX: 166, maxY: 150)
    /// 段階0 の芽(nub_lit / nub_closed): 反転後 x 115〜150 / y 101〜142(測った値)
    static let nub = WidgetLeafFocus(minX: 112, minY: 98, maxX: 153, maxY: 145)

    static func focus(for leaf: WidgetContent.PartnerLeaf) -> WidgetLeafFocus {
        leaf.isNub ? .nub : .leaf
    }

    /// 直径 `side` の円に、範囲の長い方が円の `fill` 倍に収まる拡大率(キャンバス1単位あたりの長さ)
    func scale(fittingDiameter side: Double, fill: Double = 0.78) -> Double {
        side * fill / max(width, height)
    }

    /// キャンバス全体(240×320)を拡大したあと、範囲の中心を円の中心に合わせる平行移動量(正 = 右・下)
    func offset(scale: Double) -> (dx: Double, dy: Double) {
        ((PlantLayers.canvasWidth / 2 - midX) * scale, (PlantLayers.canvasHeight / 2 - midY) * scale)
    }
}
