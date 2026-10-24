// WidgetRenderSheets.swift — ウィジェットの一覧画像(WidgetRenderTests が保存する)の台紙(issue #17 T17a)
//
// 状態の一覧・ロック画面・機種の大きさ × 文字の大きさ。中身は本物と同じ WidgetRootView(WidgetRenderSupport の WidgetTestFrame /
// WidgetLockCircle / WidgetLockInline が、システムが足す内側の余白・背景・円形の背景・単色化を近似する)。
// Lazy な入れ物は ImageRenderer で描けないことがあるので、行と列を素直に並べる。

import SwiftUI
@testable import Lien

// MARK: - 一覧の台紙

/// 一覧の台紙(タイトル+ライト / ダークの背景)
struct WidgetSheet<Content: View>: View {
    let title: String
    let dark: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content
        }
        .padding(16)
        .background(dark ? Color(white: 0.32) : Color(white: 0.9))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

func widgetSheetRows<T>(_ items: [T], by size: Int) -> [[T]] {
    stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
}

/// ホーム S / M の状態の一覧(Lazy な入れ物は ImageRenderer で描けないことがあるので、行と列を素直に並べる)
struct WidgetStatesSheet: View {
    let title: String
    let layout: WidgetLayout
    let size: CGSize
    let dark: Bool
    let columns: Int

    var body: some View {
        WidgetSheet(title: title, dark: dark) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(widgetSheetRows(WidgetSamples.homeStates, by: columns).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(row.indices, id: \.self) { index in
                            WidgetCell(item: row[index], layout: layout, size: size, dark: dark)
                        }
                    }
                }
            }
        }
    }
}

/// ウィジェット1つ+ラベル
struct WidgetCell: View {
    let item: WidgetSamples.Item
    let layout: WidgetLayout
    let size: CGSize
    let dark: Bool
    var textSize: DynamicTypeSize = .large
    var caption: String?

    var body: some View {
        VStack(spacing: 4) {
            WidgetTestFrame(
                content: WidgetContent(snapshot: item.snapshot), layout: layout, size: size, dark: dark, textSize: textSize
            )
            Text(caption ?? item.label)
                .font(.system(size: 9))
                .foregroundStyle(dark ? Color.white.opacity(0.75) : Color.black.opacity(0.65))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: size.width)
        }
    }
}

/// ロック画面: 暗い壁紙に、円形(白黒の近似と、色のまま)とインライン
struct WidgetLockScreenSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ロック画面 — 円形(上: 単色化の近似 / 下: 色のまま)とインライン")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            circles(monochrome: true)
            circles(monochrome: false)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(WidgetSamples.lockStates.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        WidgetLockInline(content: WidgetContent(snapshot: WidgetSamples.lockStates[index].snapshot))
                        Text(WidgetSamples.lockStates[index].label)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.1, green: 0.16, blue: 0.3), Color(red: 0.25, green: 0.12, blue: 0.3)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .environment(\.colorScheme, .dark)
    }

    private func circles(monochrome: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(WidgetSamples.lockStates.indices, id: \.self) { index in
                VStack(spacing: 4) {
                    WidgetLockCircle(content: WidgetContent(snapshot: WidgetSamples.lockStates[index].snapshot), monochrome: monochrome)
                    Text(WidgetSamples.lockStates[index].label)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 76)
                }
            }
        }
    }
}

/// 機種の大きさ × 文字の大きさ(最大の文字サイズは、WidgetRootView の上限(xxLarge)で止まる)
struct WidgetSizesSheet: View {
    let title: String
    let layout: WidgetLayout
    let sizes: [CGSize]
    private let textSizes: [(String, DynamicTypeSize)] = [("標準", .large), ("xxLarge", .xxLarge), ("最大(accessibility5 = xxLarge で止まる)", .accessibility5)]
    private let items: [WidgetSamples.Item] = [WidgetSamples.homeStates[2], WidgetSamples.homeStates[3], WidgetSamples.homeStates[6]]

    var body: some View {
        WidgetSheet(title: title, dark: false) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(textSizes.indices, id: \.self) { textIndex in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(sizes.indices, id: \.self) { sizeIndex in
                            VStack(spacing: 8) {
                                ForEach(items.indices, id: \.self) { itemIndex in
                                    WidgetCell(
                                        item: items[itemIndex], layout: layout, size: sizes[sizeIndex], dark: false,
                                        textSize: textSizes[textIndex].1,
                                        caption: "\(Int(sizes[sizeIndex].width))×\(Int(sizes[sizeIndex].height)) \(textSizes[textIndex].0) — \(items[itemIndex].label)"
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
