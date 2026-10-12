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
//   - push_env は署名の aps-environment から決める(APNsEnvironment.swift。issue #28)。Xcode 直インストールの
//     development 署名は sandbox の APNs、TestFlight / App Store は production の APNs に登録されるため、
//     トークンごとにサーバーが送信先のエンドポイントを選べるように環境も一緒に保存する(#53)。
//     コンパイル設定(DEBUG / Release)では決めない — Release を development 署名で入れた端末を取り違えるため
//   - **サーバー側のずれを直す**(issue #62): サーバーは APNs が 410 / BadDeviceToken を返したトークンの
//     users.push_token を null にする(apns.ts)。端末の記録(ledger)は「送信済み」のままなので、変化時だけ送る
//     仕組みだけでは二度と戻らない。そこで、記録の上では送信済みのときに限り、プロセスの最初の1回と
//     前面復帰のたび(前回の確認から minVerifyInterval 以上あけて)に、自分の users.push_token / push_env を
//     読んで、送ったはずの内容とずれていれば記録を捨てて送り直す
//
// このファイルは Foundation のみに依存する(テストは mock の registrar / ledger を注入)。

import Foundation

/// このトークンが属する APNs 環境(users.push_env — migration 0005 の check と同じ語彙)。
/// このビルドの環境(`PushEnvironment.current`)の判定は APNsEnvironment.swift
enum PushEnvironment: String, Equatable, Sendable, Codable {
    case sandbox
    case production
}

/// users 行に今入っている APNs 登録(自分の行を読んだ結果)
struct ServerPushRegistration: Equatable, Sendable {
    /// users.push_token。サーバーが 410 / BadDeviceToken で無効にした後は nil
    let token: String?
    /// users.push_env。未設定(従来の行)は nil
    let environment: PushEnvironment?
}

/// users 行の push_token / push_env を更新・参照する口(本実装: SupabaseService。テストはモック)
protocol PushRegistrationUpdating: AnyObject {
    func updatePushRegistration(token: String, environment: PushEnvironment) async throws
    /// 自分の users 行の push_token / push_env を読む(サーバー側で無効にされていないかの確認用)
    func fetchPushRegistration() async throws -> ServerPushRegistration
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
    /// サーバーの登録を読んで確かめる最短間隔(前面復帰のたびに読みに行かない)。
    /// プロセスの最初の確認(トークンとセッションがそろった最初の機会)は、この間隔に関係なく行う
    static let minVerifyInterval: TimeInterval = 60 * 60

    private let registrar: PushRegistrationUpdating
    private let currentUserID: () -> UUID?
    private let environment: PushEnvironment
    private let ledger: PushRegistrationLedger
    private let now: () -> Date

    /// 最後に受け取ったデバイストークン(hex。未取得は nil)
    private(set) var token: String?
    private var isSending = false
    /// サーバーの登録を最後に読めた時刻(このプロセスの中だけ。起動直後は nil = 最初の機会に必ず確かめる)
    private var lastVerifiedAt: Date?

    init(
        registrar: PushRegistrationUpdating,
        currentUserID: @escaping () -> UUID?,
        environment: PushEnvironment = .current,
        ledger: PushRegistrationLedger,
        now: @escaping () -> Date = Date.init
    ) {
        self.registrar = registrar
        self.currentUserID = currentUserID
        self.environment = environment
        self.ledger = ledger
        self.now = now
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
    /// 記録の上では送信済みのときは、サーバー側で無効にされていないかを(間隔をあけて)確かめ、ずれていれば送り直す。
    /// 失敗は握りつぶして保留にする(次のトリガーで再送)
    func flush() async {
        // 送信中の追加トリガーは、下のループが送信後に最新の宛先を再評価して拾う
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        await discardRecordIfServerDiffers()

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

    /// 記録の上では送信済みの登録について、サーバーの実際の値を読んで確かめる。
    /// ずれていれば(push_token が null にされた / 別の値 / push_env が未設定)記録を捨て、
    /// 続く送信ループが同じ内容を送り直す。
    /// 確かめるのはプロセスの最初の1回と、前回の確認から minVerifyInterval 以上たったときだけ。
    /// 読めなかった(オフライン等)ときは何もせず、次のトリガーで改めて確かめる
    private func discardRecordIfServerDiffers() async {
        // 記録と違う(= どのみち送る)なら、確かめるまでもない
        guard let desired = desiredRegistration(), desired == ledger.lastSynced else { return }
        if let last = lastVerifiedAt {
            // 時計が巻き戻っても(elapsed < 0)、確認が永遠に先送りにならないよう「間隔があいた」扱いにする
            let elapsed = now().timeIntervalSince(last)
            if elapsed >= 0, elapsed < Self.minVerifyInterval { return }
        }

        let server: ServerPushRegistration
        do {
            server = try await registrar.fetchPushRegistration()
        } catch {
            return
        }
        lastVerifiedAt = now()
        if server.token != desired.token || server.environment != desired.environment {
            ledger.lastSynced = nil
        }
    }

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
