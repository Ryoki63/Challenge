// PaywallContext.swift — ペイウォールを出す3文脈(T33 / REQUIREMENTS §3.14)
//
//   - .milestone(days:) : 節目(7/30/100/365日)のお祝いから。ストリークの日数を渡す
//   - .albumLimit       : 写真アルバムの30日超のロックから(T21。アルバム画面の実装後に結線する)
//   - .ticketEmpty      : お休みチケットが0枚になったとき(ホームの残数バッジから)
//
// v2 の「2ペア目作成」は、複数ペア機能と同時に足す(コメントで予約。今は case を作らない)。
// 文脈ごとに見出し・説明だけを変え、価格・トライアル・購入の流れは共通にする(押し売りしない)。

import Foundation

enum PaywallContext: Equatable, Identifiable, Sendable {
    /// 節目のお祝い(ストリーク days 日)
    case milestone(days: Int)
    /// 写真アルバムの30日超のロック(T21)
    case albumLimit
    /// お休みチケットが0枚
    case ticketEmpty

    var id: String {
        switch self {
        case .milestone(let days): return "milestone:\(days)"
        case .albumLimit: return "albumLimit"
        case .ticketEmpty: return "ticketEmpty"
        }
    }

    /// 計測用の名前(REQUIREMENTS §7 の paywall_view の文脈。DB には残さず、分析 SDK のイベント名に使う)
    var analyticsName: String {
        switch self {
        case .milestone: return "milestone"
        case .albumLimit: return "album_limit"
        case .ticketEmpty: return "ticket_empty"
        }
    }

    var headline: String {
        switch self {
        case .milestone(let days): return Strings.Paywall.milestoneHeadline(days)
        case .albumLimit: return Strings.Paywall.albumHeadline
        case .ticketEmpty: return Strings.Paywall.ticketEmptyHeadline
        }
    }

    var message: String {
        switch self {
        case .milestone: return Strings.Paywall.milestoneMessage
        case .albumLimit: return Strings.Paywall.albumMessage
        case .ticketEmpty: return Strings.Paywall.ticketEmptyMessage
        }
    }
}
