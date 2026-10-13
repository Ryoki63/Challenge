// PlantExperienceModel.swift — ホームの植物まわりの「体験」の状態(issue #57 / docs/GROWTH.md §4.4・§5.2・§5.3・§5.5)
//
// HomeViewModel が1つ持つ。snapshot が変わるたび(HomeViewModel.load / apply)に snapshotDidChange を受け、次を決める:
//   - 段階アップの全画面演出(presentation = .stageUp): 各段階で1回だけ。ペア成立の「はじめまして」(段階0)も含む
//       (記録の仕方・版の最初の観測・取り消しのあとの再到達は PlantMemory.observeStage)
//   - 相手が植物の名前を付けた・変えた知らせ(nameNotice): 次に開いたとき(PlantMemory.observeName)
//   - おかえり(presentation = .welcomeBack): 自分が2日以上チェックインしていなかったあと、自分がチェックインした瞬間だけ
//       (HomeViewModel.performCheckin が myCheckinCompleted を呼ぶ。段階アップの演出と重なるときは、段階アップだけ)
//   - 今日のひとこと(whisper): その日はじめてホームを開いたとき、吹き出しで短く(数秒で消える。植物のタップでもう一度)
//
// 画面に出すのは HomeView(演出は全画面のオーバーレイ、知らせは植物の下、吹き出しは植物の上)。モデルは出すものを持つだけ。
// 「もう見せたか」の記録は PlantMemoryStoring(端末の UserDefaults)。操作のたびに読み直して書く(サインアウトでの消去と食い違わない)。
//
// 初期化は軽く、副作用が無い(RootView の body が HomeViewModel を作り直すたびに呼ばれる。実際に使われるのは最初の1つ)。

import Foundation
import Observation

@MainActor
@Observable
final class PlantExperienceModel {
    /// 全画面で出すもの(同時に1つ)
    enum Presentation: Equatable, Identifiable {
        /// 段階アップ(段階0 = ペア成立の「はじめまして」を含む)
        case stageUp(StageCelebration)
        /// おかえり(2日以上あいたあとの自分のチェックイン)
        case welcomeBack

        var id: String {
            switch self {
            case .stageUp(let celebration): return "stageUp:\(celebration.id)"
            case .welcomeBack: return "welcomeBack"
            }
        }
    }

    /// 出している全画面の演出(nil = 出していない)
    private(set) var presentation: Presentation?
    /// 相手が名前を付けた・変えた知らせ(ホームの植物の下に出す。閉じるまで残る)
    private(set) var nameNotice: String?
    /// 今の吹き出し(nil = 出していない)
    private(set) var whisper: String?
    /// 吹き出しを出すたびに増える(View が数秒後に消すタイマーを、出し直しのたびに作り直すための識別)
    private(set) var whisperToken = 0

    @ObservationIgnored private let memoryStore: PlantMemoryStoring
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var latestSnapshot: PairSnapshot?

    init(
        memoryStore: PlantMemoryStoring = InMemoryPlantMemoryStore(),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.memoryStore = memoryStore
        self.now = now
        self.calendar = calendar
    }

    // MARK: snapshot の変化

    /// snapshot が変わった(HomeViewModel.load / apply)。同じ snapshot を何度渡しても、演出は1回だけ。
    /// nil(未取得)は、最新の snapshot を忘れるだけ
    func snapshotDidChange(_ snapshot: PairSnapshot?) {
        latestSnapshot = snapshot
        guard let snapshot else { return }
        var memory = memoryStore.load()
        let observation = memory.observe(snapshot)
        memoryStore.save(memory)

        if let celebration = observation.celebration {
            // 演出の中で名前を見せる・付ける。おかえり・ひとことより優先
            presentation = .stageUp(celebration)
            whisper = nil
        }
        if let name = observation.changedName {
            nameNotice = Strings.Plant.nameChangedNotice(name)
        }
        if snapshot.pairId == nil {
            // ペアが解消された・ソロに戻った: 相手の名前の知らせは意味がない
            nameNotice = nil
        }
    }

    // MARK: 自分のチェックイン(おかえり)

    /// 自分のチェックインが完了した(HomeViewModel.performCheckin の成功)。
    /// 前回から2日以上あいていたら「おかえり」を出す(ペアのときだけ。段階アップの演出が出ているときは出さない)。
    /// 判定は端末の中だけ。空いた日数は表示しない
    func myCheckinCompleted(snapshot: PairSnapshot) {
        var memory = memoryStore.load()
        let welcomesBack = memory.noteMyCheckin(day: PlantDay.number(of: now(), calendar: calendar))
        memoryStore.save(memory)
        guard welcomesBack, snapshot.pairId != nil, presentation == nil else { return }
        presentation = .welcomeBack
        whisper = nil
    }

    // MARK: 演出・知らせを閉じる

    func dismissPresentation() {
        presentation = nil
    }

    func dismissNameNotice() {
        nameNotice = nil
    }

    // MARK: 名前

    /// 自分が名前を付けた・変えた(自分には「名前が かわったよ」を出さない)。snapshot を反映する前に呼ぶ
    func recordOwnName(pairId: String, name: String) {
        var memory = memoryStore.load()
        memory.recordOwnName(pairId: pairId, name: name)
        memoryStore.save(memory)
        nameNotice = nil
    }

    /// 相手が先に付けていた名前に決まった(「名前は『みどり』になったよ」)
    func showNameNotice(_ text: String) {
        nameNotice = text
    }

    // MARK: 今日のひとこと

    /// ホームが前面に出た(表示・前面復帰)。その日はじめてなら吹き出しを出す。
    /// 全画面の演出が出ているときは出さない(今日のぶんは使わず、次の機会に出す)
    func homeDidAppear() {
        guard presentation == nil, let snapshot = latestSnapshot, snapshot.pairId != nil else { return }
        var memory = memoryStore.load()
        let claimed = memory.claimWhisper(day: PlantDay.number(of: now(), calendar: calendar))
        guard claimed else { return }
        memoryStore.save(memory)
        showWhisper(for: snapshot)
    }

    /// 植物をタップした: もう一度ひとことを出す(同じ日の同じ状況なら同じ言葉)
    func plantTapped() {
        guard presentation == nil, let snapshot = latestSnapshot, snapshot.pairId != nil else { return }
        showWhisper(for: snapshot)
    }

    func hideWhisper() {
        whisper = nil
    }

    private func showWhisper(for snapshot: PairSnapshot) {
        guard let line = PlantWhisper.line(for: snapshot, now: now(), calendar: calendar) else { return }
        whisper = line
        whisperToken += 1
    }
}
