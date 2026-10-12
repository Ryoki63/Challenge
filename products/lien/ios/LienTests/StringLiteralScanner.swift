// StringLiteralScanner.swift — Swift ソースから文字列リテラルを拾う小さな字句解析器(issue #62)
//
// StringsReviewTests が Strings.swift の文言を「書いた通りに」全件拾うための道具。
// 文言を足したのに lint の対象へ登録し忘れる、という事故をなくす(足した瞬間から検査される)。
//
// 対応する構文は Strings.swift が実際に使うものに絞り、それ以外が出てきたら黙って読み飛ばさず throw する:
//   - 対応   : "…"(エスケープ \n \t \r \0 \" \' \\ \u{…} と、補間 \( … ))、行コメント //、ブロックコメント /* */(ネスト可)
//   - 非対応 : """ 複数行リテラル、#"…"# 生文字列(使いたくなったらここを拡張する)
//
// Foundation のみに依存する(macOS のコマンドラインでもコンパイルできる)。

import Foundation

enum StringLiteralScanner {
    /// ソース上の文字列リテラル1つ
    struct Literal: Equatable {
        /// 補間 `\( … )` の位置で分けた固定部分(エスケープは解決済み)。補間が無ければ要素は1つ
        let fragments: [String]
        /// ソース上の行(1 始まり。リテラルが始まる行)
        let line: Int

        var hasInterpolation: Bool { fragments.count > 1 }

        /// 補間の位置を ⟨…⟩ で示した、メッセージ用の表示
        var display: String { fragments.joined(separator: "⟨…⟩") }
    }

    enum ScanError: Error, CustomStringConvertible {
        case unsupported(String, line: Int)
        case unterminated(line: Int)

        var description: String {
            switch self {
            case .unsupported(let what, let line):
                return "\(line) 行目: 未対応の構文(\(what))。StringLiteralScanner を拡張してください"
            case .unterminated(let line):
                return "\(line) 行目から始まる文字列リテラルが閉じていません"
            }
        }
    }

    /// source に書かれた文字列リテラルをすべて返す(コメントの中は含めない。補間の中に入れ子になったリテラルも拾う)
    static func literals(in source: String) throws -> [Literal] {
        var lexer = Lexer(source: source)
        return try lexer.run()
    }
}

// MARK: - 字句解析

private struct Lexer {
    typealias Literal = StringLiteralScanner.Literal
    typealias ScanError = StringLiteralScanner.ScanError

    private let chars: [Character]
    private var index = 0
    private var line = 1
    private var found: [Literal] = []

    init(source: String) {
        chars = Array(source)
    }

    mutating func run() throws -> [Literal] {
        while index < chars.count {
            let c = chars[index]
            if c.isNewline {
                line += 1
                index += 1
            } else if c == "/", peek(1) == "/" {
                // 行コメント: 行末まで読み飛ばす(コメントの中の " は文言ではない)
                while index < chars.count, !chars[index].isNewline { index += 1 }
            } else if c == "/", peek(1) == "*" {
                try skipBlockComment()
            } else if c == "#", startsRawString() {
                throw ScanError.unsupported("生文字列 #\"…\"#", line: line)
            } else if c == "\"" {
                if peek(1) == "\"", peek(2) == "\"" {
                    throw ScanError.unsupported("複数行文字列 \"\"\"", line: line)
                }
                try readLiteral()
            } else {
                index += 1
            }
        }
        return found
    }

    private func peek(_ offset: Int) -> Character? {
        let i = index + offset
        return i < chars.count ? chars[i] : nil
    }

    /// `#` の連なりの直後が `"` なら生文字列(`#if` や `#Preview(` は違う)
    private func startsRawString() -> Bool {
        var i = index
        while i < chars.count, chars[i] == "#" { i += 1 }
        return i < chars.count && chars[i] == "\""
    }

    private mutating func skipBlockComment() throws {
        let startLine = line
        var depth = 1
        index += 2
        while depth > 0 {
            guard index < chars.count else { throw ScanError.unterminated(line: startLine) }
            if chars[index] == "/", peek(1) == "*" {
                depth += 1
                index += 2
            } else if chars[index] == "*", peek(1) == "/" {
                depth -= 1
                index += 2
            } else {
                if chars[index].isNewline { line += 1 }
                index += 1
            }
        }
    }

    /// index が開き `"` を指している状態で呼ぶ。閉じ `"` の次まで進め、リテラルを found に足す
    private mutating func readLiteral() throws {
        let startLine = line
        index += 1 // 開き "
        var fragments: [String] = []
        var current = ""
        while true {
            guard index < chars.count, !chars[index].isNewline else {
                throw ScanError.unterminated(line: startLine)
            }
            let c = chars[index]
            if c == "\"" {
                index += 1
                break
            }
            guard c == "\\" else {
                current.append(c)
                index += 1
                continue
            }

            // エスケープ
            index += 1
            guard index < chars.count else { throw ScanError.unterminated(line: startLine) }
            let e = chars[index]
            switch e {
            case "n": current.append("\n"); index += 1
            case "t": current.append("\t"); index += 1
            case "r": current.append("\r"); index += 1
            case "0": current.append("\0"); index += 1
            case "\"": current.append("\""); index += 1
            case "'": current.append("'"); index += 1
            case "\\": current.append("\\"); index += 1
            case "u":
                current.unicodeScalars.append(try readUnicodeEscape())
            case "(":
                // 補間: ここまでを固定部分として確定し、式の終わりまで読み飛ばす
                fragments.append(current)
                current = ""
                index += 1
                try skipInterpolation(literalLine: startLine)
            default:
                throw ScanError.unsupported("エスケープ \\\(e)", line: line)
            }
        }
        fragments.append(current)
        found.append(Literal(fragments: fragments, line: startLine))
    }

    /// `\u{1F600}` の `u` を指している状態で呼び、`}` の次まで進める
    private mutating func readUnicodeEscape() throws -> Unicode.Scalar {
        guard peek(1) == "{" else { throw ScanError.unsupported("\\u の形式", line: line) }
        index += 2
        var hex = ""
        while index < chars.count, chars[index] != "}" {
            hex.append(chars[index])
            index += 1
        }
        guard index < chars.count, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw ScanError.unsupported("\\u{\(hex)}", line: line)
        }
        index += 1 // }
        return scalar
    }

    /// `\(` の次を指している状態で呼び、対応する `)` の次まで進める。
    /// 式の中の文字列リテラルも文言になり得る(`"\(flag ? "あり" : "なし")"`)ので、readLiteral で拾う
    private mutating func skipInterpolation(literalLine: Int) throws {
        var depth = 1
        while depth > 0 {
            guard index < chars.count else { throw ScanError.unterminated(line: literalLine) }
            let c = chars[index]
            if c == "(" {
                depth += 1
                index += 1
            } else if c == ")" {
                depth -= 1
                index += 1
            } else if c == "\"" {
                try readLiteral()
            } else {
                if c.isNewline { line += 1 }
                index += 1
            }
        }
    }
}
