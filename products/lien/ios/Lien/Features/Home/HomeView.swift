// HomeView.swift — ホーム画面(T13+T14 / REQUIREMENTS §3.4, §3.5, §3.9, §3.10 / §6)
//
// 構成: 植物(SVG レイヤーの重ね合わせ+名前+ゲージの文+今日のひとこと — PlantHeroView。約束の絵文字は 2026-10-26 に UI から廃止)/ ストリーク /
//       お休みチケットの残数バッジ(T19a #19。0枚でも出す — REQUIREMENTS §3.6)/ ふたりの今日(自分・相手チップ+相手の今日の写真)/
//       チェックインフロー(CheckinFlowView — 1タップ完了+写真添付+当日取消)。
// 植物の全画面の演出(段階アップ・おかえり — PlantCelebrationView)は、ホームの上に重ねるオーバーレイ(PB #57)。
// 名前を付ける・変えるシート(PlantNameSheet)はホームから開く。
// 相手の今日の写真(PV #59)は、相手が写真を添えた日だけ出る(PartnerPhotoView.swift)。写真が無い日・
// 取得に失敗したときは何も出さない。タップで原寸を全画面で見る。
// 文言は Strings.Home / Strings.Checkin、色・余白は DesignSystem の定数に集約(DESIGN §3.8)。
// 表示原則(§3.10)はウィジェット(LienWidgetEntryView)と揃える:
//   自分未完 = 自分側グレー / 相手が先に完了 =「(名前)が待ってるよ」。
// ソロ状態(pairId = null)は土の中で眠るタネの子+誘導文言+「相手を招待する」導線(招待 UI 本体は T11 PairingView —
// RootView がシートで開く。issue #55)。チェックインはソロでもできる(写真・つつく・リアクションはペア後)。
// 未送信キュー(pending_ops.json)の再送は表示時+フォアグラウンド復帰時(DESIGN §3.7)。
// サーバーとの同期(GET /snapshot)は AppModel が行い、結果は App Group 経由で reloadToken の変化として届く。

import SwiftUI

@MainActor
struct HomeView: View {
    @State private var viewModel: HomeViewModel
    @State private var showsHistory = false
    @Environment(\.scenePhase) private var scenePhase

    /// AppModel が snapshot を同期・保存するたびに増える値。変化したら App Group から読み直す
    private let reloadToken: Int
    /// ソロ状態の「相手を招待する」。nil なら導線を出さない(ペア成立後・プレビュー)
    private let onInvite: (() -> Void)?
    /// 相手のコンテンツ(ニックネーム・約束の文・植物の名前)の長押しメニュー(通報・ブロック)と、その確認の表示。
    /// nil(Stub 構成・プレビュー)なら付けない(写真の長押しは PartnerPhotoModel.actions — T23 #23)
    private let moderation: ModerationViewModel?
    /// カレンダー履歴(T18 #18)。nil なら導線を出さない(プレビュー・履歴を使わない組み立て)
    private let historyRepository: HistoryRepository?
    /// ペイウォール(T33)。nil なら課金の導線を出さない(プレビュー・課金を使わない組み立て)
    private let paywall: PaywallDependencies?
    /// 出しているペイウォールの文脈(チケット切れなど)。nil = 出していない
    @State private var paywallContext: PaywallContext?

    init(
        viewModel: HomeViewModel,
        reloadToken: Int = 0,
        onInvite: (() -> Void)? = nil,
        moderation: ModerationViewModel? = nil,
        historyRepository: HistoryRepository? = nil,
        paywall: PaywallDependencies? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.reloadToken = reloadToken
        self.onInvite = onInvite
        self.moderation = moderation
        self.historyRepository = historyRepository
        self.paywall = paywall
    }

    /// プレビュー・簡易構成用(本番の依存は RootView が HomeViewModel として渡す)
    init(store: AppGroupStore?, checkinService: CheckinPerforming) {
        self.init(viewModel: HomeViewModel(store: store, checkinService: checkinService))
    }

