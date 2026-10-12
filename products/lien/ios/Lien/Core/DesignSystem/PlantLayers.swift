// PlantLayers.swift — 植物キャラクター「タネの子」の状態 → 重ねる SVG レイヤーの並び(純粋関数 / issue #56)
//
// 正本: assets/plant/mapping.md(レイヤー名・重ね順・状態との対応・のぞきの位置・左右反転・ダークモード)。
// このファイルは mapping.md「重ね順」の実装で、同じ規則を assets/plant/tools/gen_layers.py の stack() も持つ。
// 両者は assets/plant/layer_stacks.json で突き合わせる(PlantLayersTests / CI の plant-assets)。
//
// 絵は全レイヤーが同じ 240×320 のキャンバスに最終位置で描いてあり、iOS は**重ねるだけ**で座標を持たない。例外は3つ:
//   1. 右の葉・右の芽・右の花の塗り = 左のレイヤーを x=120 で左右反転して使う(PlantLayer.mirrored)
//   2. のぞき(fx_peek) = 段階ごとの位置へ平行移動する(PlantLayers.peekOffsets。assets/plant/peek_offsets.json と一致)
//   3. bg_plate = ダークモードのときだけ最背面に敷く
//
// 罰なし原則(REQUIREMENTS §3.9): たたんだ葉は眠っているだけの元気な形で、しおれ・枯れ・後退を表す絵は無い。
// 知らない段階(サーバーが新しい段階を返したとき)は、知っている最大の段階として描く(GROWTH §8.2)。
//
// このファイルは Lien / LienWidget の2ターゲットでソース共有される(project.yml 参照。T17a のウィジェットと
// T22 のシェア画像でも使う)。Foundation と PairSnapshot(これもソース共有)以外に依存させないこと。

import Foundation

// MARK: - 状態

/// 顔(表情)6種(GROWTH §9.4)。顔によって、腕(arms_up)・ふちの手(hands_rim)・効果が決まる
enum PlantExpression: String, CaseIterable, Equatable, Sendable {
    /// ふつう(何もない日・朝)
    case normal
    /// にっこり(ふたりそろった日。キラキラ)
    case happy
    /// ひらいた自分(左)の葉を、うれしそうに見る
    case lookLeft
    /// ひらいた相手(右)の葉を、うれしそうに見る
    case lookRight
    /// すやすや(API の plantMood `sad`。zzz)
    case sleep
    /// 目をまるくして喜ぶ(段階アップ・はじめまして・おかえりの演出)
    case wow

    /// レイヤー名(imageset は PlantLayers.assetPrefix + 名前)
    var layerName: String {
        switch self {
        case .normal: return "face_normal"
        case .happy: return "face_happy"
        case .lookLeft: return "face_look_l"
        case .lookRight: return "face_look_r"
        case .sleep: return "face_sleep"
        case .wow: return "face_wow"
        }
    }

    /// 腕を上げる顔。arms_up を体の背後に重ね、ふちの手(hands_rim)は出さない
    var raisesArms: Bool {
        self == .happy || self == .wow
    }

    /// 顔と対の効果レイヤー(mapping.md §4)。ほかの顔には効果が付かない
    var effectLayerName: String? {
        switch self {
        case .happy: return "fx_sparkle"
        case .sleep: return "fx_zzz"
        case .wow: return "fx_celebrate"
        case .normal, .lookLeft, .lookRight: return nil
        }
    }
}

/// 植物の描画に必要な入力(どのレイヤーを重ねるかは、これだけで決まる)
struct PlantCharacterState: Equatable, Sendable {
    /// 成長の段階。描くときは 0…9 に丸める(負 → 0 / 知らない段階 → 知っている最大の 9)
    var stage: Int
    /// 自分の葉(左)がひらいている。段階0では、自分の芽が光る
    var meOpen: Bool
    /// 相手の葉(右)がひらいている。段階0では、相手の芽が光る
    var partnerOpen: Bool
    var expression: PlantExpression
    /// ソロ(ペア未成立): 鉢の土の中で眠っている。段階・葉・顔は無視する
    var isSolo: Bool
    /// ソロで自分が今日チェックインした(土がほのかに光る)
    var soilGlow: Bool
    /// のぞき(区間の途中の光る小さな芽)を出す。位置がある段階(3〜8)だけに出る。いつ出すかは PB(GROWTH §3.4)が決める
    var peek: Bool

    init(
        stage: Int,
        meOpen: Bool = false,
        partnerOpen: Bool = false,
        expression: PlantExpression = .normal,
        isSolo: Bool = false,
        soilGlow: Bool = false,
        peek: Bool = false
    ) {
        self.stage = stage
        self.meOpen = meOpen
        self.partnerOpen = partnerOpen
        self.expression = expression
        self.isSolo = isSolo
        self.soilGlow = soilGlow
        self.peek = peek
    }

