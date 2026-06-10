// LienWidgetBundle.swift — ウィジェット拡張のエントリポイント(DESIGN §3.1, §3.5)
//
// T07: systemSmall の静的ウィジェット(App Group の snapshot を読み取り専用で表示)。
// systemMedium / ロック画面(accessory)/ 写真表示は T17 で追加する。
//
// 実装方針(DESIGN §3.5):
//   - TimelineProvider のエントリは2点: now(現在状態)と 翌日0:00(両者「未完」表示に戻す)。policy: .atEnd
//   - reload のトリガーは NSE とアプリ本体のみ(WidgetKit の reload 予算を浪費しない。
//     ウィジェット自身は能動的に reload しない)
//   - ウィジェットは読み取り専用。App Group へ書き込むのはアプリ本体と NSE の2者だけ(§3.4)

import SwiftUI
import WidgetKit

@main
struct LienWidgetBundle: WidgetBundle {
    var body: some Widget {
        LienWidget()
    }
}

struct LienWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LienWidget", provider: LienTimelineProvider()) { entry in
            LienWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(Strings.Widget.displayName)
        .description(Strings.Widget.description)
        .supportedFamilies([.systemSmall])
    }
}

struct LienTimelineEntry: TimelineEntry {
    let date: Date
    /// nil = App Group に snapshot が無い(初回起動前など)→ 空状態表示
    let snapshot: PairSnapshot?
}

struct LienTimelineProvider: TimelineProvider {
    /// テストやプレビューでストアを差し替えられるように注入可能にする
    var store: AppGroupStore? = AppGroupStore.standard()

    func placeholder(in context: Context) -> LienTimelineEntry {
        LienTimelineEntry(date: .now, snapshot: .widgetSample)
    }

    func getSnapshot(in context: Context, completion: @escaping (LienTimelineEntry) -> Void) {
        // ギャラリー(プレビュー)では実データが無くてもサンプルを見せる
        let snapshot = store?.loadSnapshot() ?? (context.isPreview ? .widgetSample : nil)
        completion(LienTimelineEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LienTimelineEntry>) -> Void) {
        // エントリ2点: now と 翌日0:00(日付跨ぎで両者「未完」に戻す)。policy: .atEnd(DESIGN §3.5)
        let now = Date()
        let nextMidnight = DayBoundary.nextMidnight(after: now)
        let snapshot = store?.loadSnapshot()
        let entries = [
            LienTimelineEntry(date: now, snapshot: snapshot),
            LienTimelineEntry(date: nextMidnight, snapshot: snapshot?.resettingForNewDay()),
        ]
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

extension PairSnapshot {
    /// ギャラリー(placeholder / preview)表示用のサンプル(DESIGN §3.4 の例示値)
    static let widgetSample = PairSnapshot(
        schemaVersion: PairSnapshot.currentSchemaVersion,
        pairId: "00000000-0000-0000-0000-000000000000",
        updatedAt: .now,
        streakCurrent: 23,
        streakBest: 40,
        todayMeDone: true,
        todayPartnerDone: false,
        myPromiseTitle: "筋トレ",
        myPromiseEmoji: "💪",
        partnerName: "ゆうき",
        partnerPromiseTitle: "ランニング",
        partnerPromiseEmoji: "🏃",
        plantStage: 3,
        plantMood: .fidget, // 片方未完のそわそわ(REQUIREMENTS §3.9)
        plantName: "みどり",
        hasPartnerPhotoToday: false
    )
}