    var body: some View {
        ScrollView {
            Group {
                if let snapshot = viewModel.snapshot {
                    SnapshotContent(
                        viewModel: viewModel,
                        snapshot: snapshot,
                        onInvite: onInvite,
                        moderation: moderation,
                        onShowPaywall: showPaywall,
                        onShowHistory: showHistory
                    )
                } else {
                    EmptyHomeContent()
                }
            }
            // 内容の周りの余白。上の余白(24pt)は、植物の上に出る吹き出しの余白の計算が前提にしている
            // (WhisperBubbleMetrics.parentTopPadding。変えるときは、そちらも合わせる)
            .padding(LienSpacing.l)
        }
        // 主役の「できた!」はスクロールの外に固定する(植物の高さ・文字の大きさで位置が動かない)
        .safeAreaInset(edge: .bottom) {
            if viewModel.snapshot != nil {
                HomeActionBar(viewModel: viewModel, onShowPaywall: showPaywall)
            }
        }
        // 植物の全画面の演出(段階アップ・おかえり — PB #57)。ホームの上に重ねる。ナビゲーションバーも隠して全画面に見せる
        .overlay { celebrationOverlay }
        .hidesNavigationBar(viewModel.plantExperience.presentation != nil)
        .animation(.easeInOut(duration: 0.25), value: viewModel.plantExperience.presentation)
        // 名前を付ける・変えるシート(PB #57)
        .sheet(isPresented: nameSheetBinding) {
            if let naming = viewModel.plantNaming {
                PlantNameSheet(model: naming)
            }
        }
        // シェア画像(T22)。ホームの導線と、節目(7/30/100/365日)のお祝いの両方がここから開く
        .sheet(item: sharePresentationBinding) { presentation in
            if let shareImage = viewModel.shareImage {
                ShareImageSheet(model: shareImage, presentation: presentation)
            }
        }
        // 通報の確認・メールを開けなかったときのアラート・ブロック(ペア解消)の説明シート(T23 #23)
        .moderationPresentation(moderation)
        // ペイウォール(T33 / REQUIREMENTS §3.14)。文脈はチケット切れから開く(節目・アルバムは画面側の実装後)
        .sheet(item: $paywallContext) { context in
            if let paywall {
                PaywallView(model: paywall.makeViewModel(context: context))
            }
        }
        // カレンダー履歴(T18 #18)。ペア成立後のホームからのみ開ける
        // カレンダー履歴(T18 #18)の入口は、右上の常設ボタンをやめて植物の長押しにした
        // (2026-10-25 の UI/UX レビュー。月に数回しか見ないものに常設の場所を与えない)。
        // シートは名前付けと重ならないよう、ホームの NavigationStack に push する
        .navigationDestination(isPresented: $showsHistory) {
            if let historyRepository {
                HistoryView(repository: historyRepository)
            }
        }
        .onAppear {
            viewModel.load()
            viewModel.plantExperience.homeDidAppear()
        }
        // 今日のひとこと(吹き出し)は数秒で消える。出し直す(タップ)たびにタイマーを作り直し、VoiceOver へ読み上げる
        .plantWhisperLifetime(viewModel.plantExperience)
        .task { await viewModel.flushPendingOps() }
        // 前面に出したまま日付が変わったら、相手の写真を消す(PV #59。View が消えるとキャンセルされる)
        .task { await viewModel.partnerPhoto?.watchDayChanges() }
        // 相手の写真をタップしたときの全画面(PV #59)
        .background {
            if let photo = viewModel.partnerPhoto {
                PartnerPhotoViewerHost(model: photo, partnerName: viewModel.snapshot?.partnerName)
            }
        }
        .onChange(of: reloadToken) { viewModel.load() }
        .onChange(of: scenePhase) {
            // フォアグラウンド復帰時の再送(DESIGN §3.7。snapshot 表示も読み直す)
            if scenePhase == .active {
                viewModel.load()
                // 前面に出したまま日付が変わった次の朝も「その日はじめて」(今日のひとこと)
                viewModel.plantExperience.homeDidAppear()
                // バックグラウンドで観測して出しておいた段階アップの演出を、前面に戻って実際に見せた(ここで「見せた」と記録する)
                viewModel.plantExperience.presentationDidAppear()
                Task { await viewModel.flushPendingOps() }
            }
        }
    }

    /// ペイウォールを開く導線(課金を使わない組み立てでは nil)
    private var showPaywall: ((PaywallContext) -> Void)? {
        guard paywall != nil else { return nil }
        return { context in paywallContext = context }
    }

    /// 植物の長押しからカレンダー履歴を開く導線(履歴を使わない組み立て・ソロでは nil)
    private var showHistory: (() -> Void)? {
        guard historyRepository != nil, viewModel.snapshot?.pairId != nil else { return nil }
        return { showsHistory = true }
    }