    /// ソロ(snapshot 未取得の空状態も同じ姿)
    static let solo = PlantCharacterState(stage: 0, isSolo: true)

    /// 毎朝の既定(ふたりともまだ): 葉は2枚ともたたみ、顔はふつう
    static func morning(stage: Int) -> PlantCharacterState {
        PlantCharacterState(stage: stage)
    }
}

extension PlantCharacterState {
    /// snapshot から描画の状態を導く(GROWTH §4.1 の表)。
    ///
    /// 葉は**今日のチェックインの有無(todayMeDone / todayPartnerDone)から決める**。サーバーの derivePlantMood
    /// (両方完了 = happy / 片方だけ = fidget / どちらも未完 = normal か sad)と同じ規則なので、
    /// サーバーの snapshot なら plantMood から導くのと結果が同じになる。フラグを優先するのは、楽観更新で
    /// plantMood が古いまま todayMeDone だけが立つ瞬間(LocalEchoCheckinService)にも、自分の葉がすぐにひらくため。
    ///
    /// | 今日の状態 | 左(自分) | 右(相手) | 顔 |
    /// |---|---|---|---|
    /// | ふたりともまだ | たたむ | たたむ | ふつう |
    /// | 自分だけ完了 | ひらく | たたむ | 自分の葉を見る |
    /// | 相手だけ完了 | たたむ | ひらく | 相手の葉を見る |
    /// | ふたりそろった | ひらく | ひらく | にっこり |
    /// | すやすや(sad かつどちらも未完) | たたむ | たたむ | 眠る |
    ///
    /// ペア未成立(pairId が null)はソロ。段階アップの演出(wow)は snapshot の値ではなくアプリ側の演出なので、ここでは導かない
    init(snapshot: PairSnapshot) {
        if snapshot.pairId == nil {
            self.init(stage: 0, isSolo: true, soilGlow: snapshot.todayMeDone)
            return
        }
        let me = snapshot.todayMeDone
        let partner = snapshot.todayPartnerDone
        let expression: PlantExpression
        switch (me, partner) {
        case (true, true):
            expression = .happy
        case (true, false):
            expression = .lookLeft
        case (false, true):
            expression = .lookRight
        case (false, false):
            expression = snapshot.plantMood == .sad ? .sleep : .normal
        }
        self.init(stage: snapshot.plantStage, meOpen: me, partnerOpen: partner, expression: expression)
    }
}

// MARK: - レイヤー

/// 重ねる1枚。`name` は assets/plant/mapping.md のレイヤー名(例 "pot_back")で、imageset 名は `assetName`
struct PlantLayer: Equatable, Sendable, Identifiable {
    /// 重ね順の中での位置(同じ位置で絵だけが替わる — 葉をひらく / たたむはクロスフェードではなく差し替え)
    enum Slot: String, Sendable {
        case backPlate, potBack, soilGlow, soloSeed
        case leftLeaf, rightLeaf, leftPetal, rightPetal, head
        case arms, body, face, potFront, hands
        case peek, effect
    }

    /// 花の塗りの着色。色そのものは見た目の側(PlantCharacterView)が持つ: me = 自分の花の色 / partner = 相手の花の色
    enum Tint: String, Equatable, Sendable {
        case me
        case partner
    }

    let slot: Slot
    let name: String
    /// x=120(キャンバスの中央)で左右反転して重ねる(右の葉・右の芽・右の花の塗り)
    var mirrored: Bool = false
    var tint: Tint?
    /// 平行移動(キャンバス座標 240×320 での量。のぞきだけ)
    var dx: Double = 0
    var dy: Double = 0

    var id: Slot { slot }

    /// アセットカタログの imageset 名
    var assetName: String { PlantLayers.assetPrefix + name }
}

enum PlantLayers {
    /// imageset 名 = このプレフィックス + レイヤー名(assets/plant/tools/build_asset_catalog.py の ASSET_PREFIX と同じ)
    static let assetPrefix = "plant_"

    /// 全レイヤー共通のキャンバス(SVG の viewBox)。表示は 3:4 を保つ
    static let canvasWidth: Double = 240
    static let canvasHeight: Double = 320
    static let canvasAspect: Double = canvasWidth / canvasHeight

    /// 描ける段階(GROWTH §3.3: たね 0 〜 みのり 9)。これより大きい段階は最大として描く
    static let stageRange = 0...9
    /// 花の塗り(petal_sN)がある段階
    static let petalStages = 6...9

    /// v1.0 の既定の花色 #FFB3C7(petal_sN の SVG の色と同じ。PlantLayersTests が突き合わせる)
    static let defaultPetalRGB: UInt32 = 0xFFB3C7

    /// のぞき(fx_peek)の平行移動量(キャンバス座標)。assets/plant/peek_offsets.json と一致する
    struct PeekOffset: Equatable, Sendable {
        let dx: Double
        let dy: Double
    }

