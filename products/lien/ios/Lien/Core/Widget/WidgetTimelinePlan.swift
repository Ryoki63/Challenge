// WidgetTimelinePlan.swift — ウィジェットのタイムラインの計画(純粋関数 / issue #17 T17a / DESIGN §3.5)
//
// ウィジェットは**自分では取りに行かない**(reload のトリガーは NSE とアプリ本体だけ — WidgetKit の reload 予算)。
// App Group の snapshot を読んで、次の2点のエントリを返す:
//   1. 今(now): snapshot の今日の完了(todayMeDone / todayPartnerDone)をそのまま描く。ただし**前の日までに作られた
//      snapshot の「今日」は前の日のこと**なので、今日の分は「まだ」(葉をたたむ)として描く(下の effective)
//   2. 翌日 0:00: 日付が変わると2枚とも葉をたたむ(REQUIREMENTS §3.9「日付が変わると2枚ともたたむ」)。
//      ストリーク・段階・進み具合・名前は保つ(resettingForNewDay。GROWTH §7.3: 0時台は確定前なので、減らさない)
// policy は .atEnd(0:00 のエントリを過ぎたら、WidgetKit が新しいタイムラインを求める)。
//
// 「前の日に作られた snapshot」: PairSnapshot.updatedAt(サーバーが組み立てた時刻。端末で楽観更新したときも now で更新する)の
// ローカル日が、今日より前。たとえば相手の push を何日も受け取らず、アプリも開かなかったとき、前の日の「ふたりそろった」を
// 今日の絵として出し続けない。updatedAt が今日・または未来(端末の時計とのずれ)なら、そのまま信じる。
//
// ここは Foundation だけに依存する(WidgetKit の TimelineProvider は LienWidget ターゲット側が、この計画を包む)。
// このファイルは Lien / LienWidget の2ターゲットでソース共有される(project.yml 参照)。

import Foundation

enum WidgetTimelinePlan {
    /// タイムラインの1点。date に WidgetKit がこの状態へ切り替える。snapshot が nil のときは、データ無しの表示
    struct Step: Equatable {
        let date: Date
        let snapshot: PairSnapshot?
    }

    /// snapshot のファイルが**あるのにデータ保護で読めない**間(再起動後の最初のアンロックの前。夜間の自動更新のあとなど)に、
    /// ウィジェットが読み直すまでの秒数。そのまま `.atEnd` にすると、「アプリを開いてはじめよう」を翌日 0:00 まで出しつづけてしまう。
    /// 読めない間だけの短い読み直しなので、reload の予算は使い果たさない(読めれば、通常の 2 点のタイムラインに戻る)
    static let lockedRetryInterval: TimeInterval = 120

    /// 今のエントリと、翌日 0:00 のエントリ(DESIGN §3.5)。0:00 ちょうどの now でも、次は「その翌日」の 0:00
    static func steps(snapshot: PairSnapshot?, now: Date, calendar: Calendar = .current) -> [Step] {
        let current = snapshot.map { effective($0, at: now, calendar: calendar) }
        return [
            Step(date: now, snapshot: current),
            Step(date: DayBoundary.nextMidnight(after: now, calendar: calendar), snapshot: current?.resettingForNewDay()),
        ]
    }

    /// `now` に描く snapshot。**前の日までに作られた**(updatedAt のローカル日が今日より前)ものは、今日の分を「まだ」に戻す。
    /// 今日に作られたもの・未来の時刻のもの(端末の時計とのずれ)は、そのまま
    static func effective(_ snapshot: PairSnapshot, at now: Date, calendar: Calendar = .current) -> PairSnapshot {
        isFromEarlierDay(snapshot, now: now, calendar: calendar) ? snapshot.resettingForNewDay() : snapshot
    }

    /// snapshot が、`now` の日(端末のローカル日)より前の日に作られたものか
    static func isFromEarlierDay(_ snapshot: PairSnapshot, now: Date, calendar: Calendar = .current) -> Bool {
        snapshot.updatedAt < calendar.startOfDay(for: now)
    }
}
