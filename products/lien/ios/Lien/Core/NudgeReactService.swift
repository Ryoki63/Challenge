// NudgeReactService.swift — つつく/リアクションの追加能力(T15 / REQUIREMENTS §3.7, §3.8)
//
// CheckinService.swift の「追加能力プロトコル」パターンを踏襲する(HomeViewModel は
// checkinService を as? でキャストして能力検出する — 新しい init 引数は増やさない)。
//
// スコープ:
//   - T15(2026-06-11 決定・issue #15)はホーム画面の導線(つつくボタン/リアクション導線)を
//     モック注入(LocalEchoCheckinService のモック適合 — 本ファイル末尾)で結線した
//   - 実 Supabase Functions nudge/react への結線は issue #55: 実 API クライアント
//     (EdgeFunctionNudgeReactClient — Api/NudgeReactAPIClient.swift)と、それを NudgeSending / Reacting
//     として公開する LiveNudgeReactService(Core/LiveNudgeReactService.swift)。AppServices が
//     Config の有無で Live / モックを切り替え、Live は HomeViewModel へ明示注入される
//     (CheckinService 自体は nudge/react を知らない — 能力の合成は注入側の責務)
//
// 自由テキスト入力は無し(§3.7「チャット化を避ける」)。スタンプは閉じた語彙(NudgeStamp /
// ReactionStamp)のみ。サーバー側正本は supabase/functions/_shared/messages.ts の
// NUDGE_STAMPS / REACTION_STAMPS — 語彙・順序を一致させる(クライアントは表示用の複製)

import Foundation

/// つつき(ナッジ)の6スタンプ(REQUIREMENTS §3.7)。
/// サーバー側 `_shared/messages.ts` の `NUDGE_STAMPS` と同じ語彙・同じ順序
enum NudgeStamp: String, CaseIterable, Equatable, Sendable {
    case wave = "👋"
    case clock = "⏰"
    case pray = "🙏"
    case megaphone = "📣"
    case huff = "😤"
    case sparkle = "✨"
}

/// リアクションの6スタンプ(REQUIREMENTS §3.8)。
/// サーバー側 `_shared/messages.ts` の `REACTION_STAMPS` と同じ語彙・同じ順序
enum ReactionStamp: String, CaseIterable, Equatable, Sendable {
    case heart = "❤️"
    case fire = "🔥"
    case clap = "👏"
    case laugh = "😂"
    case touched = "🥹"
    case muscle = "💪"
}

/// つつき送信の失敗理由(functions/nudge/core.ts のエラーコードに対応 — §3.7)。
/// `other` は通信エラー等、原因を問わない一般失敗(責めない文言で表示 — §3.5)
enum NudgeSendError: Error, Equatable {
    /// 1日3回まで(429 nudge_limit_exceeded)
    case limitReached
    /// 相手がすでに完了済み(409 partner_already_done。表示条件 canNudge で通常は防がれる)
    case partnerAlreadyDone
    case other
}

/// つつく(REQUIREMENTS §3.7「相手が未完のときだけ押せる。1日3回まで」)。
/// 1日3回のレート制限はサーバー正本(functions/nudge/core.ts)で判定する。クライアントは
/// 「相手が未完」でのみボタンを出す粗い出し分け(HomeViewModel.canNudge)に留め、
/// 超過時はサーバー応答(NudgeSendError)を責めない文言で表示する(§3.5)
protocol NudgeSending: AnyObject {
    func sendNudge(stamp: NudgeStamp) async throws
}

/// 相手の今日のチェックインへスタンプでリアクションする(REQUIREMENTS §3.8)。
/// 対象チェックインの特定(checkinId の解決)は実装詳細 — 本モックは当日の相手チェックインを
/// 前提に無条件で成功させる。実装側(本結線後)が実際の対象解決を担う
protocol Reacting: AnyObject {
    func sendReaction(stamp: ReactionStamp) async throws
}

// MARK: - LocalEchoCheckinService への適合(モック。本タスクのホーム結線用)
//
// サーバーも push も無く、常に成功を返すだけ(T13 の LocalEchoCheckinService 本体と同じ
// 「場つなぎ」方針)。実装の正本は functions/nudge, functions/react(deno test 済み・
// デプロイ無し — issue #15)

extension LocalEchoCheckinService: NudgeSending, Reacting {
    func sendNudge(stamp: NudgeStamp) async throws {
        // モック: 送信も永続化もしない(1日3回制限はサーバー実装側のみに存在する)
    }

    func sendReaction(stamp: ReactionStamp) async throws {
        // モック: 送信も永続化もしない(選択状態は HomeViewModel がセッション内のみ保持)
    }
}