    static let peekOffsets: [Int: PeekOffset] = [
        3: PeekOffset(dx: 0, dy: -84),   // わかば: 2本の茎の間
        4: PeekOffset(dx: 0, dy: -126),  // よりそい: 触れ合う先端の上
        5: PeekOffset(dx: 0, dy: -108),  // つぼみ: 2つのつぼみの間
        6: PeekOffset(dx: 0, dy: -108),  // いろづき
        7: PeekOffset(dx: 0, dy: -108),  // ほころび
        8: PeekOffset(dx: 0, dy: -84),   // ふたりざき: みのりでハートのタネが出る場所
    ]

    /// 全34レイヤーの名前(assets/plant/svg/ と PlantAssets.xcassets の imageset に1対1)
    static let allLayerNames: [String] = {
        var names = [
            "bg_plate", "pot_back", "pot_front",
            "body", "hands_rim", "arms_up", "solo_seed",
            "nub_closed", "nub_lit", "leaf_open", "leaf_folded",
            "fx_sparkle", "fx_zzz", "fx_celebrate", "fx_soil_glow", "fx_peek",
        ]
        names += PlantExpression.allCases.map(\.layerName)
        names += (2...9).map { "head_s\($0)" }
        names += petalStages.map { "petal_s\($0)" }
        return names.sorted()
    }()

    /// 知らない段階を 0…9 に丸める(負 → 0、9 より大きい → 9)
    static func clampedStage(_ stage: Int) -> Int {
        min(max(stage, stageRange.lowerBound), stageRange.upperBound)
    }

    /// 状態から、重ねるレイヤーを**下から順に**返す(mapping.md §4「重ね順」)。
    /// - Parameter dark: ダークモード。true のとき最背面に bg_plate(クリーム色のプレート)を敷く
    static func stack(for state: PlantCharacterState, dark: Bool) -> [PlantLayer] {
        var layers: [PlantLayer] = []
        if dark {
            layers.append(PlantLayer(slot: .backPlate, name: "bg_plate"))
        }
        layers.append(PlantLayer(slot: .potBack, name: "pot_back"))

        if state.isSolo {
            // ソロ: 土の中で眠る(段階・葉・顔は無視)。自分がチェックインした日は土がほのかに光る
            if state.soilGlow {
                layers.append(PlantLayer(slot: .soilGlow, name: "fx_soil_glow"))
            }
            layers.append(PlantLayer(slot: .soloSeed, name: "solo_seed"))
            layers.append(PlantLayer(slot: .potFront, name: "pot_front"))
            layers.append(PlantLayer(slot: .effect, name: "fx_zzz"))
            return layers
        }

        let stage = clampedStage(state.stage)

        // ふたりの葉。左 = 自分 / 右 = 相手(左のレイヤーを左右反転)。段階0はまだ葉が無く、頭の2つの芽が同じ役目をする
        let leftName: String
        let rightName: String
        if stage == 0 {
            leftName = state.meOpen ? "nub_lit" : "nub_closed"
            rightName = state.partnerOpen ? "nub_lit" : "nub_closed"
        } else {
            leftName = state.meOpen ? "leaf_open" : "leaf_folded"
            rightName = state.partnerOpen ? "leaf_open" : "leaf_folded"
        }
        layers.append(PlantLayer(slot: .leftLeaf, name: leftName))
        layers.append(PlantLayer(slot: .rightLeaf, name: rightName, mirrored: true))

        // 花の塗り(段階6〜9): 左の花 = 自分の色 / 左右反転 = 相手の色。頭の植物(線と陰影)の下
        if petalStages.contains(stage) {
            layers.append(PlantLayer(slot: .leftPetal, name: "petal_s\(stage)", tint: .me))
            layers.append(PlantLayer(slot: .rightPetal, name: "petal_s\(stage)", mirrored: true, tint: .partner))
        }

        // 頭の植物は葉より上(たたんだ葉が段階2〜4の植物を隠さない)、体の背後(頭から生えて見える)
        if stage >= 2 {
            layers.append(PlantLayer(slot: .head, name: "head_s\(stage)"))
        }

        let armsUp = state.expression.raisesArms
        if armsUp {
            layers.append(PlantLayer(slot: .arms, name: "arms_up"))
        }
        layers.append(PlantLayer(slot: .body, name: "body"))
        layers.append(PlantLayer(slot: .face, name: state.expression.layerName))
        layers.append(PlantLayer(slot: .potFront, name: "pot_front"))
        if !armsUp {
            layers.append(PlantLayer(slot: .hands, name: "hands_rim"))
        }

        // のぞき: 位置がある段階(3〜8)だけ。効果(fx_*)より下
        if state.peek, let offset = peekOffsets[stage] {
            layers.append(PlantLayer(slot: .peek, name: "fx_peek", dx: offset.dx, dy: offset.dy))
        }
        if let effect = state.expression.effectLayerName {
            layers.append(PlantLayer(slot: .effect, name: effect))
        }
        return layers
    }
}
