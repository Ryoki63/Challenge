// SessionHealth.swift — ログイン状態(セッション)が使えなくなったことの判定(T23 #23)
//
// 起動時・前面復帰時・push 受信時の GET /snapshot の結果(SnapshotSynchronizer.Outcome)を数えて、
// 「サーバーがこのセッションを受け付けない」状態が続いているかを判定する。
//   - 401 unauthorized / 404 user_not_found は「このセッションのユーザーが居ない・認証できない」の合図。
//     アカウントがサーバー側で消えた(別の端末で削除した・運営が削除した)ときや、プロジェクトを作り直したときに
//     続いて出る。認証サーバーの不調(通信の失敗・5xx)は、サーバーが 503 auth_unavailable に分ける(snapshot/index.ts・
//     _shared/auth_errors.ts)ので、ここでは数えない。それでも 401 は、自分たちのサーバーの設定の誤りなどでも出うるので、
//     1 回では決めない。**連続して threshold 回**出たときだけ `.lost` にする
//   - サーバーが答えた(applied / skipped…)ら健全。数え直し
//   - 通信エラー・サーバーの 5xx(503 auth_unavailable を含む)・端末側の保存の失敗は、セッションの良し悪しとは関係がないので、
//     数えも消しもしない
//
// `.lost` になったときの動き(AppModel / RootView): まず**認証サーバーに直接たしかめる**(SessionVerifying)。確かに拒否されて
// いたときだけ、すぐには何も消さず、「ログイン状態を確認できません」の確認を出す(受け付けているなら数え直し、たしかめられなければ
// 次の同期でもう一度)。利用者が「はじめからやり直す」を選んだときだけサインアウトして端末の記録を消し、オンボーディングに戻る
// (登録なしで始めたアカウントには戻れないので、一時的な不調で勝手に消さない)。「あとで」なら数え直す。
// なお、認証 SDK 自身がセッションを破棄したとき(アカウントが消えたあと、トークンの更新が拒否された)は、選べることが無いので、
// 確認なしで同じ後始末を通す(AppModel.confirmSessionVanished)。

import Foundation

struct SessionHealthMonitor: Equatable {
    /// 連続してセッションが拒否されたら「失われた」とみなす回数
    static let defaultThreshold = 3

    enum Verdict: Equatable {
        /// サーバーが答えた、またはまだ疑う理由がない
        case healthy
        /// セッションが拒否された。まだ回数が足りない(あるいは、通信の失敗で判断を保留している)
        case suspect
        /// 連続して拒否された。確認を出す
        case lost
    }

    let threshold: Int
    private(set) var consecutiveRejections = 0

    init(threshold: Int = defaultThreshold) {
        self.threshold = max(1, threshold)
    }

    /// 同期の結果を 1 件数える
    @discardableResult
    mutating func record(_ outcome: SnapshotSynchronizer.Outcome) -> Verdict {
        switch outcome {
        case .applied, .skippedPendingOps, .skippedLocalChanged, .skippedSessionEnded:
            // サーバーはこのセッションを受け付けた(または、いま終わらせているところ)
            consecutiveRejections = 0
            return .healthy
        case .failed(.unauthorized), .failed(.userNotFound):
            consecutiveRejections += 1
            return consecutiveRejections >= threshold ? .lost : .suspect
        case .failed(.network), .failed(.server), .failed(.storage):
            // セッションの良し悪しとは関係がない: 数えも消しもせず、いまの見立てのまま
            return consecutiveRejections == 0 ? .healthy : .suspect
        }
    }

    /// 数え直す(「あとで」を選んだ・サインアウトした)
    mutating func reset() {
        consecutiveRejections = 0
    }
}
