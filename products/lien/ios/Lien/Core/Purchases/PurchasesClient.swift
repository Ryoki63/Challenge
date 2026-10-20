// PurchasesClient.swift — 課金(RevenueCat)の抽象(T33 / REQUIREMENTS §3.14)
//
// View / ViewModel はこのプロトコルだけを知り、RevenueCat SDK を直接触らない。
// - Live 構成: RevenueCatPurchasesClient(RevenueCat SDK)
// - API キーが無い CI・プレビュー・テスト: MockPurchasesClient(メモリ)
// - 本番で API キーが無いとき: UnavailablePurchasesClient(購入画面は「いまは購入できません」)
//
// 価格・トライアル日数は **必ず offerings から取る**。コードに「700円」「17日」を書かない
// (価格とトライアルは G6/T37 で最終化する。REQUIREMENTS §3.14)。
//
// 課金の正は RevenueCat。サーバー(users.premium_until)は Webhook で更新される控えで、
// アプリは「自分の購読 ∪ snapshot.pairPlan」でプレミアムを判定する(EntitlementStore)。

import Foundation

/// 購入画面に出す1プラン。表示に必要なのは id・種類・価格・トライアルだけ
struct PaywallPackage: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case monthly
        case yearly
        case other
    }

    /// RevenueCat の package identifier(購入時にそのまま渡す)
    let id: String
    let kind: Kind
    /// StoreKit が地域・通貨に合わせて整形した価格(例: "¥700")。コードで組み立てない
    let priceLabel: String
    /// 無料トライアルの日数。無ければ nil(日数をコードに書かない)
    let trialDays: Int?

    /// 年額を推す(REQUIREMENTS §3.14)。プランが年額だけ・月額だけのときも、その1つを主役にする
    var isRecommended: Bool { kind == .yearly }
}

/// いま表示できるプラン一式
struct PaywallOfferings: Equatable, Sendable {
    let packages: [PaywallPackage]

    var monthly: PaywallPackage? { packages.first { $0.kind == .monthly } }
    var yearly: PaywallPackage? { packages.first { $0.kind == .yearly } }
    /// 表示するプラン(月→年の順)。未知の種類は出さない
    var displayPackages: [PaywallPackage] {
        [monthly, yearly].compactMap { $0 }
    }
    /// トライアル日数(プランから取れたものの最大)。無ければ nil
    var trialDays: Int? { packages.compactMap(\.trialDays).max() }
}

/// 購入・復元の結果(自分の購読の状態)
struct PurchasesSnapshot: Equatable, Sendable {
    /// プレミアム entitlement が有効か
    let isActive: Bool
    /// プレミアム entitlement の期限。nil = 購読していない(または期限の無い購読)
    let premiumUntil: Date?

    init(isActive: Bool, premiumUntil: Date?) {
        self.isActive = isActive
        self.premiumUntil = premiumUntil
    }

    /// 期限から作る(期限があれば有効)
    init(premiumUntil: Date?) {
        self.init(isActive: premiumUntil != nil, premiumUntil: premiumUntil)
    }

    /// 購読していない
    static let none = PurchasesSnapshot(isActive: false, premiumUntil: nil)
}

/// 課金の失敗。画面の文言は Strings.Paywall が持ち、ここは種別だけ
enum PurchasesError: Error, Equatable, Sendable {
    /// API キーが無い・SDK を構成できない(本番で設定漏れ)
    case unavailable
    /// 利用者が購入画面を閉じた(エラーとして責めない)
    case cancelled
    /// 購入が保留(Ask to Buy など)。あとで完了する
    case pending
    /// 通信・ストアの失敗
    case failed(String)
}

/// 課金の入口。実装は RevenueCat / メモリ / 利用不可の3つ
protocol PurchasesClient: Sendable {
    /// Supabase の user id で RevenueCat にログインする(Webhook の app_user_id と一致させる規約。
    /// ログインしないと users.premium_until を更新できない)
    func logIn(userID: String) async
    /// いま表示できるプラン。API キーが無い実装は .unavailable を投げる
    func offerings() async throws -> PaywallOfferings
    /// packageID を購入する。成功したら自分の購読の期限を返す
    func purchase(packageID: String) async throws -> PurchasesSnapshot
    /// 過去の購入を復元する
    func restore() async throws -> PurchasesSnapshot
    /// いまの自分の購読の状態(キャッシュ)。起動時の表示に使う
    func currentEntitlement() async -> PurchasesSnapshot
}
