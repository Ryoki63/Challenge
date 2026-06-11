// Colors.swift — DesignSystem 最小カラーパレット(T13 / DESIGN §3.8)
//
// 色は View 内に直書きせず、ここに定数として置く。
// 既存画面(Onboarding / Pairing / PromiseSetup)の色使いを踏襲した最小セット。
// 本格的なパレット整備はビジュアル確定(G2)後のタスクで行う。

import SwiftUI
import UIKit

enum LienColors {
    /// 完了状態のチェック・植物のアクセント
    static let done = Color.green
    /// 未完了状態(自分未完 = グレー — REQUIREMENTS §3.10)
    static let pending = Color.gray
    /// エラー文言(責めないトーンの暖色 — 既存画面の .orange を踏襲)
    static let gentleAlert = Color.orange
    /// 今日の状態チップの背景
    static let chipBackground = Color(uiColor: .secondarySystemBackground)
}
