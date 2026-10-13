// PlantMemory.swift — 植物の体験が「端末の中だけ」で覚えておくこと(段階アップの演出を1回だけ出す記録ほか / issue #57)
//
// 状態の正はサーバーで、アプリが永続するのは App Group の snapshot と未送信キューだけ(DESIGN §3.3)。
// ここに置くのは、画面の状態ではなく**「もう見せたか」の記録**で、サーバーには無く、ウィジェット・NSE も読まない。
// なので App Group ではなく、アプリ本体の UserDefaults に置く(PushTokenSync の ledger と同じ扱い。再インストールで消えるのは正しい挙動):
//
//   - 段階アップの全画面演出(GROWTH §5.2): pairId ごとの「最後にお祝いした段階」
//       * 各段階で1回だけ。段階0(ペア成立の「はじめまして」)も含む
//       * 新しいバージョンを初めて起動したときは、今の段階で静かに初期化する(過去の段階をさかのぼって祝わない)
//       * 取り消しで段階が戻ったあと、また同じ段階に上がっても、もう一度は見せない(記録は戻らない)
//       * **「見せた」と記録するのは、演出を前面で実際に表示したとき**(markCelebrated)。snapshot を観測した時点では記録しない:
//         サイレント push で起こされたバックグラウンドのプロセスが snapshot を観測して、そのまま終了すると、
//         その段階の演出を一度も見せないまま失ってしまう(PB の Opus レビュー)
//   - 相手が名前を付けた・変えたことの知らせ(GROWTH §5.3): pairId ごとの「最後に見た名前」。初めて付けたときと変えたときで文言を分ける
//   - おかえり(GROWTH §4.4): 自分が最後にチェックインした日(「端末の中だけで判定」。空いた日数は表示しない)
//   - 今日のひとこと(GROWTH §5.5): 最後にひとことを出した日
//   - 自分が最後にリアクションを送った日: その日のうちは「ハートを送る」を出さない(付け替えは相手に届かないため)
//   - **ペアごとの記録は、今のペアのものだけを残す**: 解消した旧ペアの植物の名前(相手が付けた UGC)を端末に残さない
//
// 判定はすべて純粋な mutating 関数(PlantMemory)。保存の口は PlantMemoryStoring(本実装 UserDefaults / テストはメモリ)。
// 日付は「端末のローカル日の通し日数」(Calendar の ordinality。夏時間・タイムゾーンをまたいでも日の差が数えられる)で持つ。

import Foundation

// MARK: - 段階アップの演出

/// 段階アップの全画面演出(1回分)。段階0 = ペア成立の「はじめまして」
struct StageCelebration: Equatable, Identifiable, Sendable {
    let pairId: String
    /// お祝いする段階(0〜9。アプリが知らない大きい段階は 9 に丸めてある)
    let stage: Int
    /// 前回お祝いした(= ユーザーが最後に見た)段階。無ければ nil(ペア成立の直後など)
    let previousStage: Int?
    /// 成長回数(ふたり達成日の累計)。新しいキーが無い snapshot では nil
    let grownDays: Int?

    var id: String { "\(pairId)#\(stage)" }

    /// ペア成立の「はじめまして」(段階0)
    var isFirstMeeting: Bool { stage == 0 }

    /// 名前を付ける演出を添える段階(最初の「ふたば」— GROWTH §5.3。ペア成立の直後ではなく、最初の成功と結びつける)
    var offersNaming: Bool { stage == 1 }

    /// 「変わる前」の植物の段階。段階0は、ソロの土の中で眠る姿(nil)。複数の段階を一度に飛んだときは、最後に見た段階
    var beforeStage: Int? {
        guard stage > 0 else { return nil }
        return previousStage ?? (stage - 1)
    }
}

/// 1回の観測(snapshot を見たとき)で起きること
struct PlantObservation: Equatable, Sendable {
    /// 出すべき段階アップの演出。**記録はまだ更新していない** — 表示したあとに `PlantMemory.markCelebrated` で記録する
    var celebration: StageCelebration?
    /// 相手が付けた・変えた名前(「名前が『みどり』にかわったよ」を出す)。なければ nil
    var changedName: String?
    /// changedName が、このペアで初めて見る名前か(= 相手が初めて名前を付けた。「かわったよ」でなく「なったよ」を出す)
    var isFirstName = false
}

// MARK: - 記録

struct PlantMemory: Codable, Equatable, Sendable {
    /// おかえり: 前回のチェックインからこの日数(日付の差)以上あいたら出す。
    /// 「2日以上チェックインしていなかったあと」= 間の日が2日以上 = 日付の差が 3 以上(GROWTH §4.4)
    static let welcomeBackMinGapDays = 3

