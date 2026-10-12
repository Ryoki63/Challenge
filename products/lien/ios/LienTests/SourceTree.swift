// SourceTree.swift — リポジトリ内のファイル(ソース・マニフェスト・アセット)の場所と読み込み(issue #28)
//
// リリース準備のテスト(PrivacyManifestTests / ReleaseReadinessTests)が、アプリに同梱される設定ファイルと
// Swift ソースを「書いた通りに」読むための道具。シミュレータはホストのファイルを読めるので、
// CI でも #filePath からソースの場所をそのまま辿れる(StringsReviewTests・ContractFixtures と同じ方式)。

import Foundation

enum SourceTree {
    /// products/lien/ios/(このファイルは products/lien/ios/LienTests/ にある)
    static func iosRoot(from file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // LienTests
            .deletingLastPathComponent() // ios
    }

    /// products/lien/
    static func lienRoot(from file: StaticString = #filePath) -> URL {
        iosRoot(from: file).deletingLastPathComponent()
    }

    /// ios/ からの相対パスのファイルの中身
    static func data(_ relativePath: String, file: StaticString = #filePath) throws -> Data {
        let url = iosRoot(from: file).appendingPathComponent(relativePath)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw fileError(relativePath, url: url, error: error)
        }
    }

    /// products/lien/ からの相対パスのファイルの中身(assets/ など ios/ の外)
    static func lienData(_ relativePath: String, file: StaticString = #filePath) throws -> Data {
        let url = lienRoot(from: file).appendingPathComponent(relativePath)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw fileError(relativePath, url: url, error: error)
        }
    }

    /// ios/ からの相対パスの plist(エンタイトルメント・マニフェスト・ExportOptions)を辞書として読む
    static func plist(_ relativePath: String, file: StaticString = #filePath) throws -> [String: Any] {
        let data = try data(relativePath, file: file)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(
                domain: "SourceTree",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(relativePath) が辞書の plist ではありません"]
            )
        }
        return dictionary
    }

    /// ios/ からの相対パスの JSON(Asset Catalog の Contents.json など)を辞書として読む
    static func json(_ relativePath: String, file: StaticString = #filePath) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try data(relativePath, file: file))
        guard let dictionary = object as? [String: Any] else {
            throw NSError(
                domain: "SourceTree",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "\(relativePath) が辞書の JSON ではありません"]
            )
        }
        return dictionary
    }

    /// ios/ からの相対パスのテキスト
    static func text(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        guard let text = String(data: try data(relativePath, file: file), encoding: .utf8) else {
            throw NSError(
                domain: "SourceTree",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(relativePath) が UTF-8 ではありません"]
            )
        }
        return text
    }

    /// ios/ からの相対ディレクトリの下にある .swift を(再帰的に)すべて、ios/ からの相対パスで返す
    static func swiftFiles(under relativeDirectory: String, file: StaticString = #filePath) throws -> [String] {
        let root = iosRoot(from: file)
        let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            throw NSError(
                domain: "SourceTree",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(relativeDirectory) を開けません(\(directory.path))"]
            )
        }
        // /var と /private/var のような別名の差を除いてから、ios/ からの相対パスにする
        let rootPath = root.resolvingSymlinksInPath().path
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return paths.sorted()
    }

    private static func fileError(_ relativePath: String, url: URL, error: Error) -> NSError {
        NSError(
            domain: "SourceTree",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(relativePath) が読めません(\(url.path)): \(error)"]
        )
    }
}
