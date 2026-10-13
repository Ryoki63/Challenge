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
//   - ボタン「(相手)にハートを送る」(P1。T15 のリアクション ❤️ を使い回す。相手が今日チェックイン済みのときだけ)
//   - 閉じるボタン
//   - 相手名義の通知には混ぜない。ウィジェットは動かさない(GROWTH §5.2)
// おかえり(2日以上あいたあと、自分がチェックインした瞬間だけ): 目をさました植物と「おかえり。また いっしょに」。空いた日数は出さない。
//
// アニメは、あとの植物がぽんと現れるだけ(視差効果を減らす設定ではそのまま出す)。VoiceOver には全体を1つのモーダルとして出す。

import SwiftUI

struct PlantCelebrationView: View {
    let presentation: PlantExperienceModel.Presentation
    /// いまの snapshot(相手の名前・植物の名前・今日の状態)
    let snapshot: PairSnapshot?
    /// 名前を付けるフォームの状態(最初の「ふたば」で、まだ名前が無いとき)。nil なら名前付けは出さない
    let naming: PlantNamingModel?
    /// 「(相手)にハートを送る」を出すか(相手が今日チェックイン済みで、リアクションの口がある)
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

    /// 「ハートを送る」ボタンの状態
    private enum HeartState {
        case idle
        case sending
        case sent
        case failed
    }

    @State private var heartState: HeartState = .idle
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
            plantsRow
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

    // MARK: 植物(変わる前 → 後)

    private var afterState: PlantCharacterState {
        switch presentation {
        case .stageUp(let celebration):
            // ふたりの葉がひらいて、驚いて喜ぶ(段階0は、ふたりの芽が光る)
            return PlantCharacterState(stage: celebration.stage, meOpen: true, partnerOpen: true, expression: .wow)
        case .welcomeBack:
            // おかえり: 目をさました植物。自分はいまチェックインした(葉がひらく)。相手の葉は今日の状態のまま
            let stage = snapshot?.plantStage ?? 0
            return PlantCharacterState(
                stage: stage,
                meOpen: true,
                partnerOpen: snapshot?.todayPartnerDone ?? false,
                expression: .wow
            )
        }
    }

    private var beforeState: PlantCharacterState? {
        guard case .stageUp(let celebration) = presentation else { return nil }
        guard let before = celebration.beforeStage else { return .solo } // はじめまして: 土の中で眠っていた姿から
        return PlantCharacterState(stage: before, meOpen: true, partnerOpen: true, expression: .normal)
    }

    /// 植物の行の高さ(あとの植物がこの高さに収まる大きさにする)
    private static let plantsRowHeight: CGFloat = 280

    private var plantsRow: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = Self.plantsRowHeight
            // 変わる前(小さく)→ 後(大きく)。3:4 のキャンバスなので、幅は高さの 0.75 倍まで
            let afterWidth = min(width * (beforeState == nil ? 0.7 : 0.58), height * 0.75)
            let beforeWidth = min(width * 0.28, height * 0.5 * 0.75)
            let beforeHeight = beforeWidth / 0.75
            HStack(alignment: .bottom, spacing: LienSpacing.s) {
                if let beforeState {
                    PlantCharacterView(state: beforeState)
                        .frame(width: beforeWidth)
                    // 矢印は、変わる前の植物の顔の高さのあたり(キャンバスの下から約 4 割)に置く
                    Image(systemName: "arrow.right")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, max(beforeHeight * 0.41 - 10, 0))
                        .accessibilityHidden(true)
                }
                PlantCharacterView(state: afterState)
                    .frame(width: afterWidth)
                    .scaleEffect(revealed ? 1 : 0.7, anchor: .bottom)
                    .opacity(revealed ? 1 : 0)
            }
            .frame(width: width, height: height, alignment: .bottom)
        }
        .frame(height: Self.plantsRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plantsAccessibilityLabel)
    }

    /// VoiceOver: 変わる前と後の段階
    private var plantsAccessibilityLabel: String {
        switch presentation {
        case .stageUp(let celebration):
            let after = Strings.Plant.celebrationAfter(Strings.Plant.stageName(celebration.stage))
            guard let before = celebration.beforeStage else { return after }
            return Strings.Plant.celebrationBefore(Strings.Plant.stageName(before)) + "。" + after
        case .welcomeBack:
            return Strings.Plant.stageName(snapshot?.plantStage ?? 0)
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
        if case .stageUp = presentation, let partnerName = snapshot?.partnerName,
           canSendHeart || heartState != .idle {
            VStack(spacing: LienSpacing.xs) {
                switch heartState {
                case .idle, .failed:
                    Button {
                        Task { await sendHeart() }
                    } label: {
                        Text(Strings.Plant.celebrationHeart(partnerName))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if heartState == .failed {
                        Text(Strings.Plant.celebrationHeartError)
                            .font(.footnote)
                            .foregroundStyle(LienColors.gentleAlert)
                            .multilineTextAlignment(.center)
                    }
                case .sending:
                    Text(Strings.Plant.celebrationHeartSending)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .sent:
                    Text(Strings.Plant.celebrationHeartSent)
                        .font(.footnote)
                        .foregroundStyle(LienColors.done)
                }
            }
        }
    }

    private func sendHeart() async {
        heartState = .sending
        heartState = await onSendHeart() ? .sent : .failed
    }
}
