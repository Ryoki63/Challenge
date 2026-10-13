// PlantCelebrationView.swift — 植物の全画面の演出(段階アップ・おかえり / issue #57 / docs/GROWTH.md §4.4・§5.2・§5.3)
//
// HomeView が、PlantExperienceModel.presentation があるあいだ、ホームの上に全画面で重ねる(オーバーレイ。ナビゲーションバーは隠す)。
// シート / fullScreenCover にしないのは、設定・招待・相手の写真の全画面・通報の確認など、ほかの表示と重なっても、
// 先に出ていた表示を閉じるまで裏で待ち、閉じたあとに見える(SwiftUI の「同時に出せる表示は1つ」に左右されない)ため。
//
// 段階アップ(各段階で1回だけ — 記録は PlantMemory):
//   - 変わる前と後の植物(左 → 右。後は驚いた顔・ふたりの葉がひらいて、お祝いのきらきら)
//   - 一言(段階名と「ふたりで 7回 そろったよ」。段階0 = ペア成立は「はじめまして!」「タネの子が、目をさましたよ」)
//   - 最初の「ふたば」(段階1)では、名前を付ける(まだ名前が無いとき。先に付けた人の名前に決まる — PlantNameFormView)
//   - ボタン「(相手)にハートを送る」(P1。T15 のリアクション ❤️ を使い回す。相手が今日チェックイン済みで、今日まだ
//     リアクションを送っていないときだけ — PlantCelebrationHeartView。付け替えは相手に届かないので、送った日は出さない)
//   - 閉じるボタン
//   - 相手名義の通知には混ぜない。ウィジェットは動かさない(GROWTH §5.2)
// おかえり(2日以上あいたあと、自分がチェックインした瞬間だけ): 目をさました植物と「おかえり。また いっしょに」。空いた日数は出さない。
//
// アニメは、あとの植物がぽんと現れるだけ(視差効果を減らす設定ではそのまま出す)。VoiceOver には全体を1つのモーダルとして出す。
// 300 行の目安(DESIGN §9-4)のため、植物の行は PlantCelebrationPlantsView.swift、ハートのボタンは PlantCelebrationHeartView.swift。

import SwiftUI

struct PlantCelebrationView: View {
    let presentation: PlantExperienceModel.Presentation
    /// いまの snapshot(相手の名前・植物の名前・今日の状態)
    let snapshot: PairSnapshot?
    /// 名前を付けるフォームの状態(最初の「ふたば」で、まだ名前が無いとき)。nil なら名前付けは出さない
    let naming: PlantNamingModel?
    /// 「(相手)にハートを送る」を出すか(相手が今日チェックイン済みで、リアクションの口があり、今日まだリアクションを送っていない)
    let canSendHeart: Bool
    /// ハートを送る。成功したら true
    let onSendHeart: () async -> Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            LienColors.celebrationBackground
                .ignoresSafeArea()
            ScrollView {
                PlantCelebrationContent(
                    presentation: presentation,
                    snapshot: snapshot,
                    naming: naming,
                    canSendHeart: canSendHeart,
                    onSendHeart: onSendHeart,
                    onClose: onClose
                )
            }
        }
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - 中身(スクロールの内側。実描画のテストからも描ける)

struct PlantCelebrationContent: View {
    let presentation: PlantExperienceModel.Presentation
    let snapshot: PairSnapshot?
    let naming: PlantNamingModel?
    let canSendHeart: Bool
    let onSendHeart: () async -> Bool
    let onClose: () -> Void