    /// 名前のシートを出しているか。観測する状態は body の中で読む(Binding の getter の中では読まない — T23 #23)
    private var nameSheetBinding: Binding<Bool> {
        let isShown = viewModel.plantNaming?.isSheetPresented ?? false
        return Binding(
            get: { isShown },
            set: { viewModel.plantNaming?.isSheetPresented = $0 }
        )
    }

    /// シェア画像のシート(ホームの導線・節目のお祝い)。閉じたときはモデル側で「見た」を記録する。
    /// 観測する状態は body の中で読む(Binding の getter の中では読まない — T23 #23)
    private var sharePresentationBinding: Binding<ShareImageModel.Presentation?> {
        let presentation = viewModel.shareImage?.presentation
        return Binding(
            get: { presentation },
            set: { viewModel.shareImage?.setPresentation($0) }
        )
    }

    /// 植物の全画面の演出(段階アップ・おかえり)。無いときは何も出さない
    @ViewBuilder
    private var celebrationOverlay: some View {
        if let presentation = viewModel.plantExperience.presentation {
            PlantCelebrationView(
                presentation: presentation,
                snapshot: viewModel.snapshot,
                naming: viewModel.plantNaming,
                // 今日すでにリアクションを送っていたら出さない(付け替えは相手に届かない — HomeViewModel.canSendHeart)
                canSendHeart: viewModel.canSendHeart,
                // T15 のリアクション ❤️ を使い回す(相手の今日のチェックインへ)。失敗の文言は演出の中に出す
                onSendHeart: { await viewModel.sendReaction(stamp: .heart) },
                onClose: { viewModel.plantExperience.dismissPresentation() }
            )
            .id(presentation.id)
            .transition(.opacity)
            // 前面のシーンで実際に表示した: ここで初めて「見せた」と記録する(バックグラウンドで観測しただけでは記録しない)。
            // active になる前に表示された分は、scenePhase の変化(上の onChange)で記録する
            .onAppear {
                if scenePhase == .active { viewModel.plantExperience.presentationDidAppear() }
            }
        }
    }
}

// MARK: - 全画面の演出の間だけナビゲーションバーを隠す

private extension View {
    /// 全画面の演出の間は、ナビゲーションバー(歯車)も隠す。macOS の型検査(Xcode 無しの下見)では何もしない
    @ViewBuilder
    func hidesNavigationBar(_ hidden: Bool) -> some View {
        #if os(iOS)
        toolbar(hidden ? .hidden : .automatic, for: .navigationBar)
        #else
        self
        #endif
    }
}

// MARK: - snapshot あり(通常表示)

/// ホームの中身(スクロールの外側を除く)。ストア用スクリーンショット(issue #80)は、
/// ImageRenderer が ScrollView を描けないため、この View を直接 端末と同じ大きさで描く。
struct SnapshotContent: View {
    let viewModel: HomeViewModel
    let snapshot: PairSnapshot
    let onInvite: (() -> Void)?
    let moderation: ModerationViewModel?
    /// ペイウォールを開く(T33)。nil なら課金の導線を出さない。
    /// 既定 nil は、課金の導線を持たないストア用スクリーンショット(issue #80)の実描画のため
    var onShowPaywall: ((PaywallContext) -> Void)? = nil
    /// 植物の長押しからカレンダー履歴を開く(nil なら出さない)
    var onShowHistory: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: LienSpacing.m) {
            // 記録は一番上に1行だけ(植物の上の文脈。以前は植物とボタンの間にあって視線を割っていた)
            if viewModel.showsStreak {
                StreakLine(current: snapshot.streakCurrent, best: snapshot.streakBest)
            }

            PlantHeroView(
                state: viewModel.plantState,
                sways: viewModel.plantSways,
                accessibilityText: viewModel.plantAccessibilityText,
                plantName: viewModel.plantName,
                canRename: viewModel.canRenamePlant,
                canName: viewModel.canNamePlant,
                gaugeText: viewModel.growthGaugeText,
                whisper: viewModel.plantExperience.whisper,
                canWhisper: viewModel.canWhisper,
                nameNotice: viewModel.plantExperience.nameNotice,
                moderation: moderation,
                onShowHistory: onShowHistory,
                onTapPlant: { viewModel.plantExperience.plantTapped() },
                onNameAction: { viewModel.presentPlantNameSheet() },
                onDismissNameNotice: { viewModel.plantExperience.dismissNameNotice() }
            )

            if viewModel.isSolo {
                // ソロ状態: 眠るタネの子+誘導文言+招待導線(§3.2, §3.9。招待画面本体は PairingView — T11)
                VStack(spacing: LienSpacing.xs) {
                    Text(Strings.Home.soloCaption)
                        .font(.subheadline)
                    Text(Strings.Home.soloInviteHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let onInvite {
                        Button(action: onInvite) {
                            Text(Strings.Home.inviteButton)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, LienSpacing.xs)
                    }
                }
            }

            // 約束と今日の状態。チップのカードはやめ、1行の文にした(葉がすでに誰がやったかを示している)
            PairStatusArea(viewModel: viewModel, snapshot: snapshot, moderation: moderation)

            // チケットは 0 枚のときだけ出す(常時出すと在庫管理の印象になり、守られている実感にならない)
            if let ticketBalance = viewModel.ticketBalance, ticketBalance == 0 {
                // タップでペイウォール(チケット切れの文脈)を開ける(T33)
                TicketBalanceBadge(balance: ticketBalance, onTap: { onShowPaywall?(.ticketEmpty) })
            }
        }
    }
}

