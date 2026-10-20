// PairSnapshot.swift — App Group 共有契約の正本モデル(DESIGN §3.4。schemaVersion = 1)
//
// JSON スキーマ(キー名は §3.4 と一字一句一致。変更時は要レビュー+JOURNALに互換性影響を明記):
//
//   {
//     "schemaVersion": 1,
//     "pairId": "uuid | null(ソロ状態)",
//     "updatedAt": "ISO8601",
//     "streakCurrent": 23,
//     "streakBest": 40,
//     "todayMeDone": true,
//     "todayPartnerDone": false,
//     "myPromiseTitle": "筋トレ", "myPromiseEmoji": "💪",
//     "partnerName": "ゆうき",
//     "partnerPromiseTitle": "ランニング", "partnerPromiseEmoji": "🏃",
//     "plantStage": 3,
//     "plantGrownDays": 9,
//     "plantStageFloor": 7,
//     "plantNextStageAt": 14,
//     "plantMood": "normal | happy | fidget | sad",
//     "plantName": "みどり",
//     "hasPartnerPhotoToday": false,
//     "ticketBalance": 2,
//     "pairPlan": "free | premium"
//   }
//
// - snapshot は**受信者視点**でサーバーが組み立てる(me/partner をクライアントで反転しない — §3.4)
// - デコードは境界として防御的に:
//   * 未知キーは無視(前方互換)
//   * pairId は null を許容(ソロ状態)
//   * 未知の plantMood は .normal にフォールバック
//   * schemaVersion / updatedAt 以外は欠落時にデフォルト値で埋める
//   * 成長ルール v2 の新キー3つ(plantGrownDays / plantStageFloor / plantNextStageAt。DESIGN §3.4)は**省略可**:
//     無いとき(古いサーバー・古いキャッシュ)は nil のまま持ち、画面はゲージを出さない(0 で埋めると、
//     表示が「0回」と出てちらつく — GROWTH §8.6)。型が違っても snapshot 全体を壊さず nil として扱う
//   * お休みチケットの残数(ticketBalance。DESIGN §3.4)は**省略可**: 無い(古いサーバー・古いキャッシュ)・
//     null(ソロ、またはサーバーが残数を読めていない)は nil のまま持ち、ホームはバッジを出さない。
//     0 は「0枚」の有効な値として持ち、バッジを出す(罰なし — REQUIREMENTS §3.5)。型が違っても壊さず nil
// - このファイルは Lien / LienWidget / LienNSE の3ターゲットでソース共有される(project.yml 参照)。
//   Foundation 以外に依存させないこと。

import Foundation

/// 植物の表情(REQUIREMENTS §3.9。枯れ・後退の状態は存在しない)
enum PlantMood: String, Equatable, Sendable {
    /// 通常
    case normal
    /// 両者完了のキラキラ
    case happy
    /// 片方未完のそわそわ
    case fidget
    /// 2日連続未達成のしょんぼり
    case sad
}

/// ペアのプラン(REQUIREMENTS §3.14 / §5)。メンバーの users.premium_until からサーバーが導出する
/// (plan カラムは持たない)。アプリは「自分の購読 ∪ pairPlan == .premium」でプレミアムを判定する
enum PairPlan: String, Codable, Equatable, Sendable {
    case free
    case premium
}

extension PlantMood: Codable {
    /// 未知の値は .normal にフォールバック(サーバー側が表情を追加しても古いアプリが壊れない)
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlantMood(rawValue: raw) ?? .normal
    }
}

