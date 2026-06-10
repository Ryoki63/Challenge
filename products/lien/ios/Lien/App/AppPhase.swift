// AppPhase.swift — ルート画面系統の状態(DESIGN §3.3)

import Foundation

/// アプリのルート状態。onboarding → solo → paired と進む。
/// 状態の正はサーバー(PairSnapshot)で、本 enum は表示系統の切替にのみ使う。
enum AppPhase: String, Codable, CaseIterable, Sendable {
    /// 初回起動〜認証前
    case onboarding
    /// 認証済み・ペア未成立(招待の送受信が可能)
    case solo
    /// ペア成立済み(ホーム画面系統)
    case paired
}