    /// このアプリの版で、snapshot を1回でも見たか。false のうちに最初に見たペアの snapshot は、その段階で静かに初期化する
    /// (新しいバージョンを初めて起動した既存のペアが、過去の段階を一度に祝われないように — GROWTH §5.2)
    var initialized = false
    /// pairId → 最後にお祝いした段階(0〜9)
    var celebratedStage: [String: Int] = [:]
    /// pairId → 最後に見た植物の名前
    var seenName: [String: String] = [:]
    /// 自分が最後にチェックインした日(端末のローカル日の通し日数)
    var lastCheckinDay: Int?
    /// 今日のひとことを最後に出した日(同じ)
    var lastWhisperDay: Int?
    /// 自分が最後にリアクション(どのスタンプでも)を送った日(同じ)
    var lastReactionDay: Int?

    init(
        initialized: Bool = false,
        celebratedStage: [String: Int] = [:],
        seenName: [String: String] = [:],
        lastCheckinDay: Int? = nil,
        lastWhisperDay: Int? = nil,
        lastReactionDay: Int? = nil
    ) {
        self.initialized = initialized
        self.celebratedStage = celebratedStage
        self.seenName = seenName
        self.lastCheckinDay = lastCheckinDay
        self.lastWhisperDay = lastWhisperDay
        self.lastReactionDay = lastReactionDay
    }

    // 将来キーを足しても、古い記録を読み捨てない(欠けているキーは初期値で埋める)
    private enum CodingKeys: String, CodingKey {
        case initialized, celebratedStage, seenName, lastCheckinDay, lastWhisperDay, lastReactionDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        initialized = try c.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
        celebratedStage = try c.decodeIfPresent([String: Int].self, forKey: .celebratedStage) ?? [:]
        seenName = try c.decodeIfPresent([String: String].self, forKey: .seenName) ?? [:]
        lastCheckinDay = try c.decodeIfPresent(Int.self, forKey: .lastCheckinDay)
        lastWhisperDay = try c.decodeIfPresent(Int.self, forKey: .lastWhisperDay)
        lastReactionDay = try c.decodeIfPresent(Int.self, forKey: .lastReactionDay)
    }

    // MARK: 段階アップ・名前の知らせ

    /// snapshot を見て、段階アップの演出と名前の知らせが要るかを決める。
    /// **段階アップの記録(celebratedStage)は、ここでは更新しない**(演出を実際に見せたあとに markCelebrated で記録する)。
    /// なので、まだ見せていない演出は、同じ snapshot をもう一度見ても、また返る(呼び出し側が、出している演出と同じか見て、二重に出さない)
    mutating func observe(_ snapshot: PairSnapshot) -> PlantObservation {
        forgetOtherPairs(keeping: snapshot.pairId)
        let wasInitialized = initialized
        let celebration = observeStage(snapshot)
        // 演出と同時のときは名前を知らせない(演出の中で名前を見せる)。最初の観測(初期化)でも知らせない
        let change = observeName(snapshot, announce: wasInitialized && celebration == nil)
        return PlantObservation(celebration: celebration, changedName: change?.name, isFirstName: change?.isFirst ?? false)
    }

    /// 段階アップの演出を出すか。
    ///   - ソロ(pairId が null)は出さない(記録に触れない)
    ///   - 版の最初の観測(initialized が false): 今の段階で静かに初期化(過去をさかのぼって祝わない。見せるものが無いので、ここで記録する)
    ///   - ふだん: 記録の段階(無ければ -1)より今の段階が大きいときだけ返す。記録は更新しない(markCelebrated)。
    ///     取り消しで段階が戻っても、記録は戻さない(同じ段階にまた上がっても、もう一度は祝わない)
    ///   - アプリが知らない大きい段階は 9(みのり)に丸めて比べる(1.0.1 の花壇の段階で、みのりを繰り返し祝わない)
    mutating func observeStage(_ snapshot: PairSnapshot) -> StageCelebration? {
        defer { initialized = true }
        guard let pairId = snapshot.pairId else { return nil }
        let stage = PlantLayers.clampedStage(snapshot.plantStage)
        guard initialized else {
            celebratedStage[pairId] = stage
            return nil
        }
        let previous = celebratedStage[pairId]
        guard stage > (previous ?? -1) else { return nil }
        return StageCelebration(
            pairId: pairId,
            stage: stage,
            previousStage: previous,
            grownDays: snapshot.plantGrownDays
        )
    }

    /// 段階アップの演出を、前面で実際に見せた。ここで初めて「見せた」と記録する(戻さない: 取り消しで段階が下がった記録の上書きはしない)
    mutating func markCelebrated(_ celebration: StageCelebration) {
        celebratedStage[celebration.pairId] = max(celebratedStage[celebration.pairId] ?? -1, celebration.stage)
    }

