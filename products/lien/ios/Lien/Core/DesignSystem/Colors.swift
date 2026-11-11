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
    /// カレンダー履歴の達成の点(T18)。無彩色の中立表現にする(REVIEW-2026-10-12 §4.2)。
    /// 真っ黒ではなく墨の色(2026-11-11 UI 改修。ほぼ無彩色のまま、紙の上でなじませる)
    static var historyMark: Color { ink }

    // 紙と面(2026-11-11 UI 改修 — Issho の原則の移植)。白い画面をやめ、クリームの紙の上にカードを置く。
    // ダークは、紙の色みを残した暗い土の色(真っ黒にしない)
    /// 画面の地(紙)。#FBF6EA / ダーク #1D1F1B
    static let paper = dynamicColor(
        light: (0.984, 0.965, 0.918, 1),
        dark: (0.114, 0.122, 0.106, 1)
    )
    /// 紙の上のカード。#FFFDF7 / ダーク #282B25
    static let card = dynamicColor(
        light: (1.0, 0.992, 0.969, 1),
        dark: (0.157, 0.169, 0.145, 1)
    )
    /// カードの縁(紙との境い目を、影ではなく細い線で見せる)。#E9E0CB / ダーク #3A3E35
    static let cardBorder = dynamicColor(
        light: (0.914, 0.878, 0.796, 1),
        dark: (0.227, 0.243, 0.208, 1)
    )
    /// 文字の色(真っ黒より柔らかい、深い緑の墨)。#2B3A32 / ダーク #ECEBE3
    static let ink = dynamicColor(
        light: (0.169, 0.227, 0.196, 1),
        dark: (0.925, 0.922, 0.890, 1)
    )
    /// 補足の文字。#7A7466 / ダーク #A7A598(紙の上でも読める濃さ)
    static let inkSecondary = dynamicColor(
        light: (0.478, 0.455, 0.400, 1),
        dark: (0.655, 0.647, 0.596, 1)
    )
    /// 主役のボタンの文字(セージの上の白。ダークは淡いセージの上の深い緑)
    static let onAccent = dynamicColor(
        light: (1, 1, 1, 1),
        dark: (0.114, 0.122, 0.106, 1)
    )
    /// 主役のボタンの「沈み」(下に敷く濃い縁。ぷっくり見せる)。#2C503D / ダーク #6FA587
    static let accentDeep = dynamicColor(
        light: (0.173, 0.314, 0.239, 1),
        dark: (0.435, 0.647, 0.529, 1)
    )
    /// 押せない主役のボタン・控えめなボタンの塗り(淡いセージ)
    static let accentSoft = dynamicColor(
        light: (0.239, 0.420, 0.322, 0.12),
        dark: (0.561, 0.780, 0.659, 0.16)
    )
    /// 「ふたりで◯日」の数字の下に敷く、やわらかい黄の光(シェア画像の shareGlow と同じ色)
    static let highlight = dynamicColor(
        light: (0.969, 0.851, 0.549, 0.55),
        dark: (0.969, 0.851, 0.549, 0.18)
    )
}
