// PhotoProcessor.swift — チェックイン写真のクライアント側縮小(T14 / DESIGN §5.6)
//
// - サーバーは画像処理を持たない(シンプル最優先 — issue #48)。原寸・サムネとも
//   クライアントがここで生成してからアップロードする
// - 原寸: 長辺 2048px の JPEG(ウィジェット/アプリ表示用。元写真をそのまま送らない)
// - サムネ: **200KB 以下**の JPEG(NSE が相手のウィジェット用にダウンロードする上限 —
//   DESIGN §3.4 photo_thumb.jpg 契約。T17 NSE 本実装との約束なので超えてはいけない)
// - ImageIO のみ使用(UIKit 非依存。EXIF 回転は kCGImageSourceCreateThumbnailWithTransform で反映)

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// アップロード直前の写真2点セット
struct ProcessedPhoto: Equatable, Sendable {
    /// 原寸(長辺 2048px 以下の JPEG)
    let photo: Data
    /// サムネ(200KB 以下の JPEG — NSE 契約)
    let thumb: Data
}

enum PhotoProcessor {
    enum ProcessError: Error, Equatable {
        /// 画像として読めないデータ(壊れたファイル・非対応形式)
        case unreadableImage
        /// JPEG エンコードに失敗
        case encodingFailed
        /// 反復圧縮でも 200KB 以下にできなかった(実用上は到達しない安全弁)
        case thumbnailTooLarge
    }

    /// 原寸の長辺上限(px)
    static let photoMaxPixelSize = 2048
    /// サムネの長辺上限(px)。ここから半減しながら 200KB 以下を探す
    static let thumbMaxPixelSize = 512
    /// サムネのバイト上限(NSE 契約 — DESIGN §3.4)
    static let thumbMaxBytes = 200 * 1024

    /// 元画像データ → 原寸+サムネ。CPU バウンドなので呼び出し側はメインスレッドを避けること
    /// (CheckinService は Task.detached で呼ぶ)
    static func process(_ data: Data) throws -> ProcessedPhoto {
        let photo = try downscaledJPEG(from: data, maxPixelSize: photoMaxPixelSize, quality: 0.85)
        let thumb = try thumbnailJPEG(from: data)
        return ProcessedPhoto(photo: photo, thumb: thumb)
    }

    /// 品質 → 寸法の順で反復圧縮し、200KB 以下の JPEG を作る
    static func thumbnailJPEG(from data: Data) throws -> Data {
        var maxPixelSize = thumbMaxPixelSize
        // 512px → 256px → 128px → 64px。各寸法で品質 0.7 / 0.5 / 0.3 を試す
        for _ in 0..<4 {
            for quality in [0.7, 0.5, 0.3] {
                let candidate = try downscaledJPEG(
                    from: data,
                    maxPixelSize: maxPixelSize,
                    quality: quality
                )
                if candidate.count <= thumbMaxBytes {
                    return candidate
                }
            }
            maxPixelSize /= 2
        }
        throw ProcessError.thumbnailTooLarge
    }

    /// 長辺 maxPixelSize 以下に縮小(拡大はしない)した JPEG を返す
    static func downscaledJPEG(from data: Data, maxPixelSize: Int, quality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ProcessError.unreadableImage
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // EXIF の回転を画素に焼き込む(向き情報を持たないビューアでも正しく見える)
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions as CFDictionary
            )
        else {
            throw ProcessError.unreadableImage
        }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
            )
        else {
            throw ProcessError.encodingFailed
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessError.encodingFailed
        }
        return output as Data
    }
}
