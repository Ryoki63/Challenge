// AppRouter.swift — ルート画面系統の導出(純粋関数。issue #55 / REVIEW-2026-10-12 §4.1)
//
// 入力は「セッションの有無」と「最後に取得した PairSnapshot(App Group)」だけ。
// 独自の永続フラグは持たない(状態の正はサーバー — DESIGN §3.3)。
// 起動時・サーバー同期後・約束保存後・ペア成立後に毎回これで再導出するので、
// ペア解消による paired → solo も同じ経路で扱える。
//
//   セッション無し                  → onboarding(オンボーディング)
//   セッション有り・現役の約束なし   → promiseSetup(約束設定。snapshot 未取得もここ —
//                                      AppModel が初回同期の間は読み込み表示にする)
//   約束あり・ペア未成立            → solo(ホーム: 土の鉢+チェックイン+招待導線)
//   約束あり・ペア成立              → paired(ホーム)

import Foundation

enum AppRouter {
    static func phase(hasSession: Bool, snapshot: PairSnapshot?) -> AppPhase {
        guard hasSession else { return .onboarding }
        guard let snapshot, snapshot.hasActivePromise else { return .promiseSetup }
        return snapshot.pairId == nil ? .solo : .paired
    }
}

extension PairSnapshot {
    /// 自分の現役の約束があるか(サーバーはタイトル未設定を null で返す。空白だけも未設定扱い)
    var hasActivePromise: Bool {
        guard let title = myPromiseTitle else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
