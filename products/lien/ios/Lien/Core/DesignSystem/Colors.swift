// Colors.swift — DesignSystem 最小カラーパレット(T13 / DESIGN §3.8)
//
// 色は View 内に直書きせず、ここに定数として置く。
// 既存画面(Onboarding / Pairing / PromiseSetup)の色使いを踏襲した最小セット。
// 本格的なパレット整備はビジュアル確定(G2)後のタスクで行う。

import SwiftUI
import UIKit

/// ライト / ダークで色を変える。macOS の型検査(scripts/macos-check)では UIKit が無いので、ライトの色に固定する
private func dynamicColor(
    light: (red: Double, green: Double, blue: Double, alpha: Double),
    dark: (red: Double, green: Double, blue: Double, alpha: Double)
) -> Color {
    #if canImport(UIKit)
    return Color(uiColor: UIColor { trait in
        let c = trait.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    })
    #else
    return Color(red: light.red, green: light.green, blue: light.blue, opacity: light.alpha)
    #endif
}

enum LienColors {
    /// ブランドのセージグリーン(Web サイト・シェア画像と同じ色)。ボタンの tint に使う。
    /// アセットカタログの AccentColor と同じ値だが、こちらは **ImageRenderer で描いたときにも効く**
    /// (アセット経由の Color.accentColor は、窓を持たない描画では既定の青に落ちる)
    static let accent = dynamicColor(
        light: (0.239, 0.420, 0.322, 1),
        dark: (0.561, 0.780, 0.659, 1)
    )
    /// 完了状態のチェック・植物のアクセント。accent と同じ色(意味で分けて名前を置く)
    static let done = accent
    /// 未完了状態(自分未完 = グレー — REQUIREMENTS §3.10)
    static let pending = Color.gray
    /// エラー文言(責めないトーンの暖色 — 既存画面の .orange を踏襲)
    static let gentleAlert = Color.orange
    /// 今日の状態チップの背景
    static let chipBackground = Color(uiColor: .secondarySystemBackground)
    /// 今日の状態チップの背景(完了側)。チップ全体を薄くせずに、完了/未完を見分けるための淡い緑
    static let chipDoneBackground = dynamicColor(
        light: (0.239, 0.420, 0.322, 0.10),
        dark: (0.561, 0.780, 0.659, 0.16)
    )
    /// 相手の写真を全画面で見るときの背景(写真の周りを暗くする)
    static let photoBackdrop = Color.black
    /// 全画面の写真に重ねる操作(閉じるボタン・読み込み中の表示)の色
    static let photoControl = Color.white
    /// 植物の全画面の演出(段階アップ・おかえり — PB #57)の背景。ライト / ダークの標準の背景(プレートが暗い背景でも輪郭を見せる)
    static let celebrationBackground = Color(uiColor: .systemBackground)

    // シェア画像(T22)。端末のライト / ダークに関係なく、いつも同じ色で書き出す(共有先で見え方が変わらないように)
    /// 背景の上(クリーム)
    static let shareBackgroundTop = Color(red: 0.984, green: 0.969, blue: 0.925)
    /// 背景の下(若草)
    static let shareBackgroundBottom = Color(red: 0.894, green: 0.945, blue: 0.871)
    /// 文字の濃い緑
    static let shareInk = Color(red: 0.169, green: 0.227, blue: 0.196)
    /// 見出し・アプリ名の緑
    static let shareAccent = Color(red: 0.239, green: 0.420, blue: 0.322)
    /// 背景にぼかして置く光(やわらかい黄)
    static let shareGlow = Color(red: 0.969, green: 0.851, blue: 0.549)
    /// カレンダー履歴の達成の点(T18)。無彩色の中立表現にする(REVIEW-2026-10-12 §4.2)
    static let historyMark = Color.primary
}
