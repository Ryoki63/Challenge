// Typography.swift — DesignSystem の書体(2026-11-11 UI 改修 / DESIGN §3.8)
//
// アプリ・ウィジェット・シェア画像の文字を、丸ゴシック(Zen Maru Gothic。SIL OFL 1.1)の1書体にそろえる。
// 「どの画面も同じ声で話している」ことが、キャラクター以外の場所にも温度を出す(Issho の分析 — JOURNAL 2026-11-11)。
//
// - 書体のファイルは ../assets/fonts/ZenMaruGothic/(Medium と Bold の2つだけ。OFL.txt も同梱する)。
//   登録は Info.plist の UIAppFonts(project.yml。アプリ本体とウィジェットの両方)
// - 大きさは iOS の文字スタイル(.body・.footnote など)と同じ。`relativeTo:` で、文字を大きくする設定に連れて広がる
// - 書体が読めない環境(macOS の下見・登録漏れ)では、SwiftUI がシステムの書体で描く(落ちない)。
//   登録できているかは FontRegistrationTests が確かめる
// - View では `.font(.lien(.footnote))` のように使う。`.font(.footnote)` のようなシステムの書体を直書きしない
//   (コード・数字の桁をそろえたい招待コードなど、等幅が要る所だけは例外)

import SwiftUI

enum LienTypeface {
    /// 本文・ラベル(Medium)の PostScript 名
    static let regular = "ZenMaruGothic-Medium"
    /// 見出し・数字・ボタン(Bold)の PostScript 名
    static let bold = "ZenMaruGothic-Bold"
    /// 同梱する書体のファイル名(Info.plist の UIAppFonts と、FontRegistrationTests が使う)
    static let files = ["ZenMaruGothic-Medium.ttf", "ZenMaruGothic-Bold.ttf"]

    /// iOS の文字スタイルの標準の大きさ(大きさの設定が「標準」のとき)
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }

    /// 見出しは太字が標準(iOS の .headline と同じ)
    static func isBoldByDefault(_ style: Font.TextStyle) -> Bool {
        style == .headline
    }
}

extension Font {
    /// 丸ゴシックの文字スタイル。bold を省くと、見出し(.headline)だけ太字になる
    static func lien(_ style: Font.TextStyle, bold: Bool? = nil) -> Font {
        let isBold = bold ?? LienTypeface.isBoldByDefault(style)
        return .custom(
            isBold ? LienTypeface.bold : LienTypeface.regular,
            size: LienTypeface.baseSize(style),
            relativeTo: style
        )
    }

    /// 丸ゴシックの決まった大きさ(大きな数字・シェア画像・ウィジェットの小さな枠)。
    /// relativeTo を渡すと、文字を大きくする設定に連れて広がる(省くと大きさは固定)
    static func lien(size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle? = nil) -> Font {
        let name = bold ? LienTypeface.bold : LienTypeface.regular
        if let style {
            return .custom(name, size: size, relativeTo: style)
        }
        return .custom(name, fixedSize: size)
    }
}
