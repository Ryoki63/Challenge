// Config.swift — Supabase 接続情報の読み込み(DESIGN §3.3, §7)
//
// 値の流れ: Secrets.xcconfig(gitignore 済み)→ Base.xcconfig の変数
//   → project.yml が Info.plist に埋め込み → 本構造体が Bundle から読む。
// CI には Secrets.xcconfig が無く空文字になるため、その場合は nil を返す
// (呼び出し側は StubAuthService にフォールバックしてビルド・テストを通す — issue #10)

import Foundation

struct Config {
    static let supabaseURLInfoPlistKey = "SUPABASE_URL"
    static let supabaseAnonKeyInfoPlistKey = "SUPABASE_ANON_KEY"

    let supabaseURL: URL
    let supabaseAnonKey: String

    /// Info.plist から読み込む。未設定(空文字)・URL として不正なら nil
    static func load(bundle: Bundle = .main) -> Config? {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: supabaseURLInfoPlistKey) as? String,
            !urlString.isEmpty,
            let url = URL(string: urlString),
            let anonKey = bundle.object(forInfoDictionaryKey: supabaseAnonKeyInfoPlistKey) as? String,
            !anonKey.isEmpty
        else { return nil }
        return Config(supabaseURL: url, supabaseAnonKey: anonKey)
    }
}
