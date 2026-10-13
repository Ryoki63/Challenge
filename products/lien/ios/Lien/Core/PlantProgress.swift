// PlantProgress.swift — 成長の進み具合(1つの区間の中での位置)と、ゲージ・のぞきの境目(純粋な計算 / issue #57)
//
// 「区間」= 今の段階に入る回数(plantStageFloor)から、次の段階に必要な回数(plantNextStageAt)まで。
// snapshot の新キー3つ(plantGrownDays / plantStageFloor / plantNextStageAt — DESIGN §3.4)だけから、
// アプリは閾値表を持たずに次を作れる(あとからサーバー側で閾値を下げても、古いアプリが追従する — GROWTH §3.6):
//   - あと何回で次の段階か(remaining)
//   - この段階に入ってから何回そろったか(countInStage)
//   - 区間の半分以上まで進んだか(isLaterHalf)
//
// 使い分け:
//   - ゲージの文(GrowthGauge)      : 区間が短い間は「あと○回で」/ 長い区間は前半「○○になってから 3回そろったよ」・後半「あと○回で」
//   - のぞき(PlantCharacterState)   : 長い区間(7回以上)の後半だけ、植物の先に光る小さな芽を出す(GROWTH §3.4)
//
// のぞきを出す回数(GROWTH §3.4): 11・18・26・38・56・83回 = 区間の半分「以上」(2 × 進んだ回数 ≧ 区間の長さ)。
// 66→100 の区間は半分がちょうど 83 で、そこから出る(「超えたら」ではなく「以上」)。
//
// このファイルは Lien / LienWidget の2ターゲットでソース共有される(project.yml 参照。T17a のウィジェットの
// 「細い進み具合のバー」でも使う)。Foundation と PairSnapshot / PlantLayers(これらもソース共有)にだけ依存させること。

import Foundation

struct PlantProgress: Equatable, Sendable {
    /// 「長い区間」とみなす最小の長さ(GROWTH §3.4: 区間の長さが 7 回以上 = わかば以降)。
    /// のぞきを出すのも、ゲージの文を前半 / 後半で切り替えるのも、この長さ以上の区間だけ
    static let longIntervalMinLength = 7

    /// サーバーが返した段階そのまま(アプリが知らない大きい段階も含む)
    let rawStage: Int
    /// 成長回数(ふたり達成日の累計)
    let grownDays: Int
    /// 今の段階に入る回数
    let stageFloor: Int
    /// 次の段階に必要な回数。最後の段階(みのり)は nil
    let nextStageAt: Int?

    /// 値の組を検査して作る。次のどれかなら nil(= ゲージ・のぞきを出さない。「あと -1 回」のような表示を出さない):
    ///   - 負の値がある
    ///   - 段階の下限が成長回数より大きい(今の段階に入っていないことになる)
    ///   - 次の段階の回数が成長回数以下(もう次の段階に着いているはずで、段階と食い違っている)
    init?(rawStage: Int, grownDays: Int, stageFloor: Int, nextStageAt: Int?) {
        guard rawStage >= 0, grownDays >= 0, stageFloor >= 0, stageFloor <= grownDays else { return nil }
        if let nextStageAt, nextStageAt <= grownDays { return nil }
        self.rawStage = rawStage
        self.grownDays = grownDays
        self.stageFloor = stageFloor
        self.nextStageAt = nextStageAt
    }

    /// snapshot から作る。次のとき nil:
    ///   - ソロ(ペア未成立。植物は土の中で眠っていて、成長の進み具合が無い — GROWTH §5.1)
    ///   - 新キーが無い(古いサーバー・古いキャッシュ。ゲージを出さない — GROWTH §5.1・§8.6)
    ///   - 値が食い違っている(上の検査)
    init?(snapshot: PairSnapshot) {
        guard
            snapshot.pairId != nil,
            let grownDays = snapshot.plantGrownDays,
            let stageFloor = snapshot.plantStageFloor
        else { return nil }
        self.init(
            rawStage: snapshot.plantStage,
            grownDays: grownDays,
            stageFloor: stageFloor,
            nextStageAt: snapshot.plantNextStageAt
        )
    }

    // MARK: - 段階

    /// 描ける段階(0〜9)に丸めた段階
    var stage: Int {
        PlantLayers.clampedStage(rawStage)
    }

    /// アプリが知らない大きい段階(サーバーが v1.0.1 の花壇の段階 10 以降を返した)。みのりとして描く
    var isUnknownStage: Bool {
        rawStage > PlantLayers.stageRange.upperBound
    }

    // MARK: - 区間の中での位置

    /// 区間の長さ(次の段階に必要な回数 − 今の段階に入る回数)。次の段階が無いときは nil
    var intervalLength: Int? {
        nextStageAt.map { $0 - stageFloor }
    }

    /// この段階に入ってから、ふたりでそろった回数
    var countInStage: Int {
        grownDays - stageFloor
    }

    /// 次の段階まであと何回(1 以上)。次の段階が無いときは nil
    var remaining: Int? {
        nextStageAt.map { $0 - grownDays }
    }

    /// 長い区間(7回以上)か。次の段階が無いときは false
    var isLongInterval: Bool {
        (intervalLength ?? 0) >= Self.longIntervalMinLength
    }

    /// 区間の半分以上まで進んだか(前半 = false / 後半 = true)。次の段階が無いときは false。
    /// 割り算を避け、整数のまま `2 × 進んだ回数 ≧ 区間の長さ` で比べる
    var isLaterHalf: Bool {
        guard let length = intervalLength else { return false }
        return countInStage * 2 >= length
    }

    // MARK: - のぞき

    /// のぞき(植物の先の光る小さな芽)を出すか: 長い区間の後半で、その段階に出す位置がある(段階 3〜8)とき。
    /// 知らない段階(みのりとして描く)では出さない
    var showsPeek: Bool {
        guard !isUnknownStage, isLongInterval, isLaterHalf else { return false }
        return PlantLayers.peekOffsets[stage] != nil
    }
}
