// Spacing.swift — DesignSystem 最小余白スケール(T13 / DESIGN §3.8)
//
// 余白は View 内に直書きせず、この4pt グリッドの定数を使う。

import CoreGraphics

enum LienSpacing {
    /// 4pt — 行内の微小間隔
    static let xs: CGFloat = 4
    /// 8pt — 要素間の標準間隔
    static let s: CGFloat = 8
    /// 16pt — セクション内ブロック間隔
    static let m: CGFloat = 16
    /// 24pt — セクション間・画面端パディング
    static let l: CGFloat = 24
    /// 32pt — 大きな区切り
    static let xl: CGFloat = 32
}

/// 角の丸み(2026-11-11 UI 改修)。カード・ボタンの丸みを、画面をまたいでそろえる
enum LienRadius {
    /// 小さな部品(チップ・小さなボタン)
    static let s: CGFloat = 12
    /// カード
    static let card: CGFloat = 22
    /// 主役のボタン(高さの半分に近い、ぷっくりした丸み)
    static let button: CGFloat = 26
}
