// ShareMilestone.swift — シェア画像の「節目」の判定と、もう出したかの記録(T22 / REQUIREMENTS §3.13)
//
// 節目の基準は **いまのストリークの日数**(7 / 30 / 100 / 365日)。GROWTH §6.6 の案 A を取り、
// 課金の柱である「ストリーク保険」(CONCEPT §6)を弱めない。ふたり達成の累計(案 B)は使わない。
// 節目は v1.0 では push せず、アプリ内のお祝いとシェア画像への誘導で扱う(TASKPLAN §9.4 の T16。
// サーバーから届く通知の ON/OFF が v1.1 でできるまで、オフにできない通知を増やさない)。
//
// 「もう出したか」は端末の中だけに持つ(サーバーには無い。ウィジェット・NSE も読まない)。
//   - 同じストリークの間は、同じ節目を一度だけ出す
//   - ストリークが途切れて新しいストリークが始まったら、そのストリークでまた節目を祝う
//     (同じ日数を何度も祝わないよう、ストリークの1日目を「アンカー」として記録する)
//   - この版を初めて起動したとき(既存の利用者)は、いまの節目を静かに記録してさかのぼって祝わない
//     (PlantMemory の段階アップと同じ扱い。アップデート直後に 30日・100日のお祝いを一度に見せない)
//   - アプリを何日か開かずに 7日 → 30日 と進んだときは、いちばん大きい節目(30日)だけを祝う
//
// 日付は「端末のローカル日の通し日数」(PlantDay。Calendar の ordinality)で持つ。夏時間・タイムゾーンを
// またいでも日の差が数えられる。保存の口は ShareMilestoneStoring(本実装 UserDefaults / テストはメモリ)。

import Foundation

// MARK: - 節目

/// シェア画像の節目(1回分)
struct ShareMilestone: Equatable, Identifiable, Sendable {
    /// 節目の日数(7 / 30 / 100 / 365)
    static let allDays = [7, 30, 100, 365]

    let pairId: String
    let days: Int
    /// このストリークの1日目の通し日数(ストリークが変わったかの判定に使う)
    let streakStartDay: Int

    var id: String { "\(pairId)#\(days)#\(streakStartDay)" }

    /// その日数までの、いちばん大きい節目(7日未満は nil)
    static func highest(atOrBelow days: Int) -> Int? {
        allDays.last { $0 <= days }
    }
}

// MARK: - 記録

/// 1ペアぶんの記録
struct ShareMilestoneRecord: Codable, Equatable, Sendable {
    /// 記録したときのストリークの1日目。変わったら「新しいストリーク」として祝い直す
    var streakStartDay: Int
    /// もう出した、いちばん大きい節目(まだ出していなければ 0)
    var celebratedDays: Int
}

/// 端末の中だけの記録(ペアごと)
struct ShareMilestoneMemory: Codable, Equatable, Sendable {
    /// この版で snapshot を1回でも見たか。false のうちに最初に見たペアは、いまの節目で静かに初期化する
    var initialized = false
    /// pairId → 記録
    var records: [String: ShareMilestoneRecord] = [:]

    init(initialized: Bool = false, records: [String: ShareMilestoneRecord] = [:]) {
        self.initialized = initialized
        self.records = records
    }

    // 将来キーを足しても、古い記録を読み捨てない(欠けているキーは初期値で埋める)
    private enum CodingKeys: String, CodingKey {
        case initialized, records
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        initialized = try c.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
        records = try c.decodeIfPresent([String: ShareMilestoneRecord].self, forKey: .records) ?? [:]
    }

    /// snapshot を見て、祝うべき節目があるかを決める。**記録は「出した」と確定するまで進めない**
    /// (markShown)。同じ snapshot をもう一度見ても、出していなければまた返る(呼び出し側が二重に出さない)。
    ///
    /// - この版の最初の観測(initialized が false): いまの節目を静かに記録して nil(さかのぼって祝わない)
    /// - 新しいペア(記録が無い): そのストリークで最初に届いた節目を祝う
    /// - 同じストリーク: 前回出した節目より大きいものだけ
    /// - ストリークが変わった(1日目が違う): 記録をそのストリークで作り直して、届いていれば祝う
    mutating func observe(pairId: String, streakDays: Int, streakStartDay: Int) -> ShareMilestone? {
        forgetOtherPairs(keeping: pairId)
        let highest = ShareMilestone.highest(atOrBelow: streakDays)

        // この版で最初に見たペアは、いまの節目を静かに記録する
        guard initialized else {
            initialized = true
            records[pairId] = ShareMilestoneRecord(
                streakStartDay: streakStartDay,
                celebratedDays: highest ?? 0
            )
            return nil
        }

        var record = records[pairId] ?? ShareMilestoneRecord(streakStartDay: streakStartDay, celebratedDays: 0)
        if record.streakStartDay != streakStartDay {
            // 新しいストリーク: そのストリークではまだ何も祝っていない
            record = ShareMilestoneRecord(streakStartDay: streakStartDay, celebratedDays: 0)
        }
        records[pairId] = record

        guard let highest, highest > record.celebratedDays else { return nil }
        return ShareMilestone(pairId: pairId, days: highest, streakStartDay: streakStartDay)
    }

    /// 節目のお祝いを、前面で実際に見せた。ここで初めて「出した」と記録する
    mutating func markShown(_ milestone: ShareMilestone) {
        guard var record = records[milestone.pairId], record.streakStartDay == milestone.streakStartDay else { return }
        record.celebratedDays = max(record.celebratedDays, milestone.days)
        records[milestone.pairId] = record
    }

    /// 今のペア以外の記録を忘れる(解消した旧ペアの ID を端末に残さない)。ソロ(pairId が nil)では全部忘れる
    mutating func forgetOtherPairs(keeping pairId: String?) {
        guard let pairId else {
            records.removeAll()
            return
        }
        records = records.filter { $0.key == pairId }
    }
}

// MARK: - 保存の口

protocol ShareMilestoneStoring: AnyObject {
    func load() -> ShareMilestoneMemory
    func save(_ memory: ShareMilestoneMemory)
    func reset()
}

extension ShareMilestoneStoring {
    /// サインアウト・アカウント削除のあと: 前のアカウントの記録を持ち越さない。
    /// initialized は true のまま残す(次のアカウントの新しいペアが 7日目に届いたら祝う)
    func reset() {
        save(ShareMilestoneMemory(initialized: true))
    }
}

/// UserDefaults 実装(アプリ本体の端末ローカル。App Group には置かない)
final class UserDefaultsShareMilestoneStore: ShareMilestoneStoring {
    static let key = "lien.shareMilestones.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ShareMilestoneMemory {
        guard
            let data = defaults.data(forKey: Self.key),
            let memory = try? JSONDecoder().decode(ShareMilestoneMemory.self, from: data)
        else { return ShareMilestoneMemory() }
        return memory
    }

    func save(_ memory: ShareMilestoneMemory) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// メモリ内の記録(プレビュー・テスト用)
final class InMemoryShareMilestoneStore: ShareMilestoneStoring {
    private var memory: ShareMilestoneMemory

    init(_ memory: ShareMilestoneMemory = ShareMilestoneMemory()) {
        self.memory = memory
    }

    func load() -> ShareMilestoneMemory { memory }

    func save(_ memory: ShareMilestoneMemory) { self.memory = memory }
}
