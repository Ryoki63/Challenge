// AppPhase.swift — ルート画面系統の状態(DESIGN §3.3 / issue #55)

import Foundation

/// アプリのルート状態。onboarding → promiseSetup → solo → paired と進む。
/// 状態の正はサーバー(PairSnapshot)で、本 enum は表示系統の切替にのみ使う。
/// 値の導出は純粋関数 AppRouter.phase(hasSession:snapshot:)。
enum AppPhase: String, Codable, CaseIterable, Sendable {
    /// 初回起動〜認証前(セッション無し)
    case onboarding
    /// 認証済み・現役の約束がまだ無い(約束設定画面 — REQUIREMENTS §3.3)
    case promiseSetup
    /// 約束あり・ペア未成立(ソロ。ホームで約束とチェックインができ、招待導線がある — §3.2)
    case solo
    /// ペア成立済み(ホーム画面系統)
    case paired

    /// ホーム画面系統か(solo / paired はどちらもホームを出す)
    var isHome: Bool {
        self == .solo || self == .paired
    }
}