/// App Group コンテナ `pair_snapshot.json` の中身。
/// 状態の正はサーバーで、アプリ/ウィジェットはこれを表示するだけ(DESIGN §3.3)。
struct PairSnapshot: Equatable, Sendable {
    /// 本実装が読み書きするスキーマ版
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// ペア ID(uuid 文字列)。null = ソロ状態(ペア未成立)
    var pairId: String?
    /// サーバーが snapshot を組み立てた時刻(ISO8601)
    var updatedAt: Date
    var streakCurrent: Int
    var streakBest: Int
    var todayMeDone: Bool
    var todayPartnerDone: Bool
    var myPromiseTitle: String?
    var myPromiseEmoji: String?
    var partnerName: String?
    var partnerPromiseTitle: String?
    var partnerPromiseEmoji: String?
    /// 成長段階 0〜9(0 = たね 〜 9 = みのり。GROWTH §3.3 / DESIGN §3.4)。ソロは 0。
    /// アプリが知らない大きい段階が来たら、描くときは知っている最大の段階として扱う(PlantLayers)
    var plantStage: Int
    /// 成長回数(ふたり達成日の累計。GROWTH §3.2)。ソロは 0。nil = このキーが無い(→ ゲージを出さない)
    var plantGrownDays: Int? = nil
    /// 今の段階に入る回数(サーバーの閾値配列の `plantStage` 番目)。ソロは 0。nil = このキーが無い
    var plantStageFloor: Int? = nil
    /// 次の段階に必要な回数。サーバーは、最後の段階(みのり)とソロでは `null` を明示して返す(キーは省略しない)。
    /// アプリでは、`plantGrownDays` / `plantStageFloor` があって、これが nil なら「次の段階が無い」と読む
    /// (3つとも nil = キーが無い古いサーバー → ゲージを出さない。判定は PlantProgress)
    var plantNextStageAt: Int? = nil
    var plantMood: PlantMood
    var plantName: String?
    var hasPartnerPhotoToday: Bool
    /// お休みチケットの残数(ペア共有の在庫。`pairs.ticket_balance`。DESIGN §3.4)。
    /// 0 以上の整数。**0 は有効**(0枚でもホームにバッジを出す — 罰なし)。nil = キーが無い(古いサーバー・
    /// 古いキャッシュ)・null(ソロ、またはサーバーが残数を読めていない)・型違い → バッジを出さない。
    /// ペアの2人に同じ値が見える(受信者視点で反転しない)
    var ticketBalance: Int? = nil
    /// ペアのプラン(pairPlan)。メンバーのどちらかがプレミアムなら .premium。
    /// キーが無い(古いサーバー・古いキャッシュ)・未知の値は .free(課金していない側に倒す)
    var pairPlan: PairPlan = .free
}

// MARK: - Codable(§3.4 のキー名と一字一句一致させる)

extension PairSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case pairId
        case updatedAt
        case streakCurrent
        case streakBest
        case todayMeDone
        case todayPartnerDone
        case myPromiseTitle
        case myPromiseEmoji
        case partnerName
        case partnerPromiseTitle
        case partnerPromiseEmoji
        case plantStage
        case plantGrownDays
        case plantStageFloor
        case plantNextStageAt
        case plantMood
        case plantName
        case hasPartnerPhotoToday
        case ticketBalance
        case pairPlan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // schemaVersion と updatedAt は契約の必須キー。それ以外は防御的にデフォルトで埋める
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        pairId = try c.decodeIfPresent(String.self, forKey: .pairId)
        streakCurrent = try c.decodeIfPresent(Int.self, forKey: .streakCurrent) ?? 0
        streakBest = try c.decodeIfPresent(Int.self, forKey: .streakBest) ?? 0
        todayMeDone = try c.decodeIfPresent(Bool.self, forKey: .todayMeDone) ?? false
        todayPartnerDone = try c.decodeIfPresent(Bool.self, forKey: .todayPartnerDone) ?? false
        myPromiseTitle = try c.decodeIfPresent(String.self, forKey: .myPromiseTitle)
        myPromiseEmoji = try c.decodeIfPresent(String.self, forKey: .myPromiseEmoji)
        partnerName = try c.decodeIfPresent(String.self, forKey: .partnerName)
        partnerPromiseTitle = try c.decodeIfPresent(String.self, forKey: .partnerPromiseTitle)
        partnerPromiseEmoji = try c.decodeIfPresent(String.self, forKey: .partnerPromiseEmoji)
        plantStage = try c.decodeIfPresent(Int.self, forKey: .plantStage) ?? 0
        // 成長ルール v2 の新キー: 省略可。無い・null・型違いは nil(try? は decodeIfPresent の Optional をそのまま返す)
        plantGrownDays = try? c.decodeIfPresent(Int.self, forKey: .plantGrownDays)
        plantStageFloor = try? c.decodeIfPresent(Int.self, forKey: .plantStageFloor)
        plantNextStageAt = try? c.decodeIfPresent(Int.self, forKey: .plantNextStageAt)
        plantMood = try c.decodeIfPresent(PlantMood.self, forKey: .plantMood) ?? .normal
        plantName = try c.decodeIfPresent(String.self, forKey: .plantName)
        hasPartnerPhotoToday = try c.decodeIfPresent(Bool.self, forKey: .hasPartnerPhotoToday) ?? false
        // 残数: 省略可。無い・null・型違いは nil(バッジを出さない)。0 はそのまま 0(0枚でもバッジを出す)
        ticketBalance = try? c.decodeIfPresent(Int.self, forKey: .ticketBalance)
        // プラン: 省略可。無い・null・未知の値・型違いは free(課金していない側に倒す)
        pairPlan = (try? c.decodeIfPresent(PairPlan.self, forKey: .pairPlan)) ?? .free
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(pairId, forKey: .pairId) // nil は明示的に null として書く(§3.4 "uuid | null")
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(streakCurrent, forKey: .streakCurrent)
        try c.encode(streakBest, forKey: .streakBest)
        try c.encode(todayMeDone, forKey: .todayMeDone)
        try c.encode(todayPartnerDone, forKey: .todayPartnerDone)
        try c.encode(myPromiseTitle, forKey: .myPromiseTitle)
        try c.encode(myPromiseEmoji, forKey: .myPromiseEmoji)
        try c.encode(partnerName, forKey: .partnerName)
        try c.encode(partnerPromiseTitle, forKey: .partnerPromiseTitle)
        try c.encode(partnerPromiseEmoji, forKey: .partnerPromiseEmoji)
        try c.encode(plantStage, forKey: .plantStage)
        // 新キーは、持っているときだけ書く(キーが無い snapshot を、書き出しで「0回」などに変えない)。
        // 成長回数と段階の下限があるときは、次の段階も明示する(最後の段階は null — サーバーの形と同じ。DESIGN §3.4)
        try c.encodeIfPresent(plantGrownDays, forKey: .plantGrownDays)
        try c.encodeIfPresent(plantStageFloor, forKey: .plantStageFloor)
        if plantGrownDays != nil || plantStageFloor != nil {
            try c.encode(plantNextStageAt, forKey: .plantNextStageAt)
        } else {
            try c.encodeIfPresent(plantNextStageAt, forKey: .plantNextStageAt)
        }
        try c.encode(plantMood, forKey: .plantMood)
        try c.encode(plantName, forKey: .plantName)
        try c.encode(hasPartnerPhotoToday, forKey: .hasPartnerPhotoToday)
        // 残数は、nil でもキーを省略せず null で書く(サーバーの形と同じ。DESIGN §3.4「キーは省略せず null で出す」)
        try c.encode(ticketBalance, forKey: .ticketBalance)
        try c.encode(pairPlan, forKey: .pairPlan)
    }
}

