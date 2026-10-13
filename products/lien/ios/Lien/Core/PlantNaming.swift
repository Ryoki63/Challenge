// PlantNaming.swift — 植物の名前付け(入力の検査・結果・抽象・スタブ / issue #57 / docs/GROWTH.md §5.3)
//
// 名前を付ける・変えるのは、新しい Edge Function plant-name(DESIGN §5.3)。実 HTTP 実装は Api/PlantNameAPIClient.swift
// (EdgeFunctionPlantNaming)。この抽象(PlantNaming)を、ViewModel(PlantNamingModel)が使う。
//
// 仕様の要点(サーバーが正本。ここはその写し):
//   - first: まだ名前が無いときだけ書く。**先に付けた人の名前に決まる**。すでに名前があれば 409 already_named(今の名前つき)
//   - rename: 上書き(名前がまだ無くても書ける。今の名前と同じなら何も起きない)
//   - **名前を付けた本人が first を再送した**(通信失敗のあとの再試行など)ときも 409 が返る(自分の名前がすでに入っているので)。
//     サーバーは誰が付けたかを返さないので、クライアントは 409 の name が**自分が送った名前と同じなら成功**として扱い、
//     違えば**相手が先に付けた**(その名前を採用する)と読む(PlantNameConflict)
//   - 誰が付けたかは、アプリ内には書かない(再インストールで「自分が付けたか」の記録が消えて、誤って表示するおそれがあるため)
//
// 名前の検査(PlantNameRules)はサーバーの normalizePlantName と同じ規則:
//   NFC に正規化し、前後の空白を除き、**Unicode コードポイントで 1〜8字**(`String.count` は書記素クラスタ数で、
//   「🏳️‍🌈」は 1 でもサーバーは 4 と数える。`unicodeScalars.count` で数える)。制御文字・行/段落区切り・書式文字
//   (双方向制御・ゼロ幅スペース・BOM など)・見える文字が1つも無い名前は使えない。**絵文字をつなぐ ZWJ(U+200D)だけ許す**。
//   VS16(U+FE0F。「❤️」)は結合記号なので通る。
//
// Foundation だけに依存する(テストが直接呼ぶ)。

import Foundation

// MARK: - 入力の検査

/// 名前の入力のエラー(表示は Strings.Plant.name*Error)
enum PlantNameError: Equatable {
    case empty
    case tooLong
    /// 改行・見えない文字・向きを変える制御文字など
    case invalidCharacter
}

enum PlantNameRules {
    /// 名前の最大の長さ(Unicode コードポイント数。ニックネームと同じ 8 字 — サーバーの PLANT_NAME_MAX_LENGTH)
    static let maxLength = 8

    /// 絵文字をつなぐ ZWJ(U+200D)。書式文字(Cf)のうち、名前に許す唯一のもの(サーバーの ALLOWED_FORMAT_CHARS)
    private static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"

    /// 送る名前: NFC に正規化し、前後の空白・改行を除く(サーバーと同じ手順。途中の空白は残す)
    static func normalized(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 検査の結果。nil なら使える(normalized(raw) を送ってよい)
    static func validate(_ raw: String) -> PlantNameError? {
        let name = normalized(raw)
        if name.isEmpty { return .empty }
        if name.unicodeScalars.count > maxLength { return .tooLong }
        var hasVisibleScalar = false
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .surrogate:
                // 改行・タブ・NUL など / 行・段落区切り / 対になっていないサロゲート
                return .invalidCharacter
            case .format:
                // 双方向制御・ゼロ幅スペース・語結合子・BOM・ソフトハイフンなど。ZWJ だけ許す(ただし見える文字ではない)
                if scalar != zeroWidthJoiner { return .invalidCharacter }
            case .spaceSeparator:
                break // 途中の空白は許す(見える文字ではない)
            default:
                hasVisibleScalar = true
            }
        }
        // 空白・ZWJ だけの名前は、見える文字が1つも無い
        return hasVisibleScalar ? nil : .invalidCharacter
    }
}

// MARK: - 結果

/// 名前を送った結果
enum PlantNameOutcome: Equatable, Sendable {
    /// 自分の送った名前が入った(first の再送で、同じ名前がすでに入っていた場合を含む)
    case saved(name: String)
    /// first で、相手が先に付けていた(409 already_named)。その名前に決まった
    case adopted(name: String)
}

enum PlantNameConflict {
    /// first の 409 already_named の読み方: サーバーの今の名前が自分の送った名前と同じなら成功(自分の再送)、
    /// 違えば相手が先に付けた。比べるのは、どちらも検査と同じ整え方(NFC・前後の空白除去)をしたあとの文字列
    static func resolveFirst(sent: String, current: String) -> PlantNameOutcome {
        PlantNameRules.normalized(sent) == PlantNameRules.normalized(current)
            ? .saved(name: current)
            : .adopted(name: current)
    }
}

// MARK: - 抽象

enum PlantNameMode: String, Equatable, Sendable {
    /// 最初に付ける(まだ名前が無いときだけ書く。先に付けた人の名前に決まる)
    case first
    /// あとから変える(上書き)
    case rename
}

protocol PlantNaming: AnyObject {
    /// 植物の名前を付ける・変える。名前は検査(PlantNameRules)を通ったものを渡す
    /// (通らないときは PlantNameClientError.invalidName を投げる)。失敗は PlantNameClientError など
    func setName(_ name: String, mode: PlantNameMode) async throws -> PlantNameOutcome
}

// MARK: - スタブ(Config 未設定のアプリ実行・プレビュー用。StubAccountClient と同じ役割)

/// サーバーが無い環境の名前付け。サーバーと同じ規則で、端末の snapshot の plantName を書き換える
/// (ペアが無ければ no_pair・first で名前がすでにあれば相手が先に付けた扱い)
final class StubPlantNaming: PlantNaming {
    private let store: AppGroupStore?

    init(store: AppGroupStore?) {
        self.store = store
    }

    func setName(_ name: String, mode: PlantNameMode) async throws -> PlantNameOutcome {
        guard PlantNameRules.validate(name) == nil else { throw PlantNameClientError.invalidName }
        let normalized = PlantNameRules.normalized(name)
        guard let snapshot = store?.loadSnapshot(), snapshot.pairId != nil else {
            throw PlantNameClientError.noPair
        }
        if mode == .first, let current = snapshot.plantName, !current.isEmpty {
            return PlantNameConflict.resolveFirst(sent: normalized, current: current)
        }
        // 端末の snapshot への反映は、呼び出し側(HomeViewModel.applyPlantName)が行う
        return .saved(name: normalized)
    }
}

extension PairSnapshot {
    /// 植物の名前だけを差し替えたコピー(ほかの値は触らない。名前を付けたあとの端末の snapshot の更新に使う)
    func withPlantName(_ name: String, updatedAt: Date? = nil) -> PairSnapshot {
        var copy = self
        copy.plantName = name
        if let updatedAt { copy.updatedAt = updatedAt }
        return copy
    }
}
