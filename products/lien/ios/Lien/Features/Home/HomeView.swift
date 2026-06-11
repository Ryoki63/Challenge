// HomeView.swift — ホーム画面(T13+T14 / REQUIREMENTS §3.4, §3.5, §3.9, §3.10 / §6)
//
// 構成: 植物(ドット絵+名前)/ ストリーク / ふたりの今日(自分・相手チップ)/
//       チェックインフロー(CheckinFlowView — 1タップ完了+写真添付+当日取消)。
// 文言は Strings.Home / Strings.Checkin、色・余白は DesignSystem の定数に集約(DESIGN §3.8)。
// 表示原則(§3.10)はウィジェット(LienWidgetEntryView)と揃える:
//   自分未完 = 自分側グレー / 相手が先に完了 =「(名前)が待ってるよ」。
// ソロ状態(pairId = null)は土+誘導文言の最小表示(招待 UI は T11 PairingView の責務)。
// 未送信キュー(pending_ops.json)の再送は表示時+フォアグラウンド復帰時(DESIGN §3.7)。

import SwiftUI

@MainActor
struct HomeView: View {
    @State private var viewModel: HomeViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(store: AppGroupStore?, checkinService: CheckinPerforming) {
        _viewModel = State(initialValue: HomeViewModel(
            store: store,
            checkinService: checkinService
        ))
    }

    var body: some View {
        ScrollView {
            Group {
                if let snapshot = viewModel.snapshot {
                    SnapshotContent(viewModel: viewModel, snapshot: snapshot)
                } else {
                    EmptyHomeContent()
                }
            }
            .padding(LienSpacing.l)

            #if DEBUG
            // G1 計測用ハーネス(issue #8 準備②)。Release には含まれない
            DeviceTokenDebugView()
                .padding(.horizontal, LienSpacing.l)
            #endif
        }
        .onAppear { viewModel.load() }
        .task { await viewModel.flushPendingOps() }
        .onChange(of: scenePhase) {
            // フォアグラウンド復帰時の再送(DESIGN §3.7。snapshot 表示も読み直す)
            if scenePhase == .active {
                viewModel.load()
                Task { await viewModel.flushPendingOps() }
            }
        }
    }
}

// MARK: - snapshot あり(通常表示)

private struct SnapshotContent: View {
    let viewModel: HomeViewModel
    let snapshot: PairSnapshot

    var body: some View {
        VStack(spacing: LienSpacing.m) {
            PlantArea(
                assetName: viewModel.plantAssetName,
                sways: viewModel.plantSways,
                plantName: snapshot.pairId != nil ? snapshot.plantName : nil
            )

            if viewModel.isSolo {
                // ソロ状態: 土+誘導文言の最小表示(§3.9。招待導線は PairingView — T11)
                VStack(spacing: LienSpacing.xs) {
                    Text(Strings.Home.soloCaption)
                        .font(.subheadline)
                    Text(Strings.Home.soloInviteHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if viewModel.showsStreak {
                StreakArea(current: snapshot.streakCurrent, best: snapshot.streakBest)
            }

            TodayArea(viewModel: viewModel, snapshot: snapshot)

            // チェックイン+写真添付+当日取消(T14 — Features/Checkin/CheckinFlowView.swift)
            CheckinFlowView(viewModel: viewModel)

            // TODO(T15): 相手未完のときだけ出す「つつく」ボタン(1日3回まで — §3.7)
        }
    }
}

// MARK: - 植物(§3.9。ドット絵は整数倍+ニアレストネイバー — DESIGN §3.5)

private struct PlantArea: View {
    let assetName: String
    /// fidget(そわそわ)の揺れアニメ(v0 は normal 画像+揺れで代用 — mapping.md)
    let sways: Bool
    let plantName: String?

    @State private var swayAngle: Double = 0

    var body: some View {
        VStack(spacing: LienSpacing.s) {
            PixelImage(assetName: assetName, scale: 8)
                .rotationEffect(.degrees(swayAngle), anchor: .bottom)
                .onAppear { updateSway() }
                .onChange(of: sways) { updateSway() }
                .padding(.top, LienSpacing.m)

            if let plantName, !plantName.isEmpty {
                Text(plantName)
                    .font(.headline)
            }
        }
    }

    /// CSS 的な揺れのみ(REQUIREMENTS §3.9。アニメ専用スプライトは持たない)
    private func updateSway() {
        if sways {
            swayAngle = -2
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                swayAngle = 2
            }
        } else {
            withAnimation(.default) {
                swayAngle = 0
            }
        }
    }
}

// MARK: - ストリーク(§3.5。最高記録は永続表示 =「ふたりの財産」)

private struct StreakArea: View {
    let current: Int
    let best: Int

    var body: some View {
        VStack(spacing: LienSpacing.xs) {
            Text(Strings.Home.streakCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("🔥 " + Strings.Home.streakDays(current))
                .font(.title2.bold())
            Text(Strings.Home.streakBestNote(best))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ふたりの今日(§3.10 の表示原則)

private struct TodayArea: View {
    let viewModel: HomeViewModel
    let snapshot: PairSnapshot

    var body: some View {
        VStack(spacing: LienSpacing.s) {
            if !viewModel.isSolo {
                Text(Strings.Home.todaySectionTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: LienSpacing.s) {
                TodayChip(
                    ownerLabel: Strings.Home.meFallbackLabel,
                    emoji: snapshot.myPromiseEmoji,
                    title: snapshot.myPromiseTitle,
                    done: snapshot.todayMeDone
                )
                if !viewModel.isSolo {
                    TodayChip(
                        ownerLabel: snapshot.partnerName ?? Strings.Home.partnerFallbackLabel,
                        emoji: snapshot.partnerPromiseEmoji,
                        title: snapshot.partnerPromiseTitle,
                        done: snapshot.todayPartnerDone
                    )
                }
            }

            if let waiting = viewModel.partnerWaitingText {
                // 相手が先に完了 →「(名前)が待ってるよ」(§3.10)
                Text(waiting)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if viewModel.showsBothDoneCelebration {
                // 両者完了の演出(§3.4)
                Text(Strings.Home.bothDoneCelebration)
                    .font(.headline)
                    .foregroundStyle(LienColors.done)
            }
        }
    }
}

/// 1人分の今日の状態チップ。未完 = グレー(自分未完 = 自分側グレー — §3.10。
/// ウィジェットの StatusChip と同じく未完側を落とす)
private struct TodayChip: View {
    let ownerLabel: String
    let emoji: String?
    let title: String?
    let done: Bool

    var body: some View {
        VStack(spacing: LienSpacing.xs) {
            Text(ownerLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(emoji ?? "・")
                .font(.title2)
            Text(title ?? Strings.Home.promiseUnsetLabel)
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(done ? LienColors.done : LienColors.pending)
        }
        .frame(maxWidth: .infinity)
        .padding(LienSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LienColors.chipBackground)
        )
        .opacity(done ? 1.0 : 0.55)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 空状態(snapshot 未取得。GET /snapshot による自己修復は後続 — DESIGN §4)

private struct EmptyHomeContent: View {
    var body: some View {
        VStack(spacing: LienSpacing.m) {
            PixelImage(assetName: PlantSprite.soloAssetName, scale: 6)
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
        plantMood: PlantMood = .fidget
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
            plantMood: plantMood,
            plantName: "みどり",
            hasPartnerPhotoToday: false
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

#Preview("ソロ(土だけ)") {
    HomeView(
        store: AppGroupStore.preview(snapshot: PairSnapshot.previewValue(
            pairId: nil,
            todayPartnerDone: false,
            plantStage: 0,
            plantMood: .normal
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
