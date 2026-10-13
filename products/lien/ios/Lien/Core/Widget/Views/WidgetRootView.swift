// WidgetRootView.swift — ウィジェットの描画方式(WidgetLayout)に応じて、各レイアウトを選ぶ(issue #17 T17a)
//
// 実際のウィジェット(LienWidget の LienWidgetEntryView)も、テストの一覧画像(WidgetRenderTests)も、このビューを描く。
// WidgetKit の WidgetFamily は、ここには持ち込まない(accessory 系は macOS の SDK に無いので、ソース共有する側に置けない)。
// システムの余白(S / M は内側 16pt)・背景(containerBackground)・円形の背景(AccessoryWidgetBackground)は、
// 描く側(LienWidget)が足す。ここが描くのは、その内側。
//
// VoiceOver: ウィジェット全体で1つの要素にして、内容の文(WidgetContent.spokenSummary など)を読み上げる。
// 絵や ○× を個別に読み上げない(植物の読み上げ文は GROWTH §5.4)。

import SwiftUI

struct WidgetRootView: View {
    let content: WidgetContent
    let layout: WidgetLayout
    /// 植物の各レイヤーに付ける装飾。実際のウィジェットは .widgetFullColor(色合い表示でも単色にしない — WidgetAccent.swift)
    var imageStyle: PlantImageStyle = .plain

    /// ホーム画面の文字の大きさの上限。小さな枠に収めるため、最大の文字サイズまでは広げない
    /// (ロック画面は、システムが大きさを決めるので制限しない)
    static let homeTextSizeLimit = DynamicTypeSize.xxLarge

    var body: some View {
        switch layout {
        case .small:
            WidgetSmallView(content: content, imageStyle: imageStyle)
                .dynamicTypeSize(...Self.homeTextSizeLimit)
                .spoken(content.spokenSummary)
        case .medium:
            WidgetMediumView(content: content, imageStyle: imageStyle)
                .dynamicTypeSize(...Self.homeTextSizeLimit)
                .spoken(content.spokenSummary)
        case .lockCircular:
            WidgetLockCircularView(content: content, imageStyle: imageStyle)
                .spoken(content.spokenPartner)
        case .lockInline:
            WidgetLockInlineView(content: content)
                .spoken(content.spokenStreak)
        }
    }
}

private extension View {
    /// 全体を1つの要素にして、文を読み上げる
    func spoken(_ label: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}
