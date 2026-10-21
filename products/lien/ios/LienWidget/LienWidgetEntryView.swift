// LienWidgetEntryView.swift — ウィジェットの本体のビュー(WidgetKit との接ぎ手 / issue #17 T17a)
//
// WidgetKit のファミリー(@Environment(\.widgetFamily))を、共有の描画方式(WidgetLayout)に写し、
// Lien/Core/Widget/ の WidgetRootView(S / M / ロック画面の円形・インライン。テストと一覧画像が描くのと同じビュー)に渡す。
// ここで足すのは、WidgetKit にしか無いもの:
//   - containerBackground: ホーム S / M はシステムの背景(ダークは暗い背景に、PlantCharacterView が最背面の bg_plate を敷く)。
//     ロック画面は背景なし(円形は AccessoryWidgetBackground を敷く。システムが単色化して描く)
//   - imageStyle: .widgetFullColor — iOS 18 の「色合い(accented)」表示でも、植物の各レイヤーが単色にならないようにする
//     (Lien/Core/Widget/Views/WidgetAccent.swift)
// 内側の余白(S / M は 16pt)は、システムの既定のまま(contentMarginsDisabled はしない)。寸法は WidgetMetrics が、その内側から決める。
//
// 表示原則(REQUIREMENTS §3.10): 自分が未完なら自分側をグレー、相手が先に完了していたら「(相手)が待ってるよ」。
// タップ動作: ウィジェット→lien://home→アプリのホーム直行(開いていた設定・招待シートを閉じる)。

import SwiftUI
import WidgetKit

struct LienWidgetEntryView: View {
    let entry: LienTimelineEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        let layout = WidgetLayout(family: family)
        let root = WidgetRootView(
            content: WidgetContent(snapshot: entry.snapshot),
            layout: layout,
            imageStyle: .widgetFullColor
        )
        Group {
            switch layout {
            case .small, .medium:
                root.containerBackground(.background, for: .widget)
            case .lockCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    root
                }
                .containerBackground(for: .widget) { Color.clear }
            case .lockInline:
                root.containerBackground(for: .widget) { Color.clear }
            }
        }
        .widgetURL(WidgetHomeLink.url)
    }
}

extension WidgetLayout {
    /// WidgetKit のファミリーから描画方式へ。想定外のファミリー(将来の追加)は S の描き方に倒す
    init(family: WidgetFamily) {
        switch family {
        case .systemMedium:
            self = .medium
        case .accessoryCircular:
            self = .lockCircular
        case .accessoryInline:
            self = .lockInline
        default:
            self = .small
        }
    }
}
