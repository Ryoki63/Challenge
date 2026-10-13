// NicknameRules.swift — ニックネームの検証(オンボーディングと設定のプロフィール編集で共通。REQUIREMENTS §3.1・§3.15)
//
// - DB の check 制約 `char_length(nickname) <= 8`(migration 0001)は Unicode コードポイントの数で数えるので、
//   unicodeScalars.count で数える(肌色修飾つきの絵文字のように、1文字に見えて2スカラーのものも DB とずれない — issue #10)
// - 前後の空白・改行は除いてから検証し、保存するのも除いたあとの値。空白だけの入力は空と同じ
// - Foundation だけに依存する純粋な関数(テストが直接呼ぶ)

import Foundation

/// ニックネームの検証エラー(REQUIREMENTS §3.1: 8字まで)
enum NicknameError: Equatable {
    case empty
    case tooLong
}

enum NicknameRules {
    /// ニックネームの最大の長さ(Unicode コードポイント数)。DB の check と同じ
    static let maxLength = 8

    /// 前後の空白・改行を除いた、保存用のニックネーム
    static func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 検証の結果。nil なら有効(trimmed(raw) を保存してよい)
    static func validate(_ raw: String) -> NicknameError? {
        let trimmed = trimmed(raw)
        if trimmed.isEmpty { return .empty }
        if trimmed.unicodeScalars.count > maxLength { return .tooLong }
        return nil
    }
}
