// StoreScreenshotFrames.swift — ストア用スクリーンショットの「実描画を入れる枠」(issue #80 / MK7)
//
// 画像の作り方は2段階。どちらも CI(lien-ios)のシミュレータで ImageRenderer が描く:
//   1. アプリの本物の View(HomeView / HistoryView / WidgetRootView / ShareImageCardView)を、
//      端末と同じポイント数(6.7in = 430×932 / 6.1in = 393×852)で描く → 実寸のスクリーンショット
//   2. その画像を、下の StoreScreenshotFrameView の端末枠に差し込み、キャプションと合成する
//
// キャプションの正本は products/lien/marketing/screenshots/captions.json(mkt-exec と共有する)。
// 文言・並び・scene はこの JSON だけを直せばよい(画像はテストが作り直す)。
//
// ここは「枠」と「配色」だけを持つ。アプリ本体には入れない(テストターゲット専用)。

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - captions.json

/// キャプションの正本(marketing/screenshots/captions.json)。画像には出さない claim も読む
struct StoreScreenshotCatalog: Decodable {
    struct Size: Decodable {
        let width: Int
        let height: Int
        let pointWidth: CGFloat
        let pointHeight: CGFloat
        let device: String

        var pointSize: CGSize { CGSize(width: pointWidth, height: pointHeight) }
        var pixelSize: CGSize { CGSize(width: width, height: height) }
    }

    struct Frame: Decodable, Identifiable {
        let id: String
        /// どの画面を描くか(StoreScreenshotRenderTests が切り替える)
        let scene: String
        let badge: String
        let accent: String
        let headline: [String]
        let sub: String
        /// この訴求の根拠(mkt-review 用。画像には出ない)
        let claim: String
    }

    let version: Int
    let updated: String
    let note: String
    let sizes: [String: Size]
    let frames: [Frame]

    /// リポジトリの marketing/screenshots/captions.json を読む
    static func load() throws -> StoreScreenshotCatalog {
        try JSONDecoder().decode(
            StoreScreenshotCatalog.self,
            from: SourceTree.lienData("marketing/screenshots/captions.json")
        )
    }
}

// MARK: - 配色(v4「タネの子」のパレット。assets/plant/svg と同じ色)

enum StoreScreenshotPalette {
    /// 背景の上(クリーム)
    static let backgroundTop = Color(red: 1.0, green: 0.984, blue: 0.949)      // #FFFBF2
    /// 背景の下(若草)
    static let backgroundBottom = Color(red: 0.933, green: 0.969, blue: 0.878)  // #EEF7E0
    /// 見出し(輪郭のダークブラウン)
    static let ink = Color(red: 0.290, green: 0.204, blue: 0.157)               // #4A3428
    /// サブコピー(土の色)
    static let subInk = Color(red: 0.494, green: 0.333, blue: 0.224)            // #7E5539
    /// 端末のベゼル
    static let bezel = Color(red: 0.180, green: 0.145, blue: 0.118)

