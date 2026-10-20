// StoreScreenshotRenderTests.swift — ストア用スクリーンショットを「本物の View」から描く(issue #80 / MK7)
//
// 目的: D1(v4「タネの子」)に合わせた App Store 用画像を、実際の画面から作る。
// 実機の無い CI でも「実際の画面と違う画像」を作らないために、次の2段階で描く(どちらも ImageRenderer)。
//
//   1. アプリの本物の View(HomeView / HistoryView / WidgetRootView / ShareImageCardView)を、
//      端末と同じポイント数(6.7in = 430×932 / 6.1in = 393×852)・3倍で描く
//      → ios/build/store-screens/raw/<size>/<id>.png(証拠。コミットはしない)
//   2. 1 を StoreScreenshotFrameView の端末枠に差し込み、キャプションと合成する
//      → ios/build/store-screens/<size>/<id>.png(コミットする完成画像)
//
// キャプションの正本は products/lien/marketing/screenshots/captions.json。文言を変えたらこのテストを回して
// 画像を作り直す(README.md の手順)。完成画像と captions.json のずれは marketing/tools/verify_screenshots.py が CI で止める。
//
// 端末の状態は固定(デモ名は REQUIREMENTS §3.12 の例と同じ あおい / ゆうき、ストリークは 23日)。
// システムが描くもの(ステータスバー・ナビゲーションバー・壁紙・他のアプリのアイコン)は描かない。
// ウィジェットはウィジェット自身の実描画(白い角丸の上)で、ホーム画面の壁紙やアイコンは作らない。

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import XCTest
@testable import Lien

// MARK: - 固定のデモデータ

private enum StoreDemo {
    /// 2026-10-20 12:00(Asia/Tokyo)。カレンダーの「今日」を固定する
    static var now: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 20
        components.hour = 12
        return Calendar.lienHistory.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// ペア成立中(あおい / ゆうき)。ストリーク 23日・植物は段階3(若葉)・チケット残り2枚
    static func paired(me: Bool, partner: Bool) -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a",
            updatedAt: now,
            streakCurrent: 23,
            streakBest: 40,
            todayMeDone: me,
            todayPartnerDone: partner,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: "ゆうき",
            partnerPromiseTitle: "ランニング",
            partnerPromiseEmoji: "🏃",
            plantStage: 3,
            plantGrownDays: 9,
            plantStageFloor: 7,
            plantNextStageAt: 14,
            plantMood: (me && partner) ? .happy : .normal,
            plantName: "みどり",
            hasPartnerPhotoToday: false,
            ticketBalance: 2
        )
    }

    /// ソロ(ペア未成立)。土の中で眠るタネの子と、招待の導線
    static func solo() -> PairSnapshot {
        PairSnapshot(
            schemaVersion: PairSnapshot.currentSchemaVersion,
            pairId: nil,
            updatedAt: now,
            streakCurrent: 0,
            streakBest: 0,
            todayMeDone: false,
            todayPartnerDone: false,
            myPromiseTitle: "筋トレ",
            myPromiseEmoji: "💪",
            partnerName: nil,
            partnerPromiseTitle: nil,
            partnerPromiseEmoji: nil,
            plantStage: 0,
            plantMood: .normal,
            plantName: nil,
            hasPartnerPhotoToday: false,
            ticketBalance: nil
        )
    }

    /// カレンダー履歴。9/21 にペア成立、10/1〜10/19 は 10/8(お休みチケット)と 10/13(途切れ)を除いてふたり達成
    static func history() -> MonthHistoryData {
        let calendar = Calendar.lienHistory
        var my: Set<String> = []
        var partner: Set<String> = []
        var streak: [String: StreakDayKind] = [:]

        guard
            let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21)),
            let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19))
        else { return .empty }

        var day = start
        while day <= end {
            let key = dateLocal(day, calendar: calendar)
            if key == "2026-10-08" {
                streak[key] = .ticket
            } else if key != "2026-10-13" {
                my.insert(key)
                partner.insert(key)
                streak[key] = .both
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return MonthHistoryData(
            pairStartedOn: "2026-09-21",
            myCheckinDays: my,
            partnerCheckinDays: partner,
            streakDays: streak
        )
    }

    static func dateLocal(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - カレンダーの取得(通信しない)

private final class StoreScreenshotHistoryRepository: HistoryRepository, @unchecked Sendable {
    private let data: MonthHistoryData

    init(data: MonthHistoryData) {
        self.data = data
    }

    func fetchMonth(_ month: HistoryMonth) async throws -> MonthHistoryData {
        data
    }
}

// MARK: - 画素(空の画像を通さない)

private struct StorePixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let width = self.width
        let height = self.height
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw StoreScreenshotError.unreadablePixels }
        data = buffer
    }

    func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    /// 左上の色と違う画素の割合(0…1)。キャプションも画面も描けていない紙を落とす
    func drawnRatio(tolerance: Int = 8) -> Double {
        let background = rgb(x: 2, y: 2)
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let pixel = rgb(x: x, y: y)
                if abs(pixel.r - background.r) > tolerance
                    || abs(pixel.g - background.g) > tolerance
                    || abs(pixel.b - background.b) > tolerance {
                    count += 1
                }
                x += 7
            }
            y += 7
        }
        let sampled = ((width + 6) / 7) * ((height + 6) / 7)
        return sampled == 0 ? 0 : Double(count) / Double(sampled)
    }
}

