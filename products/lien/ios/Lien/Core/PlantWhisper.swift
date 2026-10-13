// PlantWhisper.swift — 今日のひとこと(タネの子の吹き出し)の選び方(純粋関数 / issue #57 の P1)
//
// 正本: docs/GROWTH.md §5.5。その日はじめてホームを開いたとき、タネの子が吹き出しで短く話す(数秒で消える。植物をタップすると、もう一度出る)。
// 状況(今日のチェックインの状態・すやすや・時間帯・段階)ごとの候補から、**日付で1つ選ぶ**ので、同じ日の同じ状況なら同じ言葉になる。
// 絵は使わない。主語は名前にする(左右は使わない — GROWTH §4.5)。候補は Strings.Plant.Whisper(罰なし文言の lint の対象)。
//
// 選び方:
//   - 状況の候補: ふたりそろった / 相手だけ完了 / 自分だけ完了 / すやすや / まだ誰もしていない日(朝・昼・夕方・夜)
//   - 段階の候補(ふたば・わかば・つぼみ・ふたりざき・みのり)を、状況の候補にそのまま足す
//   - 候補の並びの中から、日付(端末のローカル日の通し日数)で1つ選ぶ
// ソロ(土の中で眠っている)には出さない。

import Foundation

enum PlantWhisper {
    /// まだ誰もチェックインしていない日の時間帯
    enum TimeBand: Equatable, Sendable {
        case morning
        case daytime
        case evening
        case night

        /// 5〜10時 = 朝 / 11〜16時 = 昼 / 17〜21時 = 夕方 / 22〜4時 = 夜
        init(hour: Int) {
            switch hour {
            case 5..<11: self = .morning
            case 11..<17: self = .daytime
            case 17..<22: self = .evening
            default: self = .night
            }
        }
    }

    /// 候補の並び(状況の候補 + 段階の候補)。ソロは空
    static func candidates(for snapshot: PairSnapshot, band: TimeBand) -> [String] {
        guard snapshot.pairId != nil else { return [] }
        let partnerName = snapshot.partnerName ?? Strings.Home.partnerFallbackLabel
        var lines: [String]
        switch (snapshot.todayMeDone, snapshot.todayPartnerDone) {
        case (true, true):
            lines = Strings.Plant.Whisper.bothDone(partnerName)
        case (false, true):
            lines = Strings.Plant.Whisper.partnerDone(partnerName)
        case (true, false):
            lines = Strings.Plant.Whisper.meDone(partnerName)
        case (false, false):
            if snapshot.plantMood == .sad {
                lines = Strings.Plant.Whisper.sleepy
            } else {
                switch band {
                case .morning: lines = Strings.Plant.Whisper.morning
                case .daytime: lines = Strings.Plant.Whisper.daytime
                case .evening: lines = Strings.Plant.Whisper.evening
                case .night: lines = Strings.Plant.Whisper.night
                }
            }
        }
        lines += Strings.Plant.Whisper.stage(PlantLayers.clampedStage(snapshot.plantStage))
        return lines
    }

    /// 今日のひとこと。候補から、日付で1つ選ぶ(同じ日の同じ状況なら同じ言葉)。ソロは nil
    static func line(for snapshot: PairSnapshot, now: Date, calendar: Calendar = .current) -> String? {
        let hour = calendar.component(.hour, from: now)
        let pool = candidates(for: snapshot, band: TimeBand(hour: hour))
        guard !pool.isEmpty else { return nil }
        return pool[PlantDay.number(of: now, calendar: calendar) % pool.count]
    }
}

/// 端末のローカル日の通し日数(おかえり・今日のひとことが「日付の差」「同じ日か」を数える)。
/// Calendar の era 内の日の序数なので、夏時間・タイムゾーンの差があっても日の差が数えられる
enum PlantDay {
    static func number(of date: Date, calendar: Calendar = .current) -> Int {
        calendar.ordinality(of: .day, in: .era, for: date) ?? 0
    }
}

/// 吹き出しの大きさ(点)と、植物の枠の上に空けておく余白の計算(純粋)。
/// 吹き出しは植物の枠の上にはみ出して出す(下端が枠の上端の `gap` 上)。レイアウトは動かさないので、出ていないときも
/// 余白を空けておく。文字を大きくする設定(Dynamic Type)では行が高くなり、最大2行の吹き出しも高くなる。余白が足りないと、
/// ホームの ScrollView の上端・ナビゲーションバーの下に吹き出しが食い込んで切れる(PB の Opus レビュー)。
/// 2行ぶんの高さに合わせて余白を広げる(行の高さは `.footnote` を基準に ScaledMetric で文字の大きさに連れて広げる)
enum WhisperBubbleMetrics {
    /// 吹き出しの文字の行数の上限
    static let maxLines = 2
    /// 吹き出しの文字の上下の余白(片側)
    static let verticalPadding: CGFloat = 6
    /// 吹き出しの文字の左右の余白(片側)
    static let horizontalPadding: CGFloat = 12
    /// しっぽ(下向きの三角)の大きさ
    static let tailWidth: CGFloat = 14
    static let tailHeight: CGFloat = 7
    /// 吹き出しの下端と、植物の枠の上端のすき間
    static let gap: CGFloat = 2
    /// 吹き出しの幅
    static let width: CGFloat = 260
    /// 標準の文字の大きさ(Large)での `.footnote` の行の高さ。ScaledMetric の基準にする(Apple の HIG: 13pt の行送りは 18pt)
    static let baseLineHeight: CGFloat = 18
    /// 親(ホームの ScrollView)が内容の上に空けている余白。吹き出しは、この余白にもはみ出してよい(LienSpacing.l と同じ 24pt)
    static let parentTopPadding: CGFloat = 24
    /// 植物の枠の上に最低限空ける余白(吹き出しが出ていないときの、植物の上の空き。LienSpacing.xl と同じ 32pt)
    static let minimumRoom: CGFloat = 32
    /// 上の端から空けておく余裕。日本語の行は、かなと漢字のフォントの違いで、基準の行の高さより少し高くなることがある
    static let safetyMargin: CGFloat = 4

    /// 最大の行数の吹き出しが、植物の枠の上にはみ出す高さ(文字 + 上下の余白 + しっぽ + すき間)
    static func extent(lineHeight: CGFloat) -> CGFloat {
        CGFloat(maxLines) * lineHeight + 2 * verticalPadding + tailHeight + gap
    }

    /// 植物の枠の上に空けておく余白。吹き出しの高さのうち、親の余白に収まらない分(と余裕)を足す。
    /// 標準の文字の大きさでは、従来の 32pt に近い(37pt)
    static func roomAbovePlant(lineHeight: CGFloat) -> CGFloat {
        max(minimumRoom, extent(lineHeight: lineHeight) - parentTopPadding + safetyMargin)
    }
}
