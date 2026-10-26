// Promise.swift — 約束のモデル+promise-set API のレスポンス(T12)
//
// 契約の正本はサーバー実装:
//   - promise-set/core.ts の PromiseRow(id / title / emoji / remindAt)と
//     PromiseSetResult の 200 body({ promise, created })
// JSON デコードは PairSnapshot.makeJSONDecoder() を使うこと(コーダ設定を1か所に揃える)。
//
// 仕様(REQUIREMENTS §3.3):
//   - 1人1つ。タイトル(20字)+絵文字+リマインド時刻(任意)
//     ※ 絵文字は 2026-10-26 のオーナー判断で UI から廃止した(画面で選ばせない・見せない)。サーバーの promise-set が
//     emoji を必須とするため、データとしては残り、クライアントは固定値を送る(PromiseSetupViewModel.placeholderEmoji)
//   - いつでも編集可。編集はサーバー側で同一 promise_id への UPDATE になるため
//     ストリーク・チェックイン履歴に影響しない(寛容設計)

import Foundation

/// 自分の約束(サーバー promises 行の API 表現)
struct Promise: Equatable, Sendable, Codable {
    /// タイトルの最大字数。サーバー(promise-set/core.ts PROMISE_TITLE_MAX_LENGTH)と
    /// DB の check 制約 char_length(title) <= 20 に一致。
    /// 字数は Unicode コードポイント(Swift では unicodeScalars)で数える
    static let titleMaxLength = 20

    /// promises.id(uuid 文字列)。編集しても変わらない(checkins FK 継続 — §3.3)
    let id: String
    let title: String
    let emoji: String
    /// リマインド時刻 "HH:MM"(なしは nil)。毎日のローカル通知の時刻で、予約は ReminderScheduler(T16 #16)。
    /// 約束設定の画面と通知の設定画面のどちらから変えても、この値(サーバーの約束)を書く
    let remindAt: String?
}

/// POST /promise-set の 200 応答(promise-set/core.ts PromiseSetResult.body)
struct PromiseSetResponse: Equatable, Sendable, Codable {
    let promise: Promise
    /// true = 新規作成 / false = 既存の約束の更新(id 不変)
    let created: Bool
}