// MARK: - エラー

private enum StoreScreenshotError: LocalizedError {
    case unknownScene(String)
    case renderFailed(String)
    case unreadablePixels
    case pngFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownScene(let scene): return "captions.json の scene が不明です: \(scene)"
        case .renderFailed(let name): return "ImageRenderer が画像を返しませんでした: \(name)"
        case .unreadablePixels: return "描いた画像の画素を読めませんでした"
        case .pngFailed(let name): return "PNG にできませんでした: \(name)"
        }
    }
}

// MARK: - テスト

@MainActor
final class StoreScreenshotRenderTests: XCTestCase {
    /// 出力の並び順(6.7 → 6.1)。JSON の辞書順に依存しない
    private let sizeOrder = ["6.7in", "6.1in"]

    // MARK: キャプションの約束(描く前の検査)

    func testCatalogFollowsTheLayoutRules() throws {
        let catalog = try StoreScreenshotCatalog.load()

        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(catalog.frames.count, 6, "6.7in / 6.1in とも 6 枚(5〜6 枚が受入条件)")
        XCTAssertEqual(Set(catalog.sizes.keys), Set(sizeOrder), "サイズは 6.7in と 6.1in")
        XCTAssertEqual(Set(catalog.frames.map(\.id)).count, catalog.frames.count, "id が重複している")

        for (key, size) in catalog.sizes {
            // App Store Connect の必須サイズ(1290×2796 / 1179×2556)
            switch key {
            case "6.7in":
                XCTAssertEqual(size.width, 1290)
                XCTAssertEqual(size.height, 2796)
            case "6.1in":
                XCTAssertEqual(size.width, 1179)
                XCTAssertEqual(size.height, 2556)
            default:
                XCTFail("知らないサイズ: \(key)")
            }
            XCTAssertEqual(
                size.width * size.height,
                Int(size.pointWidth * 3) * Int(size.pointHeight * 3),
                "\(key): ポイント×3 が書き出しの画素数と一致しない"
            )
        }

        for frame in catalog.frames {
            XCTAssertEqual(frame.headline.count, 2, "\(frame.id): 見出しは2行(枠が2行前提)")
            for line in frame.headline {
                XCTAssertLessThanOrEqual(line.count, 13, "\(frame.id): 見出しが長すぎる(13文字まで): \(line)")
                XCTAssertFalse(line.contains("\n"))
            }
            XCTAssertLessThanOrEqual(frame.badge.count, 8, "\(frame.id): バッジが長すぎる: \(frame.badge)")
            XCTAssertLessThanOrEqual(frame.sub.count, 28, "\(frame.id): サブコピーが長すぎる: \(frame.sub)")
            XCTAssertFalse(frame.claim.isEmpty, "\(frame.id): claim(根拠)が無い。mkt-review が確かめられない")

            // 罰・恥・誇大表現を使わない(REQUIREMENTS §3.5。景表法の観点は mkt-review が最終判断する)
            let copy = ([frame.badge, frame.sub] + frame.headline).joined()
            for banned in ["失敗", "最強", "No.1", "日本一", "絶対", "必ず", "無料", "誰でも"] {
                XCTAssertFalse(copy.contains(banned), "\(frame.id): 使わない表現「\(banned)」が入っている: \(copy)")
            }
        }
    }

    // MARK: 実描画

