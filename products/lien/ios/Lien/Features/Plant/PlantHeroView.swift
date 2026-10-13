// PlantHeroView.swift — ホームの植物まわり(植物・名前・ゲージの文・今日のひとこと・名前の知らせ / issue #57)
//
//   [吹き出し: 今日のひとこと]         ← 植物の上(レイアウトを動かさない。数秒で消える。植物のタップでもう一度。
//                                        VoiceOver には、アクション「タネの子のひとこと」と、出すたびの読み上げ)
//   [植物(ふたりの葉の下に約束の絵文字)]  ← 片方だけ完了のときは小さく揺れる(プレートは揺らさない)
//   名前(タップで変える)/「名前をつける」
//   名前の知らせ(「名前が『みどり』にかわったよ」)
//   ゲージの文(「ふたりそろって あと2回で めばえ」)
//
// 値と操作だけを受け取る(HomeViewModel に依存しない)ので、実描画のテスト(PlantRenderTests)からも描ける。
// 植物の VoiceOver の読み上げ文は accessibilityText(GROWTH §5.4。HomeViewModel.plantAccessibilityText)。
// 名前は相手が付けることもある(UGC)ので、長押しで通報・ブロックできる(T23 #23 — plantNameMenu)。
// 文言は Strings.Plant、色・余白は DesignSystem の定数に集約(DESIGN §3.8)。

import SwiftUI

struct PlantHeroView: View {
    let state: PlantCharacterState
    /// 小さな揺れ(片方だけ完了のそわそわ。PlantCharacterState.sways)
    let sways: Bool
    /// 植物の VoiceOver の読み上げ文。nil なら装飾画像として隠す
    var accessibilityText: String?
    /// 葉の下の約束の絵文字(左 = 自分 / 右 = 相手 — GROWTH §4.5)
    var meEmoji: String?
    var partnerEmoji: String?
    /// 植物の名前(ペアの鉢の名前。無ければ名前の行を出さない)
    var plantName: String?
    /// 名前の行をタップして変えられる / 「名前をつける」を出す
    var canRename = false
    var canName = false
    /// ゲージの文(nil なら出さない)
    var gaugeText: String?
    /// 今日のひとこと(吹き出し。nil なら出さない)
    var whisper: String?
    /// 植物をタップしてひとことを出せるか(ペア成立中)。出せるときだけ、VoiceOver のアクション「タネの子のひとこと」を付ける
    var canWhisper = false
    /// 相手が名前を付けた・変えた知らせ(nil なら出さない)
    var nameNotice: String?
    var moderation: ModerationViewModel?
    var onTapPlant: () -> Void = {}
    var onNameAction: () -> Void = {}
    var onDismissNameNotice: () -> Void = {}

    @State private var swayAngle: Double = 0
    /// `.footnote` の行の高さ。文字を大きくする設定に連れて広がる(吹き出しの余白を、2行ぶんの高さに合わせるため)
    @ScaledMetric(relativeTo: .footnote) private var footnoteLineHeight = WhisperBubbleMetrics.baseLineHeight

    /// 植物の枠の大きさ(3:4。キャンバス 240×320 と同じ比率)
    private static let plantWidth: CGFloat = 180
    private static let plantHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: LienSpacing.s) {
            PlantCharacterView(
                state: state,
                meEmoji: meEmoji,
                partnerEmoji: partnerEmoji,
                swayDegrees: swayAngle,
                accessibilityText: accessibilityText
            )
            // VoiceOver からも、タップと同じ「ひとこと」を出せる(吹き出しは数秒で消えるので、出し直せる口が要る)
            .accessibilityActions {
                if canWhisper {
                    Button(Strings.Plant.whisperAction) { onTapPlant() }
                }
            }
            .frame(width: Self.plantWidth, height: Self.plantHeight)
            .overlay(alignment: .top) { whisperBubble }
            // 吹き出しが植物の上に出る分の余白(出ていないときも同じ。レイアウトを動かさない)。
            // 最大2行の吹き出しが、文字を大きくしても ScrollView の上端に食い込まないよう、行の高さに連れて広げる
            .padding(.top, WhisperBubbleMetrics.roomAbovePlant(lineHeight: footnoteLineHeight))
            .contentShape(Rectangle())
            .onTapGesture { onTapPlant() }
            .onAppear { updateSway() }
            .onChange(of: sways) { updateSway() }

            nameRow

            if let nameNotice {
                HStack(spacing: LienSpacing.xs) {
                    Text(nameNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(action: onDismissNameNotice) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Strings.Plant.nameNoticeClose)
                }
            }

            if let gaugeText {
                Text(gaugeText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // 植物の読み上げ文(accessibilityText — GROWTH §5.4)の最後の文と同じなので、重ねて読み上げない
                    .accessibilityHidden(accessibilityText != nil)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: whisper)
    }

    // MARK: 名前

    @ViewBuilder
    private var nameRow: some View {
        if let plantName, !plantName.isEmpty {
            if canRename {
                // タップで変える。長押しは通報・ブロック(名前はどちらのペアも付けられる — T23 #23)
                Button(action: onNameAction) {
                    HStack(spacing: LienSpacing.xs) {
                        Text(plantName)
                            .font(.headline)
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true) // 鉛筆の絵は装飾(ボタンの意味はヒントで伝える)
                    }
                }
                .buttonStyle(.plain)
                .plantNameMenu(moderation, plantName: plantName)
                .accessibilityHint(Strings.Plant.renameHint)
            } else {
                Text(plantName)
                    .font(.headline)
                    .plantNameMenu(moderation, plantName: plantName)
            }
        } else if canName {
            // 最初の「ふたば」の演出を閉じても、名前が付くまで残る(GROWTH §5.3)
            Button(Strings.Plant.nameButton, action: onNameAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: 吹き出し(今日のひとこと)

    /// 植物の枠の上に、枠の外へはみ出して出す(下端が枠の上端の `gap` 上)。レイアウトは動かさない。タップは植物に通す。
    /// 位置は、枠と同じ高さの入れ物の下端に吹き出しを置き、その分だけ上へずらして決める
    /// (alignmentGuide は、実描画のテスト(ImageRenderer)で効かなかったので使わない — 吹き出しが植物の絵に重なっていた)
    @ViewBuilder
    private var whisperBubble: some View {
        if let whisper {
            WhisperBubbleView(text: whisper)
                .frame(width: WhisperBubbleMetrics.width)
                .frame(height: Self.plantHeight, alignment: .bottom)
                .offset(y: -(Self.plantHeight + WhisperBubbleMetrics.gap))
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                .allowsHitTesting(false)
        }
    }

    // MARK: 揺れ

    /// 揺れのみ(REQUIREMENTS §3.9。アニメ専用の絵は持たない。葉の開閉は PlantCharacterView が差し替えで見せる)。
    /// 回すのは PlantCharacterView の中(プレート以外 — ダークモードで背景の四角を一緒に傾けない)
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
