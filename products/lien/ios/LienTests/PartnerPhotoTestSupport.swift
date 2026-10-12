// PartnerPhotoTestSupport.swift — 相手の今日の写真(PV / issue #59)のテストが共有する道具
//
//   - TestImages                 : 実在する JPEG / PNG / CGImage を、その場で作る(ImageIO。バイナリを置かない)
//   - MockPartnerPhotoProvider   : PartnerPhotoModel に注入する取得役(結果の差し替え・呼び出し記録・取得の保留)
//   - PartnerPhotoFixtures       : 日付・ID・snapshot の組み立て

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lien

// MARK: - 画像

enum TestImages {
    /// 単色の CGImage(RGBA 8bit)
    static func cgImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func photoImage(width: Int = 64, height: Int = 48) -> PartnerPhotoImage {
        PartnerPhotoImage(cgImage: cgImage(width: width, height: height))
    }

    /// 単色の JPEG。orientation は EXIF の向き(1〜8。6 = 90度回転して表示)
    static func jpegData(width: Int, height: Int, quality: Double = 0.8, orientation: Int? = nil) -> Data {
        encode(cgImage(width: width, height: height), type: UTType.jpeg, quality: quality, orientation: orientation)
    }

    /// 単色の PNG(JPEG 以外は受け付けないことの確認用)
    static func pngData(width: Int, height: Int) -> Data {
        encode(cgImage(width: width, height: height), type: UTType.png, quality: nil, orientation: nil)
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?, orientation: Int?) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil)!
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if let orientation { options[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "テスト画像のエンコードに失敗")
        return output as Data
    }
}

// MARK: - 日付・ID・snapshot

enum PartnerPhotoFixtures {
    /// 契約フィクスチャの固定時刻 2026-06-11T08:30:00Z(日本時間 2026-06-11 17:30)
    static let now = Date(timeIntervalSince1970: 1_781_166_600)
    static let today = "2026-06-11"
    static let tomorrow = "2026-06-12"

    static let pairID = "1f0c5a4e-9d3b-4c1a-8f2e-7b6d5a4c3b2a"
    static let otherPairID = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
    static let partnerUserID = "b2222222-2222-4222-8222-222222222222"
    static let partnerCheckinID = "8c2b7e5a-0d3f-4b61-9a47-2e1f5c6d7a80"

    /// 日本時間のカレンダー(端末のタイムゾーンに左右されない)
    static var tokyo: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    static func originalPath(
        pairID: String = PartnerPhotoFixtures.pairID,
        dateLocal: String = PartnerPhotoFixtures.today,
        userID: String = PartnerPhotoFixtures.partnerUserID
    ) -> String {
        "pairs/\(pairID)/\(dateLocal)/\(userID)/photo.jpg"
    }

    static func thumbnailPath(
        pairID: String = PartnerPhotoFixtures.pairID,
        dateLocal: String = PartnerPhotoFixtures.today,
        userID: String = PartnerPhotoFixtures.partnerUserID
    ) -> String {
        "pairs/\(pairID)/\(dateLocal)/\(userID)/photo_thumb.jpg"
    }

    static func reference(
        pairID: String = PartnerPhotoFixtures.pairID,
        dateLocal: String = PartnerPhotoFixtures.today
    ) -> PartnerPhotoReference {
        PartnerPhotoReference(
            pairID: pairID,
            dateLocal: dateLocal,
            photoPath: originalPath(pairID: pairID, dateLocal: dateLocal)
        )
    }

    static func thumbnail(
        pairID: String = PartnerPhotoFixtures.pairID,
        dateLocal: String = PartnerPhotoFixtures.today,
        image: PartnerPhotoImage = TestImages.photoImage()
    ) -> PartnerPhotoThumbnail {
        PartnerPhotoThumbnail(reference: reference(pairID: pairID, dateLocal: dateLocal), image: image)
    }

    /// 写真ありのペアの snapshot。updatedAt は(既定で)今日
    static func pairedSnapshot(
        pairID: String? = PartnerPhotoFixtures.pairID,
        hasPartnerPhotoToday: Bool = true,
        updatedAt: Date = PartnerPhotoFixtures.now
    ) -> PairSnapshot {
        var snapshot = SnapshotFactory.paired(todayPartnerDone: true, updatedAt: updatedAt)
        snapshot.pairId = pairID
        snapshot.hasPartnerPhotoToday = hasPartnerPhotoToday
        return snapshot
    }
}

// MARK: - 取得役のモック

/// PartnerPhotoModel に注入する取得役。結果の差し替え・呼び出しの記録・サムネ取得の保留ができる。
/// トップレベルに置き、テストクラスの @MainActor 隔離を継承させない。
/// 呼び出しは MainActor のモデルから来るが、本体はグローバル実行体で動くので、共有状態はロックで守る
final class MockPartnerPhotoProvider: PartnerPhotoProviding {
    private let lock = NSLock()
    private var _thumbnailResult: Result<PartnerPhotoThumbnail?, Error> = .success(nil)
    private var _originalResult: Result<PartnerPhotoImage, Error> = .failure(PartnerPhotoError.notFound)
    private var _thumbnailCalls: [(pairID: String, dateLocal: String)] = []
    private var _originalCalls: [PartnerPhotoReference] = []
    private var _holdsThumbnail = false
    private var _holdsOriginal = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var thumbnailResult: Result<PartnerPhotoThumbnail?, Error> {
        get { lock.withLock { _thumbnailResult } }
        set { lock.withLock { _thumbnailResult = newValue } }
    }

    var originalResult: Result<PartnerPhotoImage, Error> {
        get { lock.withLock { _originalResult } }
        set { lock.withLock { _originalResult = newValue } }
    }

    var thumbnailCalls: [(pairID: String, dateLocal: String)] { lock.withLock { _thumbnailCalls } }
    var originalCalls: [PartnerPhotoReference] { lock.withLock { _originalCalls } }

    /// true の間、loadThumbnail は release() まで返らない(取得中の状態・二重取得・取り消しの確認用)
    func holdThumbnail() { lock.withLock { _holdsThumbnail = true } }
    func holdOriginal() { lock.withLock { _holdsOriginal = true } }

    /// 保留中の取得をすべて返す(保留の前に呼んでも、以後は保留しない)
    func release() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            _holdsThumbnail = false
            _holdsOriginal = false
            let list = waiters
            waiters = []
            return list
        }
        pending.forEach { $0.resume() }
    }

    func loadThumbnail(pairID: String, dateLocal: String) async throws -> PartnerPhotoThumbnail? {
        lock.withLock { _thumbnailCalls.append((pairID, dateLocal)) }
        await waitWhileHeld { $0._holdsThumbnail }
        return try thumbnailResult.get()
    }

    func loadOriginal(of reference: PartnerPhotoReference) async throws -> PartnerPhotoImage {
        lock.withLock { _originalCalls.append(reference) }
        await waitWhileHeld { $0._holdsOriginal }
        return try originalResult.get()
    }

    private func waitWhileHeld(_ isHeld: @escaping (MockPartnerPhotoProvider) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isHeld(self) {
                waiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }
}
