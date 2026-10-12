// PushTokenSync.swift — APNs デバイストークンと push_env の自動保存(issue #55 / REVIEW-2026-10-12 §2 M5)
//
// users.push_token(+ push_env)を最新に保つ。サーバー(checkin / nudge / react 等)が相手端末へ
// push を送るための宛先で、これが無いと本番ビルドで相手への通知・ウィジェット更新が届かない。
//
// 方針:
//   - **トークン取得とセッション確立の両方がそろうまで保留**する。順序はどちらが先でもよい
//     (既存ユーザーの起動時はトークンが後 / オンボ中は匿名サインインが先でトークンが後 /
//      通知許可済みで未サインインの起動はトークンが先)
//   - **変化時だけ送る**: 最後に送信に成功した (userID, token, env) を覚え、同じなら送らない。
//     ユーザーが変わった(再インストールで匿名ユーザーが作り直された)ときは同じトークンでも再送する
//   - 送信失敗(オフライン等)は保留のまま。次のトリガー(前面復帰・トークン更新・セッション確立)で再送する
//   - push_env は DEBUG ビルド = sandbox / それ以外 = production。Xcode 直インストールの development 署名は
//     sandbox の APNs、TestFlight / App Store は production の APNs に登録されるため、トークンごとに
//     サーバーが送信先のエンドポイントを選べるように環境も一緒に保存する(#53)
//
// このファイルは Foundation のみに依存する(テストは mock の registrar / ledger を注入)。

import Foundation

/// このトークンが属する APNs 環境(users.push_env — migration 0005 の check と同じ語彙)
enum PushEnvironment: String, Equatable, Sendable, Codable {
    case sandbox
    case production

    /// このビルドの APNs 環境(DEBUG = sandbox / それ以外 = production)
    static var current: PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

/// users 行の push_token / push_env を更新する口(本実装: SupabaseService。テストはモック)
protocol PushRegistrationUpdating: AnyObject {
    func updatePushRegistration(token: String, environment: PushEnvironment) async throws
}

/// サーバーに保存したい APNs 登録の1組
struct PushRegistration: Equatable, Codable, Sendable {
    let userID: String
    let token: String
    let environment: PushEnvironment
}

/// 最後に送信成功した登録の記録(「変化時だけ送る」の判定用)
protocol PushRegistrationLedger: AnyObject {
    var lastSynced: PushRegistration? { get set }
}

/// UserDefaults 実装(アプリ本体の端末ローカル。App Group には置かない — NSE / ウィジェットは読まない)。
/// 再インストールで消えるのは正しい挙動(新しい匿名ユーザー / 新しいトークンなので再送が必要)
final class UserDefaultsPushRegistrationLedger: PushRegistrationLedger {
    static let key = "lien.pushRegistration.lastSynced"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastSynced: PushRegistration? {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return nil }
            return try? JSONDecoder().decode(PushRegistration.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

/// メモリ内の記録(Config 未設定のスタブ構成・テスト用)
final class InMemoryPushRegistrationLedger: PushRegistrationLedger {
    var lastSynced: PushRegistration?
}

actor PushTokenSync {
    private let registrar: PushRegistrationUpdating
    private let currentUserID: () -> UUID?
    private let environment: PushEnvironment
    private let ledger: PushRegistrationLedger

    /// 最後に受け取ったデバイストークン(hex。未取得は nil)
    private(set) var token: String?
    private var isSending = false

    init(
        registrar: PushRegistrationUpdating,
        currentUserID: @escaping () -> UUID?,
        environment: PushEnvironment = .current,
        ledger: PushRegistrationLedger
    ) {
        self.registrar = registrar
        self.currentUserID = currentUserID
        self.environment = environment
        self.ledger = ledger
    }

    /// デバイストークンを受け取った(AppDelegate のコールバック → DeviceTokenStore 経由)
    func receive(token: String) async {
        self.token = token
        await flush()
    }

    /// セッションが確立した(匿名サインイン完了 / 起動時にセッションを復元)
    func sessionDidChange() async {
        await flush()
    }

    /// 送れる状態(トークン+セッション)で、前回送信成功した内容と違うときだけ送る。
    /// 失敗は握りつぶして保留にする(次のトリガーで再送)
    func flush() async {
        // 送信中の追加トリガーは、下のループが送信後に最新の宛先を再評価して拾う
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        // 送信中にトークンが更新された場合の再評価。記録が保存されない異常時に
        // 無限ループしないよう回数に上限を置く
        for _ in 0..<Self.maxSendsPerFlush {
            guard let desired = desiredRegistration(), desired != ledger.lastSynced else { return }
            do {
                try await registrar.updatePushRegistration(
                    token: desired.token,
                    environment: desired.environment
                )
                ledger.lastSynced = desired
            } catch {
                return // 保留: 前面復帰など次のトリガーで再送する
            }
        }
    }

    private static let maxSendsPerFlush = 3

    /// 今サーバーに置きたい登録。トークン未取得・未サインインなら nil(保留)
    private func desiredRegistration() -> PushRegistration? {
        guard let token, let userID = currentUserID() else { return nil }
        return PushRegistration(
            userID: userID.uuidString.lowercased(),
            token: token,
            environment: environment
        )
    }
}