    func testRendersAllFramesForBothSizes() async throws {
        let catalog = try StoreScreenshotCatalog.load()
        let output = outputDirectory()
        var failures: [String] = []
        var composed: [String: [String: CGImage]] = [:]
        var files: [String: [String: String]] = [:]

        for sizeKey in sizeOrder {
            guard let size = catalog.sizes[sizeKey] else {
                failures.append("\(sizeKey): captions.json にサイズが無い")
                continue
            }
            for frame in catalog.frames {
                do {
                    let screen = try await renderScreen(scene: frame.scene, size: size)
                    XCTAssertEqual(screen.width, size.width, "\(sizeKey)/\(frame.id): 画面の幅")
                    XCTAssertEqual(screen.height, size.height, "\(sizeKey)/\(frame.id): 画面の高さ")
                    XCTAssertGreaterThan(
                        try StorePixels(screen).drawnRatio(), 0.15,
                        "\(sizeKey)/\(frame.id): 画面がほぼ空(実描画に失敗している)"
                    )

                    let image = try renderFrame(frame, size: size, screen: screen)
                    XCTAssertEqual(image.width, size.width)
                    XCTAssertEqual(image.height, size.height)
                    XCTAssertGreaterThan(
                        try StorePixels(image).drawnRatio(), 0.15,
                        "\(sizeKey)/\(frame.id): 合成した画像がほぼ空"
                    )

                    try write(screen, to: output.appendingPathComponent("raw/\(sizeKey)/\(frame.id).png"))
                    try write(image, to: output.appendingPathComponent("\(sizeKey)/\(frame.id).png"))
                    composed[sizeKey, default: [:]][frame.id] = image
                    files[frame.id, default: [:]][sizeKey] = "\(sizeKey)/\(frame.id).png"
                } catch {
                    failures.append("\(sizeKey)/\(frame.id): \(error.localizedDescription)")
                }
            }
        }

        // 一覧画像(G4 で6枚を並べて見る)。6.7in の完成画像から作る
        if let sixSeven = composed["6.7in"], sixSeven.count == catalog.frames.count {
            let images = catalog.frames.compactMap { sixSeven[$0.id] }
            let sheet = StoreScreenshotContactSheetView(frames: images, canvasWidth: 1290)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 1
            renderer.isOpaque = true
            if let image = renderer.cgImage, let data = ShareImageRenderer.pngData(image) {
                try? data.write(to: output.appendingPathComponent("contact-sheet-6.7in.png"))
            } else {
                failures.append("contact-sheet: ImageRenderer が画像を返さない")
            }
        } else {
            failures.append("contact-sheet: 6.7in の6枚がそろわない")
        }

        // 生成の記録(どのキャプションから作ったか。verify_screenshots.py が照合する)
        let entries = catalog.frames.map { frame in
            StoreScreenshotManifest.FrameEntry(id: frame.id, scene: frame.scene, files: files[frame.id] ?? [:])
        }
        let manifest = StoreScreenshotManifest(
            generatedAt: Self.timestamp(),
            catalogVersion: catalog.version,
            catalogUpdated: catalog.updated,
            captionsSHA256: try Self.sha256(of: catalogData()),
            sizes: catalog.sizes.mapValues {
                StoreScreenshotManifest.SizeEntry(width: $0.width, height: $0.height, device: $0.device)
            },
            frames: entries,
            provenance: provenance()
        )
        try Self.writeManifest(manifest, to: output.appendingPathComponent("manifest.json"))

        XCTAssertTrue(failures.isEmpty, "描けなかった画像: \(failures.joined(separator: " / "))")
        XCTAssertEqual(entries.count, catalog.frames.count, "完成画像の数(フレーム)")
        XCTAssertEqual(entries.reduce(0) { $0 + $1.files.count }, sizeOrder.count * catalog.frames.count, "完成画像の数(サイズ×フレーム)")
    }

    // MARK: 画面(本物の View)

    private func renderScreen(scene: String, size: StoreScreenshotCatalog.Size) async throws -> CGImage {
        let view = try await sceneView(scene, size: size)
        guard let image = Self.render(view, points: size.pointSize) else {
            throw StoreScreenshotError.renderFailed(scene)
        }
        return image
    }

    private func renderFrame(
        _ frame: StoreScreenshotCatalog.Frame,
        size: StoreScreenshotCatalog.Size,
        screen: CGImage
    ) throws -> CGImage {
        let view = StoreScreenshotFrameView(copy: frame, canvas: size.pointSize, screen: screen)
        guard let image = Self.render(view, points: size.pointSize) else {
            throw StoreScreenshotError.renderFailed(frame.id)
        }
        return image
    }

    private func sceneView(_ scene: String, size: StoreScreenshotCatalog.Size) async throws -> AnyView {
        switch scene {
        case "home_both":
            return try homeView(StoreDemo.paired(me: true, partner: true))
        case "home_waiting":
            return try homeView(StoreDemo.paired(me: false, partner: true))
        case "home_solo":
            return try homeView(StoreDemo.solo(), onInvite: {})
        case "widget":
            return widgetScene(size: size)
        case "history":
            return await historyScene(size: size)
        case "share":
            return shareScene(size: size)
        default:
            throw StoreScreenshotError.unknownScene(scene)
        }
    }