    /// あとの植物を出したか(onAppear で、少し待ってぽんと現す)。実描画のテストは、最初から出した状態で描く
    @State private var revealed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        presentation: PlantExperienceModel.Presentation,
        snapshot: PairSnapshot?,
        naming: PlantNamingModel?,
        canSendHeart: Bool,
        onSendHeart: @escaping () async -> Bool,
        onClose: @escaping () -> Void,
        initiallyRevealed: Bool = false
    ) {
        self.presentation = presentation
        self.snapshot = snapshot
        self.naming = naming
        self.canSendHeart = canSendHeart
        self.onSendHeart = onSendHeart
        self.onClose = onClose
        _revealed = State(initialValue: initiallyRevealed)
    }

    var body: some View {
        VStack(spacing: LienSpacing.l) {
            PlantCelebrationPlantsView(presentation: presentation, snapshot: snapshot, revealed: revealed)
                .padding(.top, LienSpacing.xl)
            messages
            namingSection
            heartSection
            closeButton
                .padding(.top, LienSpacing.s)
        }
        .padding(LienSpacing.l)
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !revealed else { return }
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.62).delay(0.35)) {
                    revealed = true
                }
            }
            // 最初の「ふたば」の演出の中で名前を付ける: フォームを空から始める
            if case .stageUp(let celebration) = presentation, celebration.offersNaming {
                naming?.begin(mode: .first, currentName: nil)
            }
        }
    }

    // MARK: 一言

    @ViewBuilder
    private var messages: some View {
        VStack(spacing: LienSpacing.xs) {
            Text(headline)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            if let body = bodyText {
                Text(body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let name = plantName {
                Text(name)
                    .font(.headline)
                    .padding(.top, LienSpacing.xs)
            }
        }
    }

    private var headline: String {
        switch presentation {
        case .stageUp(let celebration):
            return celebration.isFirstMeeting
                ? Strings.Plant.meetingHeadline
                : Strings.Plant.stageUpHeadline(Strings.Plant.stageName(celebration.stage))
        case .welcomeBack:
            return Strings.Plant.welcomeBackHeadline
        }
    }

    private var bodyText: String? {
        switch presentation {
        case .stageUp(let celebration):
            if celebration.isFirstMeeting { return Strings.Plant.meetingBody }
            return celebration.grownDays.map(Strings.Plant.stageUpBody)
        case .welcomeBack:
            return Strings.Plant.welcomeBackBody
        }
    }

    /// 植物の名前(ペアの鉢の名前。ペアで先に付いていれば、演出にも出す)
    private var plantName: String? {
        guard let snapshot, snapshot.pairId != nil, let name = snapshot.plantName, !name.isEmpty else { return nil }
        return name
    }

    // MARK: 名前を付ける(最初の「ふたば」)

    /// 閉じるボタン。名前のフォームを出しているときは「あとで」(閉じても、ホームの植物の下の「名前をつける」から付けられる)
    @ViewBuilder
    private var closeButton: some View {
        if showsNameForm {
            Button(Strings.Plant.nameLater, action: onClose)
                .buttonStyle(.bordered)
        } else {
            Button(Strings.Plant.celebrationClose, action: onClose)
                .buttonStyle(.borderedProminent)
        }
    }

    /// 名前のフォームを出すか: 最初の「ふたば」の演出で、名前を付ける口があり、まだ名前が無く、保存もまだのとき
    private var showsNameForm: Bool {
        guard case .stageUp(let celebration) = presentation, celebration.offersNaming, let naming else { return false }
        return !naming.didSave && plantName == nil
    }

    @ViewBuilder
    private var namingSection: some View {
        if case .stageUp(let celebration) = presentation, celebration.offersNaming, let naming {
            if naming.didSave, let note = naming.resultNote {
                // 保存できた(自分の名前が入った・相手が先に付けていた名前に決まった)
                Text(note)
                    .font(.headline)
                    .foregroundStyle(LienColors.done)
                    .multilineTextAlignment(.center)
            } else if showsNameForm {
                // まだ名前が無い: ここで付ける。「あとで」で閉じても、ホームの植物の下に「名前をつける」が残る
                PlantNameFormView(model: naming)
                    .padding(.top, LienSpacing.s)
            }
        }
    }

    // MARK: ハートを送る(P1)

    @ViewBuilder
    private var heartSection: some View {
        // 段階アップのときだけ。相手の名前が分かるときだけ(「(相手)にハートを送る」)
        if case .stageUp = presentation, let partnerName = snapshot?.partnerName {
            PlantCelebrationHeartView(partnerName: partnerName, canSend: canSendHeart, onSend: onSendHeart)
        }
    }
}
