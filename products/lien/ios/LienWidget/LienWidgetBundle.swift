// LienWidgetBundle.swift — ウィジェット拡張のエントリポイント(DESIGN §3.1, §3.5 / issue #17 T17a)
//
// v1.0 のウィジェットは1つ(kind: LienWidget)で、4つのファミリー(REQUIREMENTS §3.10):
//   - ホーム画面・小(systemSmall): 植物(ふたりの葉 = 今日の2人)+ストリーク+2人の今日の状態+細い進み具合のバー+「(相手)が待ってるよ」
//   - ホーム画面・中(systemMedium): 上の内容+植物を大きく。**相手の写真は v1.0.1(T17b)**
//   - ロック画面・円形(accessoryCircular): 相手の今日の状態(葉の開閉)
//   - ロック画面・インライン(accessoryInline): ストリーク数
// 見た目は Lien/Core/Widget/(アプリ本体とソース共有。テストと一覧画像が同じビューを描く)。ここは WidgetKit との接ぎ手だけ:
// 何を出すか(WidgetContent)・どの時刻にどの状態か(WidgetTimelinePlan)は、そちらの純粋関数が決める。
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
    static let kind = "LienWidget"

    /// v1.0 のファミリー。ホーム M の相手の写真(v1.0.1)が入るまでは、写真なしの「植物を大きく」。
    /// M を外すときは、ここから .systemMedium を取る 1 行(REQUIREMENTS §3.10 は M を v1.0.1 としている)
    static let supportedFamilies: [WidgetFamily] = [
        .systemSmall, .systemMedium, .accessoryCircular, .accessoryInline,
    ]

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LienTimelineProvider()) { entry in
            LienWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Strings.Widget.displayName)
        .description(Strings.Widget.description)
        .supportedFamilies(Self.supportedFamilies)
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
        let now = Date()
        let snapshot = store?.loadSnapshot() ?? (context.isPreview ? .widgetSample : nil)
        completion(LienTimelineEntry(date: now, snapshot: snapshot.map { WidgetTimelinePlan.effective($0, at: now) }))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LienTimelineEntry>) -> Void) {
        // エントリ2点: now と 翌日0:00(日付跨ぎで両者「未完」に戻す)。policy: .atEnd(DESIGN §3.5)。
        // 前の日に作られた snapshot の「今日」は、今日の分を「まだ」として描く(WidgetTimelinePlan。テストは WidgetTimelinePlanTests)
        let now = Date()
        let snapshot = store?.loadSnapshot()
        let entries = WidgetTimelinePlan.steps(snapshot: snapshot, now: now)
            .map { LienTimelineEntry(date: $0.date, snapshot: $0.snapshot) }

        if snapshot == nil, store?.snapshotFileIsLocked() == true {
            // ファイルはあるのに、データ保護で読めない(再起動後の最初のアンロックの前)。このまま翌日 0:00 まで
            // 「アプリを開いてはじめよう」を出しつづけないよう、少しあとにもう一度読む
            completion(Timeline(
                entries: [entries[0]],
                policy: .after(now.addingTimeInterval(WidgetTimelinePlan.lockedRetryInterval))
            ))
            return
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

extension PairSnapshot {
    /// ギャラリー(placeholder / preview)表示用のサンプル(DESIGN §3.4 の例示値。進み具合のキーつき)。
    /// 呼ぶたびに作る(updatedAt を今にして、前の日の snapshot として「今日の分」を戻されないように — WidgetTimelinePlan.effective)
    static var widgetSample: PairSnapshot {
        PairSnapshot(
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
            plantGrownDays: 9,
            plantStageFloor: 7,
            plantNextStageAt: 14,
            plantMood: .fidget, // 片方未完のそわそわ(REQUIREMENTS §3.9)
            plantName: "みどり",
            hasPartnerPhotoToday: false
        )
    }
}