    /// ホーム。App Group の代わりに一時ディレクトリへ snapshot を置き、本物の HomeView に読ませる
    private func homeView(_ snapshot: PairSnapshot, onInvite: (() -> Void)? = nil) throws -> AnyView {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lien-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppGroupStore(containerURL: directory)
        try store.saveSnapshot(snapshot)

        let model = HomeViewModel(store: store, checkinService: LocalEchoCheckinService())
        model.load()
        return AnyView(HomeView(viewModel: model, onInvite: onInvite))
    }

    /// ウィジェット(実寸の実描画)。システムの壁紙・アイコンは描かない
    private func widgetScene(size: StoreScreenshotCatalog.Size) -> AnyView {
        let content = WidgetContent(snapshot: StoreDemo.paired(me: true, partner: true))
        let u = size.pointWidth / 430
        return AnyView(
            VStack(spacing: 26 * u) {
                widgetCard(content, layout: .medium, width: 330 * u, height: 154 * u)
                widgetCard(content, layout: .small, width: 154 * u, height: 154 * u)
            }
            .frame(width: size.pointWidth, height: size.pointHeight)
            .background(
                LinearGradient(
                    colors: [StoreScreenshotPalette.backgroundTop, StoreScreenshotPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        )
    }

    /// ウィジェットの外枠(システムの内側の余白 16pt・白い背景・角丸)。中身は本物の WidgetRootView
    private func widgetCard(
        _ content: WidgetContent,
        layout: WidgetLayout,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        WidgetRootView(content: content, layout: layout, imageStyle: .widgetFullColor)
            .padding(16)
            .frame(width: width, height: height)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 6)
    }

    /// カレンダー履歴(通信しない repository で 10月を読む)
    private func historyScene(size: StoreScreenshotCatalog.Size) async -> AnyView {
        let model = HistoryViewModel(
            repository: StoreScreenshotHistoryRepository(data: StoreDemo.history()),
            calendar: .lienHistory,
            now: { StoreDemo.now }
        )
        await model.load()
        return AnyView(HistoryView(viewModel: model))
    }

    /// シェア画像。アプリが実際に書き出す 9:16 のカード(1080×1920)を、画面の上に置く
    private func shareScene(size: StoreScreenshotCatalog.Size) -> AnyView {
        let content = ShareImageContent(
            myName: "あおい",
            partnerName: "ゆうき",
            streakDays: 23,
            startedOn: ShareImageContent.streakStartDate(streakDays: 23, now: StoreDemo.now, calendar: .lienHistory),
            plantStage: 3,
            appName: "Lien"
        )
        let scale = min(1, (size.pointWidth - 48) / 360)
        return AnyView(
            ZStack {
                LinearGradient(
                    colors: [StoreScreenshotPalette.backgroundTop, StoreScreenshotPalette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                ShareImageCardView(content: content, format: .story)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
                    .scaleEffect(scale)
            }
            .frame(width: size.pointWidth, height: size.pointHeight)
        )
    }

    // MARK: 描画と保存

    private static func render<V: View>(_ view: V, points: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: points.width, height: points.height))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.cgImage
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let data = ShareImageRenderer.pngData(image) else {
            throw StoreScreenshotError.pngFailed(url.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// ios/build/store-screens/(gitignore 済み。CI の artifact に載せる)
    private func outputDirectory() -> URL {
        SourceTree.iosRoot(from: #filePath)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("store-screens", isDirectory: true)
    }

    private func catalogData() throws -> Data {
        try SourceTree.lienData("marketing/screenshots/captions.json")
    }

    /// ワークフローが置いた ci.json(GITHUB_SHA / GITHUB_RUN_ID)。無ければ null
    private func provenance() -> [String: String]? {
        let url = outputDirectory().appendingPathComponent("ci.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data),
            let object = json as? [String: String]
        else { return nil }
        return object
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Asia/Tokyo の ISO8601(共通ポリシー8)
    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return formatter.string(from: Date())
    }

    private static func writeManifest(_ manifest: StoreScreenshotManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

// MARK: - manifest.json(生成の記録)

struct StoreScreenshotManifest: Codable {
    struct SizeEntry: Codable {
        let width: Int
        let height: Int
        let device: String
    }

    struct FrameEntry: Codable {
        let id: String
        let scene: String
        let files: [String: String]
    }

    let generatedAt: String
    let catalogVersion: Int
    let catalogUpdated: String
    /// この画像を作った captions.json の SHA-256(verify_screenshots.py が照合する)
    let captionsSHA256: String
    let sizes: [String: SizeEntry]
    let frames: [FrameEntry]
    /// CI の実行(commit / run id)。ローカル実行では null
    let provenance: [String: String]?
}