// MARK: - 現役の約束

extension PairSnapshot {
    /// 自分の現役の約束があるか(サーバーはタイトル未設定を null で返す。空白だけも未設定扱い)。
    /// AppRouter(画面の系統)・ローカル通知の計画(アプリと NSE の両方)が使うので、共有の型に置く
    var hasActivePromise: Bool {
        guard let title = myPromiseTitle else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - JSON コーダ(updatedAt の ISO8601 を許容的に扱う)

extension PairSnapshot {
    /// pair_snapshot.json / プッシュペイロード用のデコーダ。
    /// ISO8601 は小数秒あり・なしの両方を受け付ける(サーバー実装差に耐える)
    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = ISO8601Parser.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "ISO8601 として解釈できない日時文字列: \(raw)"
                )
            }
            return date
        }
        return decoder
    }

    /// pair_snapshot.json 用のエンコーダ(ISO8601・キー順固定で diff 可読)
    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// ISO8601 文字列のパース(小数秒あり/なし両対応)。ISO8601DateFormatter はスレッドセーフ
enum ISO8601Parser {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        withFractionalSeconds.date(from: raw) ?? plain.date(from: raw)
    }
}

// MARK: - 日付跨ぎ(ウィジェットの2点目エントリ用 — DESIGN §3.5)

extension PairSnapshot {
    /// 翌日 0:00 のエントリ用に「両者未完」表示へ戻したコピーを返す(DESIGN §3.5)。
    /// 表情は通常に戻す(前日の表情を持ち越さない。枯れ・後退の演出はしない — REQUIREMENTS §3.9)
    func resettingForNewDay() -> PairSnapshot {
        var copy = self
        copy.todayMeDone = false
        copy.todayPartnerDone = false
        copy.hasPartnerPhotoToday = false
        copy.plantMood = .normal
        return copy
    }
}

/// 日付境界の計算。タイムゾーンは端末ローカル = ユーザーの date_local(DESIGN §9。既定 Asia/Tokyo)
enum DayBoundary {
    /// `date` が属するローカル日の「翌日 0:00」を返す
    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? date.addingTimeInterval(24 * 60 * 60)
    }
}
