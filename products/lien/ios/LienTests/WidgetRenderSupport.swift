// WidgetRenderSupport.swift — ウィジェットの実描画テスト(WidgetRenderTests)の道具(issue #17 T17a)
//
//   - WidgetTestFrame   : 本物のウィジェットの外枠の近似(大きさ・システムの内側の余白 16pt・背景・角丸・ライト/ダーク・文字の大きさ)
//   - WidgetLockCircle  : ロック画面の円形の近似(暗い壁紙の上の半透明の円。システムの単色化(vibrant)は、白黒にして近似する)
//   - WidgetSamples     : 一覧に並べる snapshot(ペアの完了4通り・段階・新しいキーの有無・ソロ・データ無し ほか)
//   - RenderedPixels        : 描いた画像の画素を読む
// 実際のウィジェットは、システムが内側の余白・背景(containerBackground)・円形の背景(AccessoryWidgetBackground)を足す。
// ここは、その近似を作る(寸法の目安: S 141 / 158 / 170 の正方形、M 292×141 / 338×158 / 364×170、円形 約 76)。
// 中身は、本物と同じ WidgetRootView(imageStyle: .widgetFullColor — 本物と同じ装飾)を描く。

import SwiftUI
import UIKit
@testable import Lien

// MARK: - 外枠

/// 本物のウィジェットの外枠の近似。システムの内側の余白(16pt)を足して、背景を敷き、角丸で切る
struct WidgetTestFrame: View {
    let content: WidgetContent
    let layout: WidgetLayout
    let size: CGSize
    var dark = false
    var textSize: DynamicTypeSize = .large
    var cornerRadius: CGFloat = 22
    var margin: CGFloat = 16

    /// ウィジェットの背景(ライト = 白 / ダーク = 黒に近い濃い色)。余白の検査が、この色との一致を見る
    var background: Color {
        dark ? Color(white: 0.11) : Color.white
    }

    var body: some View {
        WidgetRootView(content: content, layout: layout, imageStyle: .widgetFullColor)
            .padding(margin)
            .frame(width: size.width, height: size.height)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, textSize)
    }
}

