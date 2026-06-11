// Promise.swift — 約束のモデル+promise-set API のレスポンス(T12)
//
// 契約の正本はサーバー実装:
//   - promise-set/core.ts の PromiseRow(id / title / emoji / remindAt)と
//     PromiseSetResult の 200 body({ promise, created })
// JSON デコードは PairSnapshot.makeJSONDecoder() を使うこと(コーダ設定を1か所に揃える)。
//
// 仕様(REQUIREMENTS §3.3):
//   - 1人1つ。タイトル(20字)+絵文字+リマインド時刻(任意)
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
    /// リマインド時刻 "HH:MM"(なしは nil)。ローカル通知のスケジューリングは T16 の責務
    let remindAt: String?
}

/// POST /promise-set の 200 応答(promise-set/core.ts PromiseSetResult.body)
struct PromiseSetResponse: Equatable, Sendable, Codable {
    let promise: Promise
    /// true = 新規作成 / false = 既存の約束の更新(id 不変)
    let created: Bool
}