    /// "#RRGGBB" を Color にする(読めない値は若草)
    static func accent(_ hex: String) -> Color {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else {
            return Color(red: 0.510, green: 0.788, blue: 0.361)
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - 枠(キャプション + 実描画の端末)

/// 1枚分のストア画像。上のキャプションと、下の端末枠(実描画のスクリーンショット)からなる。
/// 端末枠の比率は、書き出すキャンバス(6.7in / 6.1in)と同じにする(画像を歪めない)
struct StoreScreenshotFrameView: View {
    let copy: StoreScreenshotCatalog.Frame
    let canvas: CGSize
    let screen: CGImage

    /// 430pt 幅を 1 とした縮尺(6.1in は 0.914 倍。文字と余白が同じ見え方になる)
    private var u: CGFloat { canvas.width / 430 }

    /// 端末の画面の幅(pt)。キャンバスの幅から決める
    private var screenWidth: CGFloat { 332 * u }
    /// 端末の画面の高さ。元のスクリーンショットと同じ縦横比にする
    private var screenHeight: CGFloat { screenWidth * canvas.height / canvas.width }
    /// ベゼルの太さ
    private var bezelWidth: CGFloat { 6 * u }

    var body: some View {
        ZStack(alignment: .top) {
            background
            VStack(spacing: 0) {
                badge.padding(.top, 34 * u)
                headline.padding(.top, 9 * u)
                sub.padding(.top, 7 * u)
                phone.padding(.top, 13 * u)
                Spacer(minLength: 0)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        // 書き出す画像は、端末のライト / ダーク設定に左右されない
        .environment(\.colorScheme, .light)
    }

    // MARK: 背景

    private var background: some View {
        let accent = StoreScreenshotPalette.accent(copy.accent)
        return ZStack {
            LinearGradient(
                colors: [StoreScreenshotPalette.backgroundTop, StoreScreenshotPalette.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [accent.opacity(0.20), accent.opacity(0)],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 420 * u
            )
            RadialGradient(
                colors: [Color.white.opacity(0.75), Color.white.opacity(0)],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 380 * u
            )
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    // MARK: キャプション

    private var badge: some View {
        let accent = StoreScreenshotPalette.accent(copy.accent)
        return Text(copy.badge)
            .font(.system(size: 13 * u, weight: .bold, design: .rounded))
            .foregroundStyle(StoreScreenshotPalette.ink)
            .padding(.horizontal, 13 * u)
            .padding(.vertical, 6 * u)
            .background(Capsule().fill(accent.opacity(0.30)))
            .overlay(Capsule().stroke(accent.opacity(0.65), lineWidth: 1 * u))
    }

    private var headline: some View {
        VStack(spacing: 2 * u) {
            ForEach(Array(copy.headline.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 28 * u, weight: .bold, design: .rounded))
                    .foregroundStyle(StoreScreenshotPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private var sub: some View {
        Text(copy.sub)
            .font(.system(size: 13.5 * u, weight: .medium))
            .foregroundStyle(StoreScreenshotPalette.subInk)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(width: 380 * u)
    }

    // MARK: 端末枠

    private var phone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 48 * u, style: .continuous)
                .fill(StoreScreenshotPalette.bezel)
            Image(decorative: screen, scale: 3)
                .resizable()
                .scaledToFill()
                .frame(width: screenWidth, height: screenHeight)
                .clipShape(RoundedRectangle(cornerRadius: 42 * u, style: .continuous))
        }
        .frame(width: screenWidth + bezelWidth * 2, height: screenHeight + bezelWidth * 2)
        .shadow(color: .black.opacity(0.18), radius: 18 * u, x: 0, y: 12 * u)
    }
}

// MARK: - 一覧画像(G4 で6枚を並べて見る)

/// 6枚を 3列×2行に並べた1枚(G4 の承認材料)。1倍で書き出す
struct StoreScreenshotContactSheetView: View {
    let frames: [CGImage]
    let canvasWidth: CGFloat

    private let margin: CGFloat = 24
    private let gap: CGFloat = 24
    private let columns = 3

    private var cellWidth: CGFloat {
        (canvasWidth - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
    }

    private var rows: Int {
        guard !frames.isEmpty else { return 1 }
        return (frames.count + columns - 1) / columns
    }

    private var canvasHeight: CGFloat {
        // 6.7in の縦横比(1290×2796)で並べる
        let cellHeight = cellWidth * 2796 / 1290
        return margin * 2 + cellHeight * CGFloat(rows) + gap * CGFloat(rows - 1)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            StoreScreenshotPalette.backgroundTop
                .frame(width: canvasWidth, height: canvasHeight)
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < frames.count {
                                Image(decorative: frames[index], scale: 1)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: cellWidth)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                Color.clear.frame(width: cellWidth, height: cellWidth * 2796 / 1290)
                            }
                        }
                    }
                }
            }
            .padding(margin)
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .environment(\.colorScheme, .light)
    }
}
