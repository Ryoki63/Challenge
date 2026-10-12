// InviteSyncSchedule.swift — 招待シートが開いている間の同期の間隔(issue #62)
//
// 招待した側が、相手の受諾(ペア成立)を push なしでも画面上で知れるよう、招待シートが開いている間は
// GET /snapshot を取り直す(RootView の PairingSheet)。一定の短い間隔で叩き続けると、相手がなかなか
// 受諾しない間(リンクを送ってから開くまで数分〜数時間かかることもある)ずっと無駄に通信してしまうので、
// 間隔を段階的に伸ばす:
//
//     4秒 → 8秒 → 16秒 → 30秒(以降は 30秒のまま)
//
// 最初は「相手がすぐ開いた」場合にすぐ気づけるよう短くし、待つほど間隔をあける。
// シートを開き直すと最初(4秒)からやり直す。

import Foundation

enum InviteSyncSchedule {
    /// 最初の間隔(秒)
    static let initialInterval: TimeInterval = 4
    /// 間隔の上限(秒)
    static let maximumInterval: TimeInterval = 30

    /// attempt 回目(0 始まり)の同期の前に待つ秒数。倍々に伸ばして上限で頭打ちにする
    static func interval(forAttempt attempt: Int) -> TimeInterval {
        // 4 × 2^10 は上限(30)を十分に超えるので、指数は 10 で打ち切る(巨大な attempt でも桁あふれしない)
        let exponent = min(max(attempt, 0), 10)
        return min(maximumInterval, initialInterval * pow(2, Double(exponent)))
    }
}