// MARK: - 画面下に固定する操作の帯
//
// 主役の「できた!」は、スクロールの位置に関係なく**いつも同じ場所**に置く。
// 以前はスクロールの中ほど(画面の 84% の位置)にあり、植物の高さや文字の大きさで毎回動いた。
// 補助の操作(つつく・リアクション・シェア)は、その上に1行だけ。
// 帯は半透明の材質で敷き、下を内容が流れても読めるようにする。

@MainActor
struct HomeActionBar: View {
    let viewModel: HomeViewModel
    var onShowPaywall: ((PaywallContext) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 帯の上端の細い区切り。ダークモードの .bar は背景とほぼ同じ明るさで、
            // 下を内容が流れたときに帯の始まりが見えなくなる
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 0.5)

            VStack(spacing: LienSpacing.s) {
                SecondaryActionRow(viewModel: viewModel, onShowPaywall: onShowPaywall)
                // 主役の1タップ(チェックイン+写真添付+当日取消 — T14)
                CheckinFlowView(viewModel: viewModel)
            }
            .padding(.horizontal, LienSpacing.l)
            .padding(.top, LienSpacing.s)
            .padding(.bottom, LienSpacing.s)
        }
        .background(.bar)
    }
}

// MARK: - ストリーク(§3.5。最高記録は永続表示 =「ふたりの財産」)
//
// 1行に畳む。以前は「ふたりの記録 / 🔥 23日 / 最高記録 40日」の3行中央揃えで、
// 植物と主役のボタンの間にあって視線を割っていた。数字だけを強く、ほかは小さく添える。

private struct StreakLine: View {
    let current: Int
    let best: Int

