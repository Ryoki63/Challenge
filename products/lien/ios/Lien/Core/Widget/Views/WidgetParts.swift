// WidgetParts.swift — ウィジェットの小さな部品(進み具合のバー・ストリーク・2人の今日の状態 / issue #17 T17a)
//
// ホーム S / M が共有する。内容(WidgetContent)を受け取って描くだけで、状態を持たない。
// 表示原則(REQUIREMENTS §3.10): 自分未完 = 自分側をグレー(2人のチップは、未完を落とす。ホームの TodayChip と同じ)。
// チップは「完了のチェック+呼び名」(約束の絵文字は 2026-10-26 に UI から廃止)。
// 数字はストリークだけ(GROWTH §5.4): 進み具合のバーは長さだけで、数字も文も持たない。
// 文言は Strings.Widget(DESIGN §3.8)。色は下の WidgetStyle に集約する(植物の絵のパレット tools/gen_v4.py の緑)。

import SwiftUI
import WidgetKit

enum WidgetStyle {
    /// 進み具合のバーの塗り: 植物の茎の緑 #74BD52
    static let barFill = Color(.sRGB, red: 0x74 / 255, green: 0xBD / 255, blue: 0x52 / 255, opacity: 1)
    /// バーの土台(ライト・ダークどちらの背景でも見える、前景色の薄い色)
    static let barTrack = Color.primary.opacity(0.14)
    /// 完了のチェック
    static let done = Color.green
    /// 未完のチェック・落とした表示
    static let pending = Color.gray
    /// 未完側の濃さ(自分未完 = 自分側をグレー)
    static let pendingOpacity = 0.45
}

// MARK: - 進み具合のバー

/// 進み具合の細いバー(GROWTH §5.4)。数字は出さない。fraction は 0〜1(PlantProgress の区間の中での位置)
struct WidgetProgressBar: View {
    let fraction: Double
    var height: CGFloat = WidgetSmallMetrics.barHeight

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetStyle.barTrack)
                if clamped > 0 {
                    // 進みが小さくても、1点は見える(太さ分は塗る)
                    Capsule()
                        .fill(WidgetStyle.barFill)
                        .frame(width: max(proxy.size.width * CGFloat(clamped), height))
                        // 色合い(accented)表示では、塗りだけを色合いの色にする(土台は薄いまま)
                        .widgetAccentable()
                }
            }
        }
        .frame(height: height)
        // 数字も文も持たない装飾。読み上げは、ウィジェット全体の文(あと何回で次の段階 — GROWTH §5.4)が担う
        .accessibilityHidden(true)
    }
}

// MARK: - ストリーク

/// 「🔥 23日」。数字はストリークだけ
struct WidgetStreakLabel: View {
    let days: Int
    var font: Font = .caption.bold()

    var body: some View {
        Text("🔥 " + Strings.Widget.streakDays(days))
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - 2人の今日の状態

/// 1人分の今日の状態。完了のチェック+呼び名(「じぶん」「ゆうき」)の1行。未完 = 落とした表示(グレー・薄く)。
/// 約束の絵文字は出さない(2026-10-26 オーナー判断で UI から廃止)。誰の状態かは、絵文字の代わりに呼び名で示す(名前は1回だけ)
struct WidgetStatusChip: View {
    let person: WidgetContent.Person

    var body: some View {
        HStack(spacing: 3) {
            // 完了の緑・未完のグレーも、色合い(accented)表示で単色にしない(形と濃さでも見分けられる)
            WidgetImageStyle.fullColor(Image(systemName: person.done ? "checkmark.circle.fill" : "circle"))
                .font(.caption)
                .foregroundStyle(person.done ? WidgetStyle.done : WidgetStyle.pending)
            // 狭い列(iPhone SE の S)や大きい文字でも、文字が欠けないよう、縮めて収める(収まらない長い名前は末尾を省く)
            Text(person.name)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .opacity(person.done ? 1.0 : WidgetStyle.pendingOpacity)
    }
}

/// 自分・相手の2つのチップ(自分が先 = 左 / 上 — ふたりの葉の並び(左 = 自分・右 = 相手)と同じ向き。GROWTH §4.5)
struct WidgetStatusChips: View {
    /// 並べる向き。S は右の列が狭い(46〜56pt)ので縦に重ね、M は横に並べる
    enum Arrangement {
        case horizontal
        case vertical
    }

    let me: WidgetContent.Person
    let partner: WidgetContent.Person
    var arrangement: Arrangement = .horizontal
    var spacing: CGFloat = 8

    var body: some View {
        switch arrangement {
        case .horizontal:
            HStack(alignment: .top, spacing: spacing) {
                WidgetStatusChip(person: me)
                WidgetStatusChip(person: partner)
            }
        case .vertical:
            VStack(alignment: .leading, spacing: spacing) {
                WidgetStatusChip(person: me)
                WidgetStatusChip(person: partner)
            }
        }
    }
}

// MARK: - 一言

/// 「(相手)が待ってるよ」。出ないときも行を空けて、植物の大きさを状態で変えない(WidgetSmallMetrics.captionHeight)
struct WidgetCaption: View {
    let text: String?
    var font: Font = .caption2

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Color.clear
            }
        }
    }
}
