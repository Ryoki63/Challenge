// Components.swift — DesignSystem の部品(2026-11-11 UI 改修 / DESIGN §3.8)
//
// どの画面も同じ顔にするための、少数の部品。色は LienColors、余白は LienSpacing、丸みは LienRadius、書体は Font.lien。
//
//   LienPrimaryButtonStyle   : 主役のボタン(1画面に1つ)。セージの塗り+下に濃い縁を敷いた「ぷっくり」。押すと沈む。
//                              押せないあいだは淡い塗り+枠線(iOS 26 の無効な .borderedProminent はほぼ白で見えない — JOURNAL 2026-10-2x)
//   LienSecondaryButtonStyle : 補助のボタン。淡いセージの塗りだけ(主役と強さを並べない)。.lienChip は文字の幅だけの小さな1つ
//   lienCard()               : 紙の上のカード(白に近いクリーム+細い縁。影は付けない)
//   lienPaperBackground()    : 画面の地を紙の色にする(安全領域の外まで)
//   lienFormBackground()     : Form / List の地を紙の色にする(設定・約束の編集など)
//
// 色は端末のライト / ダークに従う。ImageRenderer で描くとき(ストア用スクショ・テスト)も、アセット経由の色を使わないので緑のまま。

import SwiftUI

// MARK: - 主役のボタン

struct LienPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// 主役のボタンの高さの下限(押しやすさ。文字を大きくすると連れて伸びる)
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 54
    /// 下に敷く濃い縁の厚み
    private let depth: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        return configuration.label
            .font(.lien(.body, bold: true))
            .foregroundStyle(isEnabled ? LienColors.onAccent : LienColors.accent)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .padding(.horizontal, LienSpacing.m)
            .background {
                RoundedRectangle(cornerRadius: LienRadius.button, style: .continuous)
                    .fill(isEnabled ? LienColors.accent : LienColors.accentSoft)
            }
            .overlay {
                if !isEnabled {
                    RoundedRectangle(cornerRadius: LienRadius.button, style: .continuous)
                        .strokeBorder(LienColors.accent.opacity(0.45), lineWidth: 1)
                }
            }
            // 押していないときは下に濃い縁が見え(ぷっくり)、押すと縁の分だけ沈む
            .offset(y: pressed ? depth : 0)
            .background {
                if isEnabled {
                    RoundedRectangle(cornerRadius: LienRadius.button, style: .continuous)
                        .fill(LienColors.accentDeep)
                        .offset(y: depth)
                }
            }
            .padding(.bottom, depth)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

// MARK: - 補助のボタン

struct LienSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// 小さく描く(ホームの補助の行)
    var compact = false
    /// 横幅いっぱいに広げる(false なら文字の幅だけ。植物の「名前をつける」など、行の中の小さな1つ)
    var fillsWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lien(compact ? .footnote : .subheadline, bold: true))
            .foregroundStyle(LienColors.accent)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.vertical, compact ? LienSpacing.s : 12)
            .padding(.horizontal, LienSpacing.m)
            .background {
                RoundedRectangle(cornerRadius: compact ? LienRadius.s : LienRadius.button, style: .continuous)
                    .fill(LienColors.accentSoft)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == LienPrimaryButtonStyle {
    /// 主役のボタン(1画面に1つ)
    static var lienPrimary: LienPrimaryButtonStyle { LienPrimaryButtonStyle() }
}

extension ButtonStyle where Self == LienSecondaryButtonStyle {
    /// 補助のボタン
    static var lienSecondary: LienSecondaryButtonStyle { LienSecondaryButtonStyle() }
    /// 補助のボタン(小さく)
    static var lienSecondaryCompact: LienSecondaryButtonStyle { LienSecondaryButtonStyle(compact: true) }
    /// 補助のボタン(小さく、文字の幅だけ)
    static var lienChip: LienSecondaryButtonStyle { LienSecondaryButtonStyle(compact: true, fillsWidth: false) }
}

// MARK: - カードと紙

private struct LienCardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: LienRadius.card, style: .continuous)
                    .fill(LienColors.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: LienRadius.card, style: .continuous)
                    .strokeBorder(LienColors.cardBorder, lineWidth: 1)
            }
    }
}

extension View {
    /// 紙の上のカード(白に近いクリーム+細い縁。影は付けない)
    func lienCard(padding: CGFloat = LienSpacing.m) -> some View {
        modifier(LienCardModifier(padding: padding))
    }

    /// 画面の地を紙の色にする(安全領域の外まで敷く)
    func lienPaperBackground() -> some View {
        background(LienColors.paper.ignoresSafeArea())
    }

    /// Form / List の地を紙の色にする(標準の灰色の地を消す。行はカードの色)
    func lienFormBackground() -> some View {
        scrollContentBackground(.hidden)
            .lienPaperBackground()
    }
}