    var body: some View {
        HStack(spacing: LienSpacing.xs) {
            Text(Strings.Home.streakCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Strings.Home.streakDays(current))
                .font(.headline.monospacedDigit())
            Text("・")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Strings.Home.streakBestNote(best))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 約束と今日の状態(§3.10 の表示原則)
//
// チップのカード2枚をやめ、「筋トレ ・ ランニング」の1行にした(約束の絵文字は 2026-10-26 に UI から廃止)。
// 誰が今日やったかは、植物の葉(左=自分・右=相手がひらいているか)がすでに示している。
// 同じことを2つの表現(葉とカード)で持っていたので、カードを落とした。
// 未完の情報は葉と、下の「(名前)が待ってるよ」の文が担う(§3.10)。

private struct PairStatusArea: View {
    let viewModel: HomeViewModel
    let snapshot: PairSnapshot
    let moderation: ModerationViewModel?

    var body: some View {
        VStack(spacing: LienSpacing.s) {
            // 自分の約束はソロでも出す(以前は今日のチップにしか出ておらず、チップを落とすと見えなくなる)
            HStack(spacing: LienSpacing.xs) {
                promiseSegment(
                    title: snapshot.myPromiseTitle,
                    done: snapshot.todayMeDone
                )
                if !viewModel.isSolo {
                    Text("・")
                        .foregroundStyle(.tertiary)
                    promiseSegment(
                        title: snapshot.partnerPromiseTitle,
                        done: snapshot.todayPartnerDone
                    )
                    // 相手のニックネームと約束の文: 長押しで通報・ブロック(ペア解消)できる(T23 #23)
                    .partnerChipMenu(
                        moderation,
                        nickname: snapshot.partnerName,
                        promiseEmoji: snapshot.partnerPromiseEmoji,
                        promiseTitle: snapshot.partnerPromiseTitle
                    )
                }
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)

            if let waiting = viewModel.partnerWaitingText {
                // 相手が先に完了 →「(名前)が待ってるよ」(§3.10)
                Text(waiting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if viewModel.showsBothDoneCelebration {
                // 両者完了の演出(§3.4)
                Text(Strings.Home.bothDoneCelebration)
                    .font(.headline)
                    .foregroundStyle(LienColors.done)
            }

            // 相手が今日添えた写真(§3.11 / PV #59)。写真が無い日・取得に失敗したときは何も出ない
            PartnerPhotoArea(model: viewModel.partnerPhoto, partnerName: snapshot.partnerName)
        }
    }

    /// 1人分の約束(文)。今日やった人の文だけ濃くする(葉と同じ意味を、文字でも薄く二重に持つ)
    private func promiseSegment(title: String?, done: Bool) -> some View {
        Text(title ?? Strings.Home.promiseUnsetLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(done ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
}

// MARK: - 補助の操作(つつく・リアクション・シェア)
//
// 全幅の .bordered ボタンを縦に並べると、主役の「できた!」と強さが並んでしまう。
// 補助は1行の小さなボタンにまとめ、文言もアイコン+短い語にする。メッセージは行の上に1つだけ出す。

@MainActor
private struct SecondaryActionRow: View {
    let viewModel: HomeViewModel
    let onShowPaywall: ((PaywallContext) -> Void)?

    var body: some View {
        if hasAnyAction || message != nil {
            VStack(spacing: LienSpacing.xs) {
                if let message {
                    Text(message.text)
                        .font(.footnote)
                        .foregroundStyle(message.isError ? LienColors.gentleAlert : LienColors.done)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: LienSpacing.s) {
                    NudgeArea(viewModel: viewModel, compact: true)
                    ReactionArea(viewModel: viewModel, compact: true)
                    if viewModel.canShareRecord {
                        Button {
                            viewModel.presentShareImage()
                        } label: {
                            Label(Strings.Share.shortButton, systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(LienColors.shareAccent)
                    }
                }
                .font(.footnote)
            }
        }
    }

    private var hasAnyAction: Bool {
        viewModel.canNudge || viewModel.isSendingNudge
            || viewModel.canReact || viewModel.isSendingReaction
            || viewModel.canShareRecord
    }

    /// つつく・リアクションの結果は、行の上に1つだけ出す(2つ並べると同じ強さの行が2本できる)
    private var message: (text: String, isError: Bool)? {
        if let message = viewModel.nudgeErrorMessage ?? viewModel.reactionErrorMessage {
            return (message, true)
        }
        if let note = viewModel.nudgeSentNote ?? viewModel.reactionSentNote {
            return (note, false)
        }
        return nil
    }
}

// MARK: - つつく(相手未完のときだけ押せる。1日3回まで — REQUIREMENTS §3.7 / T15)

@MainActor
private struct NudgeArea: View {
    let viewModel: HomeViewModel
    /// 補助の行に並べるときは、メッセージを出さずボタンだけを小さく描く(親が文言をまとめる)
    var compact = false
    @State private var showsSheet = false

    var body: some View {
        if viewModel.canNudge || viewModel.isSendingNudge {
            VStack(spacing: LienSpacing.xs) {
                if !compact { nudgeMessageArea }
                Button {
                    showsSheet = true
                } label: {
                    Group {
                        if viewModel.isSendingNudge {
                            ProgressView()
                        } else if compact {
                            Label(Strings.Nudge.button, systemImage: "hand.tap")
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(Strings.Nudge.button)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)
                .disabled(!viewModel.canNudge)
            }
            .sheet(isPresented: $showsSheet) {
                NudgeSheet(viewModel: viewModel, isPresented: $showsSheet)
            }
        }
    }

    @ViewBuilder
    private var nudgeMessageArea: some View {
        if let message = viewModel.nudgeErrorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(LienColors.gentleAlert)
                .multilineTextAlignment(.center)
        } else if let note = viewModel.nudgeSentNote {
            Text(note)
                .font(.footnote)
                .foregroundStyle(LienColors.done)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - リアクション(相手の今日のチェックインにスタンプ1つ — REQUIREMENTS §3.8 / T15)

@MainActor
private struct ReactionArea: View {
    let viewModel: HomeViewModel
    /// 補助の行に並べるときは、メッセージを出さずボタンだけを小さく描く(親が文言をまとめる)
    var compact = false
    @State private var showsSheet = false

    var body: some View {
        if viewModel.canReact || viewModel.isSendingReaction {
            VStack(spacing: LienSpacing.xs) {
                if !compact { reactionMessageArea }
                Button {
                    showsSheet = true
                } label: {
                    Group {
                        if viewModel.isSendingReaction {
                            ProgressView()
                        } else if compact {
                            Label(Strings.Reaction.button, systemImage: "heart")
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(Strings.Reaction.button)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)
                .disabled(!viewModel.canReact)
            }
            .sheet(isPresented: $showsSheet) {
                ReactionSheet(viewModel: viewModel, isPresented: $showsSheet)
            }
        }
    }

    @ViewBuilder
    private var reactionMessageArea: some View {
        if let message = viewModel.reactionErrorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(LienColors.gentleAlert)
                .multilineTextAlignment(.center)
        } else if let note = viewModel.reactionSentNote {
            Text(note)
                .font(.footnote)
                .foregroundStyle(LienColors.done)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - 空状態(snapshot 未取得。AppModel の GET /snapshot 同期で自己修復される — DESIGN §4)

private struct EmptyHomeContent: View {
    var body: some View {
        VStack(spacing: LienSpacing.m) {
            PlantCharacterView(state: .solo)
                .frame(width: 150, height: 200) // 3:4
                .padding(.top, LienSpacing.xl)
            Text(Strings.Home.emptyTitle)
                .font(.title3.bold())
            Text(Strings.Home.emptyMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Preview(モック snapshot — temp dir ストア)

#if DEBUG
extension AppGroupStore {
    /// Preview 用: temp dir をコンテナに snapshot を書き込んだストア
    static func preview(snapshot: PairSnapshot?) -> AppGroupStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HomePreview-\(UUID().uuidString)", isDirectory: true)
        let store = AppGroupStore(containerURL: url)
        if let snapshot {
            try? store.saveSnapshot(snapshot)
        }
        return store
    }
}

extension PairSnapshot {
    /// Preview 用のモック snapshot
    static func previewValue(
        pairId: String? = "pair-1",
        todayMeDone: Bool = false,
        todayPartnerDone: Bool = true,
        plantStage: Int = 3,
        plantGrownDays: Int? = 11,
        plantStageFloor: Int? = 7,
        plantNextStageAt: Int? = 14,
        plantMood: PlantMood = .fidget,
        ticketBalance: Int? = 2
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: pairId,
            updatedAt: Date(),
            streakCurrent: 23,
            streakBest: 40,
            todayMeDone: todayMeDone,
            todayPartnerDone: todayPartnerDone,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: plantStage,
            plantGrownDays: plantGrownDays,
            plantStageFloor: plantStageFloor,
            plantNextStageAt: plantNextStageAt,
            plantMood: plantMood,
            plantName: "みどり",
            hasPartnerPhotoToday: false,
            ticketBalance: ticketBalance
        )
    }
}

#Preview("ペア成立・相手が先に完了") {
    HomeView(
        store: AppGroupStore.preview(snapshot: PairSnapshot.previewValue()),
        checkinService: LocalEchoCheckinService()
    )
}

#Preview("ふたり達成") {
    HomeView(
        store: AppGroupStore.preview(snapshot: PairSnapshot.previewValue(
            todayMeDone: true,
            todayPartnerDone: true,
            plantMood: .happy
        )),
        checkinService: LocalEchoCheckinService()
    )
}

#Preview("チケット0枚(バッジは出したまま)") {
    HomeView(
        store: AppGroupStore.preview(snapshot: PairSnapshot.previewValue(ticketBalance: 0)),
        checkinService: LocalEchoCheckinService()
    )
}

#Preview("ソロ(土の中で眠るタネの子)") {
    HomeView(
        store: AppGroupStore.preview(snapshot: PairSnapshot.previewValue(
            pairId: nil,
            todayPartnerDone: false,
            plantStage: 0,
            plantMood: .normal,
            ticketBalance: nil
        )),
        checkinService: LocalEchoCheckinService()
    )
}

#Preview("空状態(snapshot なし)") {
    HomeView(
        store: AppGroupStore.preview(snapshot: nil),
        checkinService: LocalEchoCheckinService()
    )
}
#endif
