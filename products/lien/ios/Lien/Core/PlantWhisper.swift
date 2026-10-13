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