/// ロック画面の円形(直径 76)。暗い壁紙の上に半透明の円を敷く。単色化(vibrant)は、白黒にして近似する
struct WidgetLockCircle: View {
    let content: WidgetContent
    var diameter: CGFloat = 76
    var monochrome = true

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.18))
            if monochrome {
                WidgetRootView(content: content, layout: .lockCircular, imageStyle: .widgetFullColor).grayscale(1)
            } else {
                WidgetRootView(content: content, layout: .lockCircular, imageStyle: .widgetFullColor)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// ロック画面のインライン(1行。暗い壁紙の上の白い文字)
struct WidgetLockInline: View {
    let content: WidgetContent

    var body: some View {
        WidgetRootView(content: content, layout: .lockInline)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(width: 232, height: 26, alignment: .leading)
    }
}

// MARK: - 見本の snapshot

enum WidgetSamples {
    static let now = Date(timeIntervalSince1970: 1_781_166_600)

    /// ペア成立中。進み具合のキーは、段階とともに指定する(nil = キーが無い古い snapshot)
    static func paired(
        me: Bool = false,
        partner: Bool = false,
        stage: Int = 3,
        grown: Int? = 9,
        floor: Int? = 7,
        next: Int? = 14,
        streak: Int = 23,
        partnerName: String? = "ゆうき",
        mood: PlantMood = .normal
    ) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
            updatedAt: now,
            streakCurrent: streak,
            streakBest: 40,
            todayMeDone: me,
            todayPartnerDone: partner,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: partnerName,
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: stage,
            plantGrownDays: grown,
            plantStageFloor: floor,
            plantNextStageAt: next,
            plantMood: mood,
            plantName: "みどり",
            hasPartnerPhotoToday: false
        )
    }

    /// ペア未成立(自分がチェックインした日は土が光る)
    static func solo(me: Bool = false) -> PairSnapshot {
        var snapshot = paired(me: me, stage: 0, grown: 0, floor: 0, next: nil, streak: 0, partnerName: nil)
        snapshot.pairId = nil
        snapshot.partnerPromiseEmoji = nil
        snapshot.partnerPromiseTitle = nil
        return snapshot
    }

    typealias Item = (label: String, snapshot: PairSnapshot?)

    /// ホーム S / M の一覧に並べる状態
    static let homeStates: [Item] = [
        ("朝(ふたりともまだ)", paired()),
        ("自分だけ完了", paired(me: true, mood: .fidget)),
        ("相手だけ完了(待ってるよ)", paired(partner: true, mood: .fidget)),
        ("ふたりそろった", paired(me: true, partner: true, mood: .happy)),
        ("すやすや(sad)", paired(mood: .sad)),
        ("段階0(たね)・相手だけ", paired(partner: true, stage: 0, grown: 0, floor: 0, next: 1, streak: 1, mood: .fidget)),
        ("ふたば・ストリーク3桁", paired(me: true, stage: 1, grown: 2, floor: 1, next: 3, streak: 128, mood: .fidget)),
        ("みのり(最後・バーいっぱい)", paired(me: true, partner: true, stage: 9, grown: 128, floor: 100, next: nil, streak: 128, mood: .happy)),
        ("ふたりざき(花)・相手だけ", paired(partner: true, stage: 8, grown: 80, floor: 66, next: 100, streak: 45, mood: .fidget)),
        ("バー無し(新しいキーが無い)", paired(partner: true, grown: nil, floor: nil, next: nil, mood: .fidget)),
        ("長い相手の名前", paired(partner: true, partnerName: "あいうえおかきく", mood: .fidget)),
        ("ストリーク 0", paired(partner: true, streak: 0, mood: .fidget)),
        ("ソロ(自分は済み)", solo(me: true)),
        ("ソロ", solo()),
        ("データ無し", nil),
        ("のぞき(区間の後半)", paired(me: true, stage: 4, grown: 18, floor: 14, next: 21, mood: .fidget)),
    ]

    /// ロック画面の一覧に並べる状態
    static let lockStates: [Item] = [
        ("相手: ひらく", paired(partner: true)),
        ("相手: たたむ", paired(me: true)),
        ("段階0・光る芽", paired(partner: true, stage: 0, grown: 0, floor: 0, next: 1)),
        ("段階0・閉じた芽", paired(stage: 0, grown: 0, floor: 0, next: 1)),
        ("みのり・ひらく", paired(partner: true, stage: 9, grown: 120, floor: 100, next: nil)),
        ("ソロ", solo()),
        ("データ無し", nil),
        ("ストリーク 0", paired(streak: 0)),
    ]
}

// MARK: - 画素

/// 描いた画像の RGBA8 の画素(左上が原点)
struct RenderedPixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    let data: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.scale = image.scale
        self.data = data
    }

    /// 画素 (x, y) の (r, g, b, a)
    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let index = (y * width + x) * 4
        return (Int(data[index]), Int(data[index + 1]), Int(data[index + 2]), Int(data[index + 3]))
    }

    /// ポイント座標 (x, y) の画素
    func pixel(atPoint x: CGFloat, _ y: CGFloat) -> (r: Int, g: Int, b: Int, a: Int) {
        pixel(min(max(Int(x * scale), 0), width - 1), min(max(Int(y * scale), 0), height - 1))
    }

    /// 不透明な画素(α > threshold)の範囲(ポイント座標)。無ければ nil
    func paintedBounds(alphaThreshold: Int = 16) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixel(x, y).a > alphaThreshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let s = Double(scale)
        return (Double(minX) / s, Double(maxX + 1) / s, Double(minY) / s, Double(maxY + 1) / s)
    }
}
