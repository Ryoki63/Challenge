// WidgetContent.swift — ウィジェットが何を見せるか(snapshot → 表示の内容。純粋な導出 / issue #17 T17a)
//
// 正本: docs/REQUIREMENTS.md §3.10(ウィジェット)・docs/GROWTH.md §5.4(ウィジェットの植物まわり)・
//       assets/plant/mapping.md(葉・芽のレイヤー)。
// App Group の snapshot(pair_snapshot.json)と、そこからの導出だけで決まる。SwiftUI にも WidgetKit にも依存しない
// (macOS の下見 scripts/macos-check とテストが、そのまま走らせられるように)。見た目は Views/ の各ビューが、この内容を描く。
//
// 3つの状態:
//   - noData: snapshot が無い(初回起動前・サインアウト後)。眠るタネの子+「アプリを開いてはじめよう」
//   - solo:   ペア未成立(pairId が null)。眠るタネの子+「ペアになると、タネの子が目をさますよ」。
//             自分が今日チェックインしていれば土がほのかに光る(PlantCharacterState)
//   - paired: ふたりの葉(左 = 自分・右 = 相手)が今日の2人を表す。ストリーク・2人の○×・進み具合のバー・
//             相手が先に完了していれば「(相手)が待ってるよ」
//
// 表示原則(REQUIREMENTS §3.10): 自分が未完 = 自分側をグレー / 相手が先に完了 =「(名前)が待ってるよ」。
// **数字はストリークだけ**(GROWTH §5.4。数え方の違う数字を並べない)。進み具合は細いバーだけで、数字も文も出さない。
// 罰なし(§3.5): ストリークが 0 のときは「0日」を出さない。葉をたたむのは眠っているだけで、色も大きさも変えない。
//
// このファイルは Lien / LienWidget の2ターゲットでソース共有される(project.yml 参照)。
// Foundation と PairSnapshot・PlantLayers・PlantProgress・GrowthGauge・Strings(これらもソース共有)以外に依存させないこと。

import Foundation

/// ウィジェットの描画方式。WidgetKit の WidgetFamily から、LienWidget ターゲットが写す
/// (ロック画面の accessory 系は macOS の SDK に無いので、ソース共有する側は WidgetKit のファミリーを持たない)
enum WidgetLayout: String, CaseIterable, Equatable, Sendable {
    /// ホーム画面・小(systemSmall)
    case small
    /// ホーム画面・中(systemMedium): S の内容+植物を大きく。相手の写真は v1.0.1(T17b)
    case medium
    /// ロック画面・円形(accessoryCircular): 相手の今日の状態(葉の開閉)
    case lockCircular
    /// ロック画面・インライン(accessoryInline): ストリーク数
    case lockInline
}

