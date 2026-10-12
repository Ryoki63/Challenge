// Config.swift — Supabase 接続情報の読み込み(DESIGN §3.3, §7)
//
// 値の流れ: Secrets.xcconfig(gitignore 済み)→ Base.xcconfig の変数
//   → project.yml が Info.plist に埋め込み → 本構造体が Bundle から読む。
// CI(lien-ios)には Secrets.xcconfig が無く空文字になるため、その場合は nil を返す。
// Debug ではその nil を受けて Stub 構成にフォールバックし、ビルド・テストを通す(issue #10)。
// **Release(TestFlight / App Store に出るビルド)では黙って Stub に落とさない**(issue #28):
// 接続情報の無いビルドを配ってしまうと、誰の端末でもペアになれず、原因も分からないため。
// 起動時に明示エラーで止める(MissingPolicy.fatal)。さらに lien-release は archive の Info.plist を
// 検査して、接続情報の無い archive を TestFlight へ上げる前に落とす(ios/scripts/supabase_config.py)。

import Foundation

struct Config {
    static let supabaseURLInfoPlistKey = "SUPABASE_URL"
    static let supabaseAnonKeyInfoPlistKey = "SUPABASE_ANON_KEY"

    let supabaseURL: URL
    let supabaseAnonKey: String

    /// Info.plist から読み込む。未設定(空文字・雛形のまま・変数が展開されずに残った値)・URL として不正なら nil
    static func load(bundle: Bundle = .main) -> Config? {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: supabaseURLInfoPlistKey) as? String,
            !isUnset(urlString),
            let url = URL(string: urlString),
            let anonKey = bundle.object(forInfoDictionaryKey: supabaseAnonKeyInfoPlistKey) as? String,
            !isUnset(anonKey)
        else { return nil }
        return Config(supabaseURL: url, supabaseAnonKey: anonKey)
    }

    /// 「設定されていない」とみなす値。
    ///   - 空文字(Base.xcconfig の既定。Secrets.xcconfig が無い)
    ///   - Secrets.example.xcconfig の雛形をそのままコピーした値(YOUR-PROJECT-REF / YOUR_SUPABASE_ANON_KEY)
    ///   - xcconfig の変数が展開されずに Info.plist に残った値(`$(SUPABASE_URL)`)
    static func isUnset(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed.contains("YOUR-PROJECT-REF")
            || trimmed.contains("YOUR_SUPABASE_ANON_KEY")
            || trimmed.hasPrefix("$(")
    }
}

// MARK: - Config が無いときの扱い

extension Config {
    /// Config(Supabase 接続情報)が無いときに何をするか
    enum MissingPolicy: Equatable, Sendable {
        /// Stub 構成にフォールバックする(Debug / CI / Secrets を置いていない開発ビルド)
        case fallBackToStub
        /// 起動時に明示エラーで止める(Release = TestFlight / App Store に出るビルド)
        case fatal

        /// ビルド構成の既定。Debug は Stub、Release は致命
        static var buildDefault: MissingPolicy {
            #if DEBUG
            return .fallBackToStub
            #else
            return .fatal
            #endif
        }
    }

    /// Config が無いまま `.fatal` で起動しようとしたときのエラー。AppServices.make が fatalError にする
    /// (クラッシュログの「Fatal error:」の後ろにこの説明が出る)
    struct MissingError: Error, Equatable, CustomStringConvertible {
        var description: String { Config.missingMessage }
    }

    static let missingMessage = """
    Supabase の接続情報がこのビルドにありません(Info.plist の \(supabaseURLInfoPlistKey) / \(supabaseAnonKeyInfoPlistKey) が空)。\
    Release ビルドは接続情報なしでは起動しません(Stub に黙って落とさない)。\
    ios/Config/Secrets.example.xcconfig を Secrets.xcconfig にコピーして実値を入れるか、\
    TestFlight へのアップロードは GitHub Actions の lien-release(secrets の SUPABASE_URL / SUPABASE_ANON_KEY から生成)を使ってください。
    """
}
