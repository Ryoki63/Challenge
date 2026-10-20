// ShareImageCardView.swift — シェア画像の実描画(T22 / REQUIREMENTS §3.13)
//
// 載せるのは、植物の現在の姿・2人のニックネーム・ストリーク日数・開始日・アプリ名だけ。
// **チェックイン写真は描かない**(内容に写真が無い。privacy-policy §3)。
//
//   - 縦 9:16(story)= 360×640pt を3倍で 1080×1920 に書き出す
//   - 正方形(square)= 360×360pt を3倍で 1080×1080 に書き出す
//   - 色は LienColors の share*(端末のライト / ダークに依らず、いつも同じ色)
//   - 植物は PlantCharacterView(ホームと同じベクター)。シェア用は「ふたりそろった」にっこりの姿にする
//     (今日どちらかがまだでも、画像は記録のお祝いなので、今日の未完了を写さない)
//   - ShareImageRenderer が ImageRenderer で CGImage にし、PNG の Data にする(UIKit は使わない)
//
// ImageRenderer は iOS / macOS の両方にあるが、実際に描くのは iOS のテスト・アプリだけ
// (macOS の下見では型検査だけ。アセットカタログを読まないため)。

import CoreGraphics
import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 描画

struct ShareImageCardView: View {
    let content: ShareImageContent
    let format: ShareImageFormat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            background
            switch format {
            case .story: storyLayout
            case .square: squareLayout
            }
            appMark
                .padding(.trailing, format == .story ? 24 : 18)
                .padding(.bottom, format == .story ? 22 : 16)
        }
        .frame(width: format.pointSize.width, height: format.pointSize.height)
        .clipped()
        // 書き出す画像は、端末のライト / ダーク設定に左右されない
        .environment(\.colorScheme, .light)
    }

    // MARK: 縦(ストーリーズ 9:16)

    private var storyLayout: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 22)
            caption
            streakBlock(numberSize: 118, unitSize: 34)
                .padding(.top, 2)
            plant
                .frame(width: 198, height: 264)
                .padding(.vertical, 6)
            namesPill(fontSize: 21)
            startedOn(fontSize: 14)
                .padding(.top, 8)
            Spacer(minLength: 46)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 正方形(1:1)

    private var squareLayout: some View {
        HStack(alignment: .center, spacing: 10) {
            plant
                .frame(width: 128, height: 171)
            VStack(alignment: .leading, spacing: 5) {
                caption
                streakBlock(numberSize: 74, unitSize: 24)
                namesPill(fontSize: 15)
                startedOn(fontSize: 11)
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .padding(.trailing, 30)
        .padding(.vertical, 24)
    }

    // MARK: パーツ

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [LienColors.shareBackgroundTop, LienColors.shareBackgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(LienColors.shareGlow.opacity(0.38))
                .frame(width: 270, height: 270)
                .blur(radius: 62)
                .offset(x: -122, y: format == .story ? -225 : -128)
            Circle()
                .fill(Color.white.opacity(0.38))
                .frame(width: 230, height: 230)
                .blur(radius: 54)
                .offset(x: 140, y: format == .story ? 245 : 142)
        }
        .frame(width: format.pointSize.width, height: format.pointSize.height)
    }

    private var plant: some View {
        PlantCharacterView(
            state: PlantCharacterState(
                stage: content.plantStage,
                meOpen: true,
                partnerOpen: true,
                expression: .happy
            )
        )
        .environment(\.colorScheme, .light)
    }

    private var caption: some View {
        HStack(spacing: 5) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(Strings.Share.streakCaption)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tracking(2)
        }
        .foregroundStyle(LienColors.shareAccent.opacity(0.82))
    }

    private func streakBlock(numberSize: CGFloat, unitSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(content.streakDays)")
                .font(.system(size: numberSize, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(Strings.Share.dayUnit)
                .font(.system(size: unitSize, weight: .bold, design: .rounded))
        }
        .foregroundStyle(LienColors.shareInk)
    }

    private func namesPill(fontSize: CGFloat) -> some View {
        Text(Strings.Share.names(content.myName, content.partnerName))
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(LienColors.shareInk)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.62)))
    }

    private func startedOn(fontSize: CGFloat) -> some View {
        Text(Strings.Share.startedOn(content.startedOnText))
            .font(.system(size: fontSize, weight: .medium, design: .rounded))
            .foregroundStyle(LienColors.shareInk.opacity(0.62))
            .lineLimit(1)
    }

    private var appMark: some View {
        HStack(spacing: 4) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(content.appName)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(LienColors.shareAccent.opacity(0.55))
    }
}

// MARK: - 書き出し

@MainActor
enum ShareImageRenderer {
    /// 内容を PNG にする前の CGImage に描く(1080×1920 / 1080×1080)
    static func render(_ content: ShareImageContent, format: ShareImageFormat) -> CGImage? {
        let renderer = ImageRenderer(content: ShareImageCardView(content: content, format: format))
        renderer.scale = ShareImageFormat.scale
        renderer.isOpaque = true
        return renderer.cgImage
    }

    /// CGImage を PNG の Data にする(共有シートに渡す)
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// 書き出した1枚
struct ShareRenderedImage: @unchecked Sendable {
    let image: CGImage
    let data: Data
    let filename: String
}

/// ShareLink に渡す PNG(ファイル名つき)
struct ShareImagePayload: Transferable, Sendable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .suggestedFileName { $0.filename }
    }
}
