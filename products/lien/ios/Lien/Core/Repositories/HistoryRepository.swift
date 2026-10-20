// HistoryRepository.swift — カレンダー履歴のデータ取得(T18 / REQUIREMENTS §3.11)
//
// Live 実装は PostgREST を直接読む(新しい Edge Function は増やさない):
//   - pairs        : 自分のペア(id / started_on / status)。RLS pairs_select_member の範囲
//   - checkins     : その月の自分の行と、現役ペアの相手の行。RLS checkins_select_pair の範囲
//   - streak_days  : その月の確定行(kind = both | ticket)。RLS streak_days_select_member の範囲
//
// 解消済みのペアでも、自分の checkins と streak_days は RLS の範囲で読める
// (REQUIREMENTS §3.2「自分のチェックイン履歴は残る」)。相手の行は現役ペアのときだけ読めるので、
// 解消後のカレンダーは自分の印だけになる(サーバーが隠している以上、クライアントで補わない)。
//
// 画面の状態判定は HistoryCalendarBuilder(純粋関数)が行う。この層は「サーバーの行をそのまま返す」だけ。

import Foundation

/// カレンダー履歴の取得口。ViewModel にはこのプロトコルだけを渡す(テストはモック)
protocol HistoryRepository: AnyObject {
    /// 指定した月の履歴。ペアが無いときは pairStartedOn = nil の空データ
    func fetchMonth(_ month: HistoryMonth) async throws -> MonthHistoryData
}

enum HistoryRepositoryError: Error, Equatable {
    /// まだサインインしていない(トークンが無い)
    case notSignedIn
    /// 通信エラー(オフライン・タイムアウト等)
    case network
    /// 401 / 403(トークン失効など)
    case unauthorized
    /// 上記以外の HTTP エラー
    case server(Int)
    /// 応答を読めない(JSON の形が違う等)
    case invalidResponse
}

// MARK: - 本実装(PostgREST)

final class PostgRESTHistoryRepository: HistoryRepository {
    /// 通信が不安定でも、月の切り替えを長く待たせない
    static let requestTimeout: TimeInterval = 15

    private let baseURL: URL
    private let apiKey: String
    private let tokenProvider: () async throws -> String
    private let currentUserID: () -> UUID?
    private let session: URLSession
    private let calendar: Calendar

    init(
        baseURL: URL,
        apiKey: String,
        tokenProvider: @escaping () async throws -> String,
        currentUserID: @escaping () -> UUID?,
        session: URLSession = .shared,
        calendar: Calendar = .lienHistory
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tokenProvider = tokenProvider
        self.currentUserID = currentUserID
        self.session = session
        self.calendar = calendar
    }

    func fetchMonth(_ month: HistoryMonth) async throws -> MonthHistoryData {
        guard let myID = currentUserID() else { throw HistoryRepositoryError.notSignedIn }

        let pairs = try await fetchPairs()
        // 現役のペアを優先する(解消済みのペアしか無いときは、その最後のペアの履歴を出す)
        guard let pair = pairs.first(where: { $0.status == "active" }) ?? pairs.first else {
            return .empty
        }

        let range = month.dateLocalRange(calendar: calendar)
        let checkins = try await fetchCheckins(first: range.first, last: range.last)
        let streakDays = try await fetchStreakDays(
            pairID: pair.id,
            first: range.first,
            last: range.last
        )

        var mine = Set<String>()
        var partner = Set<String>()
        let myIDString = myID.uuidString.lowercased()
        for row in checkins {
            if row.userID.lowercased() == myIDString {
                mine.insert(row.dateLocal)
            } else {
                // RLS により、自分以外で読めるのは現役ペアの相手だけ
                partner.insert(row.dateLocal)
            }
        }

        var streak: [String: StreakDayKind] = [:]
        for row in streakDays {
            // 未知の kind(将来の追加)は無視する。既知の行だけで判定する
            if let kind = StreakDayKind(rawValue: row.kind) {
                streak[row.dateLocal] = kind
            }
        }

        return MonthHistoryData(
            pairStartedOn: pair.startedOn,
            myCheckinDays: mine,
            partnerCheckinDays: partner,
            streakDays: streak
        )
    }

    // MARK: 取得

