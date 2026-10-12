// LiveNudgeReactService.swift — つつく/リアクションの本実装(issue #55)
//
// NudgeReactService.swift で定義した能力プロトコル(NudgeSending / Reacting)を、
// 実 Edge Functions(nudge / react)に結線する。ホーム画面(HomeViewModel)は
// これらのプロトコルだけを知っていて、Config 未設定のスタブ構成では LocalEchoCheckinService の
// モック適合(NudgeReactService.swift)が使われる。
//
// 仕様の要点(サーバー正本は nudge/core.ts・react/core.ts):
//   - つつく: 相手が未完のときだけ。1日3回まで(超過は 429 → NudgeSendError.limitReached)
//   - リアクション: 相手の「今日の」チェックイン行 id を解決してから送る。
//     「今日」は端末ローカルの日付(snapshot の todayPartnerDone もユーザーのタイムゾーンの
//     今日で組み立てられるため、同じ基準で相手の行を探す)

import Foundation

final class LiveNudgeReactService: NudgeSending, Reacting {
    private let api: NudgeReactAPIClient
    private let partnerCheckins: PartnerCheckinResolving
    private let now: () -> Date
    private let calendar: Calendar

    init(
        api: NudgeReactAPIClient,
        partnerCheckins: PartnerCheckinResolving,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.api = api
        self.partnerCheckins = partnerCheckins
        self.now = now
        self.calendar = calendar
    }

    func sendNudge(stamp: NudgeStamp) async throws {
        do {
            _ = try await api.nudge(stamp: stamp.rawValue)
        } catch let error as NudgeReactClientError {
            throw error.asNudgeSendError
        } catch {
            throw NudgeSendError.other
        }
    }

    func sendReaction(stamp: ReactionStamp) async throws {
        let today = DayBoundary.dateLocalString(for: now(), calendar: calendar)
        guard let checkinID = try await partnerCheckins.partnerCheckinID(dateLocal: today) else {
            // 相手が(取消などで)まだ今日のチェックインをしていない: 対象が無い
            throw NudgeReactClientError.checkinNotFound
        }
        _ = try await api.react(checkinID: checkinID, stamp: stamp.rawValue)
    }
}
