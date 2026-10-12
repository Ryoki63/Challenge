// PartnerPhotoLoader.swift — 署名付き URL の写真をダウンロードして、メモリ上の画像にする(PV / issue #59)
//
// 相手の写真は「見るだけ」で、端末に残さない(REQUIREMENTS §3.11):
//   - 専用の ephemeral な URLSession(URL キャッシュなし・Cookie なし)で取る。ディスクに何も残らない
//   - 受け取るバイト数に上限を設け、超えたら途中で打ち切る(相手が極端に大きいファイルを置いても
//     端末のメモリを使い切らない)
//   - JPEG だけを受け付け、画素数が大きすぎるものは捨てる。ImageIO で目的の大きさまで縮めて持つ
//     (原寸 2048px を全画面ぶんの 1600px に、サムネを 800px 以内にする。拡大はしない)
//   - App Group にも UserDefaults にも書かない。持つのは PartnerPhotoModel のメモリだけ
//
// 署名付き URL の失効は `.expired` にして、呼び出し側(LivePartnerPhotoService)が署名からやり直す。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 抽象

protocol PartnerPhotoImageLoading: AnyObject {
    /// url の写真を取って、`limits` の範囲で縮小した画像にする
    func loadImage(from url: URL, limits: PartnerPhotoLimits) async throws -> PartnerPhotoImage
}

// MARK: - live 実装

final class URLSessionPartnerPhotoLoader: PartnerPhotoImageLoading {
    private let session: URLSession

    /// session を省くと、ディスクにもキャッシュにも何も残さない専用のセッションを使う。
    /// (テストは URLProtocol スタブ入りのセッションを渡す)
    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeEphemeralSession()
    }

    static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func loadImage(from url: URL, limits: PartnerPhotoLimits) async throws -> PartnerPhotoImage {
        let data = try await download(url, maxBytes: limits.maxBytes)
        return try PartnerPhotoImageDecoder.decode(data, maxPixelSize: limits.maxPixelSize)
    }

    /// 上限を超えない範囲で本文を集める。ステータスは署名付き URL の扱いに合わせて分ける:
    /// 200 = 成功 / 400・401・403 = 署名の失効・無効(署名からやり直す)/ 404 = 無い・読めない
    private func download(_ url: URL, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw PartnerPhotoError.mapping(error)
        }
        guard let http = response as? HTTPURLResponse else { throw PartnerPhotoError.network }

        switch http.statusCode {
        case 200:
            break
        case 400, 401, 403:
            throw PartnerPhotoError.expired
        case 404:
            throw PartnerPhotoError.notFound
        default:
            throw PartnerPhotoError.server(status: http.statusCode)
        }

        // 長さが分かっていて上限を超えるなら、1バイトも読まずに断る
        if http.expectedContentLength > Int64(maxBytes) { throw PartnerPhotoError.tooLarge }

        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw PartnerPhotoError.tooLarge }
            }
        } catch let error as PartnerPhotoError {
            throw error
        } catch {
            throw PartnerPhotoError.mapping(error)
        }
        return data
    }
}

// MARK: - デコード(ImageIO)

enum PartnerPhotoImageDecoder {
    /// デコード前の画素数の上限(辺ごと)。アプリが上げる写真は長辺 2048px 以下なので、
    /// それを大きく超えるものは、圧縮された巨大画像(展開でメモリを食う)として捨てる
    static let maxSourceDimension = 4096

    /// JPEG を `maxPixelSize` 以内(長辺)に縮めて CGImage にする。EXIF の向きは画素に反映する
    static func decode(_ data: Data, maxPixelSize: Int) throws -> PartnerPhotoImage {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard
            let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
            CGImageSourceGetCount(source) == 1,
            let type = CGImageSourceGetType(source) as String?,
            type == UTType.jpeg.identifier
        else { throw PartnerPhotoError.invalidImage }

        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0,
            width <= maxSourceDimension, height <= maxSourceDimension
        else { throw PartnerPhotoError.invalidImage }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PartnerPhotoError.invalidImage
        }
        return PartnerPhotoImage(cgImage: image)
    }
}

// MARK: - 通信エラーの写し

extension PartnerPhotoError {
    /// 通信の失敗を PartnerPhotoError にする。Task の取り消しは CancellationError のまま返す
    /// (取り消された取得は結果が捨てられるので、失敗として数えない)
    static func mapping(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        return PartnerPhotoError.network
    }
}