    private func fetchPairs() async throws -> [PairRow] {
        let data = try await get(
            "rest/v1/pairs",
            query: [
                URLQueryItem(name: "select", value: "id,started_on,status"),
                URLQueryItem(name: "order", value: "created_at.desc"),
            ]
        )
        return try decode([PairRow].self, from: data)
    }

    private func fetchCheckins(first: String, last: String) async throws -> [CheckinRow] {
        let data = try await get(
            "rest/v1/checkins",
            query: [
                URLQueryItem(name: "select", value: "user_id,date_local"),
                URLQueryItem(name: "date_local", value: "gte.\(first)"),
                URLQueryItem(name: "date_local", value: "lte.\(last)"),
                URLQueryItem(name: "order", value: "date_local.asc"),
            ]
        )
        return try decode([CheckinRow].self, from: data)
    }

    private func fetchStreakDays(pairID: String, first: String, last: String) async throws -> [StreakDayRow] {
        let data = try await get(
            "rest/v1/streak_days",
            query: [
                URLQueryItem(name: "select", value: "date_local,kind"),
                URLQueryItem(name: "pair_id", value: "eq.\(pairID.lowercased())"),
                URLQueryItem(name: "date_local", value: "gte.\(first)"),
                URLQueryItem(name: "date_local", value: "lte.\(last)"),
                URLQueryItem(name: "order", value: "date_local.asc"),
            ]
        )
        return try decode([StreakDayRow].self, from: data)
    }

    // MARK: HTTP

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        let token = try await tokenProvider()
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query
        guard let url = components?.url else {
            throw HistoryRepositoryError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HistoryRepositoryError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw HistoryRepositoryError.network
        }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw HistoryRepositoryError.unauthorized
        default:
            throw HistoryRepositoryError.server(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HistoryRepositoryError.invalidResponse
        }
    }
}

// MARK: - PostgREST の行

private struct PairRow: Decodable {
    let id: String
    let startedOn: String
    let status: String

    private enum CodingKeys: String, CodingKey {
        case id
        case startedOn = "started_on"
        case status
    }
}

private struct CheckinRow: Decodable {
    let userID: String
    let dateLocal: String

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case dateLocal = "date_local"
    }
}

private struct StreakDayRow: Decodable {
    let dateLocal: String
    let kind: String

    private enum CodingKeys: String, CodingKey {
        case dateLocal = "date_local"
        case kind
    }
}

// MARK: - スタブ(Config 未設定の CI・開発ビルド用)

/// サーバーが無い環境でも画面と月移動を動かせる、決まった形のサンプル。
/// 本番の表示(RLS・close-day の確定)は Live 実装だけが扱う。
final class StubHistoryRepository: HistoryRepository {
    private let calendar: Calendar
    private let now: () -> Date

    init(calendar: Calendar = .lienHistory, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
    }

    func fetchMonth(_ month: HistoryMonth) async throws -> MonthHistoryData {
        let today = now()
        let currentMonth = HistoryMonth.containing(today, calendar: calendar)
        let startedOn = HistoryDate.string(from: currentMonth.firstDate(calendar: calendar), calendar: calendar)
        // 今月以外(過去の月)は、成立前の空の月として返す
        guard month == currentMonth else {
            return MonthHistoryData(pairStartedOn: startedOn)
        }

        let todayDay = calendar.component(.day, from: today)
        var mine = Set<String>()
        var partner = Set<String>()
        var streak: [String: StreakDayKind] = [:]
        // 1〜5日のサンプル(今日以降は作らない)。両者達成・お休み・片方だけ・記録なしを一通り含める
        for day in 1...max(1, min(5, todayDay)) {
            guard let date = calendar.date(
                from: DateComponents(year: month.year, month: month.month, day: day, hour: 12)
            ) else { continue }
            let dateLocal = HistoryDate.string(from: date, calendar: calendar)
            switch day {
            case 1, 4:
                mine.insert(dateLocal)
                partner.insert(dateLocal)
                streak[dateLocal] = .both
            case 2:
                mine.insert(dateLocal)
                streak[dateLocal] = .ticket
            case 3:
                partner.insert(dateLocal)
            default:
                break
            }
        }
        return MonthHistoryData(
            pairStartedOn: startedOn,
            myCheckinDays: mine,
            partnerCheckinDays: partner,
            streakDays: streak
        )
    }
}