struct WidgetContent: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// snapshot が無い
        case noData
        /// ペア未成立
        case solo
        /// ペア成立
        case paired
    }

    /// 1人分の今日の状態(ホームの TodayChip と同じ。未完 = グレー)。
    /// 約束の絵文字は持たない(2026-10-26 オーナー判断で UI から廃止)。誰の状態かは呼び名で示す
    struct Person: Equatable, Sendable {
        /// 呼び名。自分は「じぶん」、相手はニックネーム(まだ分からなければ「あいて」)
        let name: String
        let done: Bool
    }

    /// ロック画面・円形に出す「相手の葉」。段階0 は葉の前の姿(芽)
    struct PartnerLeaf: Equatable, Sendable {
        /// レイヤー名(leaf_open / leaf_folded / nub_lit / nub_closed — mapping.md §3)
        let layerName: String
        /// ひらいている(= 相手が今日チェックイン済み。芽は光っている)
        let isOpen: Bool
        /// 段階0 の芽
        let isNub: Bool
    }

    let mode: Mode
    /// 植物の描画の状態(ふたりの葉・顔・段階。ソロ・データ無しは眠るタネの子)
    let plant: PlantCharacterState
    /// ストリークの日数。ペアで 1 以上のときだけ(0 は出さない)
    let streakDays: Int?
    /// 自分 / 相手の今日の状態。ペアのときだけ
    let me: Person?
    let partner: Person?
    /// 進み具合の細いバーの長さ(0〜1)。nil = バーを出さない(ソロ・データ無し・snapshot に新しいキーが無い・値が食い違う)。
    /// 最後の段階(次の段階が無い)は 1
    let progress: Double?
    /// 相手が先に完了しているときの一言「(名前)が待ってるよ」
    let waitingMessage: String?
    /// ソロ・データ無しのときの一言(ペアのときは nil)
    let note: String?
    /// ロック画面・円形の「相手の葉」。ペアのときだけ
    let partnerLeaf: PartnerLeaf?
    /// ロック画面・インラインに出す文(「23日」)。ストリークがあるときだけ
    let inlineStreakText: String?

    /// VoiceOver の読み上げ文(ホーム S / M。GROWTH §5.4)
    let spokenSummary: String
    /// 同(ロック画面・円形): 「ゆうき: 完了」
    let spokenPartner: String
    /// 同(ロック画面・インライン): 「ふたりの記録 23日」。ストリークが無いときはアプリ名
    let spokenStreak: String

    // MARK: - 導出

    /// snapshot から表示の内容を作る。nil(まだ無い)は noData。snapshot が前の日に作られたものかの扱いは、タイムライン側
    /// (WidgetTimelinePlan が前の日の snapshot を resettingForNewDay してから渡す)
    init(snapshot: PairSnapshot?) {
        guard let snapshot else {
            self = .noData
            return
        }
        guard snapshot.pairId != nil else {
            self = Self.solo(snapshot)
            return
        }
        self = Self.paired(snapshot)
    }

    private init(
        mode: Mode,
        plant: PlantCharacterState,
        streakDays: Int? = nil,
        me: Person? = nil,
        partner: Person? = nil,
        progress: Double? = nil,
        waitingMessage: String? = nil,
        note: String? = nil,
        partnerLeaf: PartnerLeaf? = nil,
        spokenSummary: String,
        spokenPartner: String,
        spokenStreak: String
    ) {
        self.mode = mode
        self.plant = plant
        self.streakDays = streakDays
        self.me = me
        self.partner = partner
        self.progress = progress
        self.waitingMessage = waitingMessage
        self.note = note
        self.partnerLeaf = partnerLeaf
        self.inlineStreakText = streakDays.map(Strings.Widget.streakDays)
        self.spokenSummary = spokenSummary
        self.spokenPartner = spokenPartner
        self.spokenStreak = spokenStreak
    }

    /// snapshot が無い: 眠るタネの子+「アプリを開いてはじめよう」
    static let noData = WidgetContent(
        mode: .noData,
        plant: .solo,
        note: Strings.Widget.emptyMessage,
        spokenSummary: [Strings.Widget.emptyTitle, Strings.Widget.emptyMessage].joined(separator: "。"),
        spokenPartner: Strings.Widget.emptyMessage,
        spokenStreak: Strings.Widget.emptyTitle
    )

    /// ペア未成立: 眠るタネの子+「ペアになると、タネの子が目をさますよ」
    private static func solo(_ snapshot: PairSnapshot) -> WidgetContent {
        WidgetContent(
            mode: .solo,
            plant: PlantCharacterState(snapshot: snapshot),
            note: Strings.Widget.soloCaption,
            spokenSummary: [Strings.Plant.voiceSolo, Strings.Widget.soloCaption].joined(separator: "。"),
            spokenPartner: Strings.Plant.voiceSolo,
            spokenStreak: Strings.Widget.displayName
        )
    }

    private static func paired(_ snapshot: PairSnapshot) -> WidgetContent {
        let plant = PlantCharacterState(snapshot: snapshot)
        let partnerName = snapshot.partnerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPartnerName = !(partnerName ?? "").isEmpty
        let streak = snapshot.streakCurrent > 0 ? snapshot.streakCurrent : nil

        // 相手が先に完了 →「(名前)が待ってるよ」(ホームの HomeViewModel.partnerWaitingText と同じ条件)
        var waiting: String?
        if snapshot.todayPartnerDone, !snapshot.todayMeDone, hasPartnerName, let partnerName {
            waiting = Strings.Widget.partnerWaiting(partnerName)
        }

        // 読み上げ(GROWTH §5.4): 植物の読み上げ文(名前・段階・2人の状態・あと何回)に、ストリークと「待ってるよ」を足す
        var sentences = [PlantVoiceOver.label(for: snapshot)]
        if let streak {
            sentences.append(Strings.Widget.streakSpoken(streak))
        }
        if let waiting {
            sentences.append(waiting)
        }

        let leaf = partnerLeaf(for: plant)
        let spokenName = hasPartnerName ? (partnerName ?? "") : Strings.Widget.partnerFallbackLabel
        return WidgetContent(
            mode: .paired,
            plant: plant,
            streakDays: streak,
            me: Person(name: Strings.Widget.meFallbackLabel, done: snapshot.todayMeDone),
            partner: Person(name: spokenName, done: snapshot.todayPartnerDone),
            progress: PlantProgress(snapshot: snapshot).map(barFraction),
            waitingMessage: waiting,
            partnerLeaf: leaf,
            spokenSummary: sentences.joined(separator: "。"),
            spokenPartner: Strings.Widget.partnerStatus(spokenName, done: snapshot.todayPartnerDone),
            spokenStreak: streak.map(Strings.Widget.streakSpoken) ?? Strings.Widget.displayName
        )
    }

    // MARK: - 部品

    /// 進み具合のバーの長さ(0〜1): この段階に入ってから、ふたりでそろった回数 ÷ 区間の長さ。次の段階が無いとき(最後の段階)は 1。
    /// 閾値表は持たず、snapshot の新キー3つ(plantGrownDays / plantStageFloor / plantNextStageAt)だけから作る(PlantProgress)
    static func barFraction(_ progress: PlantProgress) -> Double {
        guard let length = progress.intervalLength, length > 0 else { return 1 }
        return min(max(Double(progress.countInStage) / Double(length), 0), 1)
    }

    /// ロック画面・円形の「相手の葉」: 重ね順(PlantLayers.stack)の右の葉をそのまま使う
    /// (段階0 は芽 / 段階1以上は葉。ソロには葉が無い)
    private static func partnerLeaf(for plant: PlantCharacterState) -> PartnerLeaf? {
        guard let layer = PlantLayers.stack(for: plant, dark: false).first(where: { $0.slot == .rightLeaf }) else {
            return nil
        }
        return PartnerLeaf(
            layerName: layer.name,
            isOpen: plant.partnerOpen,
            isNub: layer.name.hasPrefix("nub_")
        )
    }
}
