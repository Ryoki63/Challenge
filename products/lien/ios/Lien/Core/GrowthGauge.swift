// GrowthGauge.swift — ホームの植物の下の「ゲージの文」と、植物の VoiceOver の読み上げ文(純粋関数 / issue #57)
//
// 正本: docs/GROWTH.md §5.1(ゲージの文)・§5.4(VoiceOver)。単位は「回」(「日」は暦の日数と混同しやすく、
// 休んだ日に数字が減らないことも、自然に伝わる)。新しい単位は作らず、文で伝える。
//
//   | 場面                                          | 文                                    |
//   |-----------------------------------------------|---------------------------------------|
//   | 区間が短い(7回未満)                         | 「ふたりそろって あと2回で めばえ」     |
//   | 長い区間(7回以上)の前半(半分未満)           | 「わかばになってから 3回そろったよ」    |
//   | 長い区間の後半(半分以上)                     | 「ふたりそろって あと4回で よりそい」   |
//   | 次の段階が無い(v1.0 のみのり以降)            | 「ふたりで 128回 そろったよ」          |
//   | アプリが知らない段階をサーバーが返したとき     | 「あと25回で つぎの おたのしみ」        |
//
// ソロのときや、snapshot に新しいキーが無いとき(古いサーバー・古いキャッシュ)は、ゲージを出さない(nil)。
// 区間の前半でまだ1回もそろっていない(段階に入った直後)ときは、「0回そろったよ」とは言わず、次の段階までの文にする。
// 判定は PlantProgress(区間の中での位置。のぞきを出す回数と同じ境目)。

import Foundation

enum GrowthGauge {
    /// ゲージの文。nil = 出さない(ソロ・新しいキーが無い・値が食い違っている)
    static func text(for snapshot: PairSnapshot) -> String? {
        PlantProgress(snapshot: snapshot).map(text(for:))
    }

    static func text(for progress: PlantProgress) -> String {
        // アプリが知らない段階(サーバーが v1.0.1 の花壇の段階などを返した): 次の段階の名前を知らない
        if progress.isUnknownStage {
            if let remaining = progress.remaining {
                return Strings.Plant.gaugeUnknownNext(remaining)
            }
            return Strings.Plant.gaugeLast(progress.grownDays)
        }
        // 次の段階が無い(みのり)
        guard let remaining = progress.remaining else {
            return Strings.Plant.gaugeLast(progress.grownDays)
        }
        let nextStageName = Strings.Plant.stageName(progress.stage + 1)
        let remainingText = Strings.Plant.gaugeRemaining(remaining, nextStageName: nextStageName)

        // 区間が短い間は、いつも「あと○回で」
        guard progress.isLongInterval else { return remainingText }
        // 長い区間の後半も「あと○回で」
        if progress.isLaterHalf { return remainingText }
        // 長い区間の前半: 「○○になってから N回そろったよ」。段階に入った直後(N = 0)は、次の段階までの文にする
        if progress.countInStage == 0 { return remainingText }
        return Strings.Plant.gaugeSinceStage(Strings.Plant.stageName(progress.stage), count: progress.countInStage)
    }
}

// MARK: - VoiceOver

enum PlantVoiceOver {
    /// ホームの植物の読み上げ文(GROWTH §5.4)。
    /// ペア: 「みどり、わかば。あなた: 完了、ゆうき: まだ。ふたりそろって あと3回で よりそい」
    ///   (名前が無ければ段階名から。ゲージが出ないとき = 新しいキーが無いときは、最後の文を付けない)
    /// ソロ: 「土の中で眠るタネの子」
    static func label(for snapshot: PairSnapshot) -> String {
        guard snapshot.pairId != nil else { return Strings.Plant.voiceSolo }
        let stage = PlantLayers.clampedStage(snapshot.plantStage)
        var sentences = [
            Strings.Plant.voiceHeader(name: snapshot.plantName, stageName: Strings.Plant.stageName(stage)),
            Strings.Plant.voiceStatus(
                meDone: snapshot.todayMeDone,
                partnerName: snapshot.partnerName ?? Strings.Home.partnerFallbackLabel,
                partnerDone: snapshot.todayPartnerDone
            ),
        ]
        if let gauge = GrowthGauge.text(for: snapshot) {
            sentences.append(gauge)
        }
        return sentences.joined(separator: "。")
    }
}