    /// 相手が付けた・変えた名前の知らせ(次に開いたとき — GROWTH §5.3)。見た名前を覚える。
    /// 自分が付けた名前は recordOwnName で先に覚えておくので、ここでは知らせない。
    /// announce が false のとき(版の最初の観測・演出と同時)は、覚えるだけで知らせない。
    /// isFirst: このペアで見た名前が1つも無かった = 相手が初めて付けた
    mutating func observeName(_ snapshot: PairSnapshot, announce: Bool) -> (name: String, isFirst: Bool)? {
        guard let pairId = snapshot.pairId, let name = snapshot.plantName, !name.isEmpty else { return nil }
        let previous = seenName[pairId]
        guard previous != name else { return nil }
        seenName[pairId] = name
        return announce ? (name, previous == nil) : nil
    }

    /// 今のペア以外の記録を忘れる(解消した旧ペアの、相手が付けた植物の名前を端末に残さない)。
    ///   - ペアのとき: そのペアのぶんだけ残す(段階の記録も、旧ペアのものは要らない)
    ///   - ソロ(pairId が null)のとき: 名前だけ全部忘れる(相手が付けた UGC。段階の記録には触れない — ソロは記録に触れない方針)
    mutating func forgetOtherPairs(keeping pairId: String?) {
        guard let pairId else {
            seenName.removeAll()
            return
        }
        celebratedStage = celebratedStage.filter { $0.key == pairId }
        seenName = seenName.filter { $0.key == pairId }
    }

    /// 自分が付けた・変えた名前(自分には「かわったよ」を出さない)
    mutating func recordOwnName(pairId: String, name: String) {
        seenName[pairId] = name
    }

    // MARK: おかえり

    /// 自分のチェックインが完了した。前回から welcomeBackMinGapDays 日以上あいていたら true(おかえりを出す)。
    /// 初めて(記録が無い)・日付が戻った(端末の時計が過去になった)ときは false。いずれも、今日の日付を覚える
    mutating func noteMyCheckin(day: Int) -> Bool {
        defer { lastCheckinDay = day }
        guard let last = lastCheckinDay else { return false }
        return day - last >= Self.welcomeBackMinGapDays
    }

    // MARK: 今日のひとこと

    /// その日はじめてホームを開いたか(true なら、今日のぶんを出したと覚える)
    mutating func claimWhisper(day: Int) -> Bool {
        guard lastWhisperDay != day else { return false }
        lastWhisperDay = day
        return true
    }

    // MARK: リアクション

    /// 自分がリアクションを送った(どのスタンプでも)。サーバーの react は、相手の同じチェックインへの2回目以降を
    /// 付け替え(上書き)にして、相手へ通知を送り直さない。その日のうちは「ハートを送る」を出さない
    mutating func noteReaction(day: Int) {
        lastReactionDay = day
    }

    func hasReacted(day: Int) -> Bool {
        lastReactionDay == day
    }
}

// MARK: - 保存の口

protocol PlantMemoryStoring: AnyObject {
    func load() -> PlantMemory
    func save(_ memory: PlantMemory)
}

extension PlantMemoryStoring {
    /// アカウントの削除・サインアウトのあと: 記録を消す(次のアカウントのペアに、前のアカウントの記録を持ち越さない。
    /// おかえりが、前のアカウントの最後のチェックイン日からの日数で誤って出るのも防ぐ)。
    /// 「版の最初の観測を済ませた」(initialized)は残す: 次のアカウントで最初にできたペアは、新しいペアなので
    /// 「はじめまして」を祝う(静かに初期化してしまわない)
    func reset() {
        save(PlantMemory(initialized: true))
    }
}

/// UserDefaults 実装(アプリ本体の端末ローカル。App Group には置かない — NSE・ウィジェットは読まない)。
/// 壊れた記録は、初期値として読む(演出を見せる側に倒す方が危うい: 初期値は「版の最初の観測」= 静かな初期化)
final class UserDefaultsPlantMemoryStore: PlantMemoryStoring {
    static let key = "lien.plantMemory.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PlantMemory {
        guard
            let data = defaults.data(forKey: Self.key),
            let memory = try? JSONDecoder().decode(PlantMemory.self, from: data)
        else { return PlantMemory() }
        return memory
    }

    func save(_ memory: PlantMemory) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// メモリ内の記録(プレビュー・テスト用。保存しない構成の既定)
final class InMemoryPlantMemoryStore: PlantMemoryStoring {
    private var memory: PlantMemory

    init(_ memory: PlantMemory = PlantMemory()) {
        self.memory = memory
    }

    func load() -> PlantMemory { memory }

    func save(_ memory: PlantMemory) { self.memory = memory }
}
