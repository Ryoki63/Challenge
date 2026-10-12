// PartnerPhoto.swift — 相手の今日の写真(PV / issue #59 / REQUIREMENTS §3.11)の値型
//
// ホームに出す「相手の今日の写真」を支える、通信にも画面にも依存しない部品:
//   - PartnerPhotoPath      : checkins.photo_path の検証と、サムネのパスの導出
//   - PartnerPhotoReference : 表示している写真の指し先(T23 の通報が、ペア・日付・パスを控えるのに使う)
//   - PartnerPhotoImage     : ダウンロードして縮小した画像(メモリ上だけ。ディスクにも App Group にも書かない)
//   - PartnerPhotoLimits    : ダウンロードの上限(バイト数)と、デコード後の大きさ
//   - PartnerPhotoError     : 署名・ダウンロードの失敗理由
//   - PartnerPhotoAction    : 写真の長押しメニューの取り付け口(T23 が通報・ブロックを入れる)
//
// 写真のパス規約(DESIGN §5.2・§5.6 / migration 0004):
//   原寸   pairs/<pair_id>/<date_local>/<user_id>/photo.jpg        (長辺 2048px)
//   サムネ pairs/<pair_id>/<date_local>/<user_id>/photo_thumb.jpg  (200KB 以下。同じ区画)
//   旧形式 pairs/<pair_id>/<date_local>/photo.jpg(#52 より前の既存分。読めるまま)
//
// Foundation と CoreGraphics だけに依存する(SwiftUI を import しない)。

import CoreGraphics
import Foundation

// MARK: - パス

struct PartnerPhotoPath: Equatable, Sendable {
    static let originalFileName = "photo.jpg"
    static let thumbnailFileName = "photo_thumb.jpg"

    /// 原寸のパス(checkins.photo_path そのまま)
    let original: String
    /// サムネのパス(原寸と同じ区画の photo_thumb.jpg)
    let thumbnail: String
    /// ペア ID(小文字)
    let pairID: String
    /// 写真を添えた日(date_local 'YYYY-MM-DD')
    let dateLocal: String

    /// 規約に合うパスだけを受け付ける。ここを通ったパスだけが Storage の URL になる
    /// (相手の行から読んだ文字列をそのまま URL に使わない — `..` や空の区画を弾く)
    init?(_ rawPath: String) {
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // pairs / <pair_id> / <date_local> / [<user_id> /] photo.jpg
        guard
            segments.count == 4 || segments.count == 5,
            segments[0] == "pairs",
            Self.isUUID(segments[1]),
            Self.isDateLocal(segments[2]),
            segments[segments.count - 1] == Self.originalFileName
        else { return nil }
        if segments.count == 5, !Self.isUUID(segments[3]) { return nil }

        original = rawPath
        thumbnail = (segments.dropLast() + [Self.thumbnailFileName]).joined(separator: "/")
        pairID = segments[1].lowercased()
        dateLocal = segments[2]
    }

    /// Storage に渡してよい文字だけで組まれたオブジェクトパスか(署名 URL を作る直前の最後の関門)。
    /// 英数字・`-`・`_`・`.` と区切りの `/` だけ。空の区画と `.` / `..` の区画は不可
    static func isSafeObjectPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 300 else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty
                && segment != "."
                && segment != ".."
                && segment.unicodeScalars.allSatisfy(Self.isSafeScalar)
        }
    }

    private static func isSafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true // 0-9 A-Z a-z
        case 0x2D, 0x5F, 0x2E: return true // - _ .
        default: return false
        }
    }

    private static func isUUID(_ text: String) -> Bool {
        text.count == 36 && UUID(uuidString: text) != nil
    }

    /// "YYYY-MM-DD"(形だけ。実在する日かどうかは見ない — 比較は呼び出し側が今日の文字列と行う)
    private static func isDateLocal(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { part in part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }
    }
}

// MARK: - 指し先

/// 表示している写真の指し先。T23 の通報(mailto にペア ID・日付をプリフィルし、運営が写真を特定する)が使う
struct PartnerPhotoReference: Equatable, Sendable {
    let pairID: String
    let dateLocal: String
    /// 原寸の写真のパス(checkins.photo_path)
    let photoPath: String
}

// MARK: - 画像

/// ダウンロードして縮小した画像(メモリ上だけ)。
/// CGImage は不変なのでスレッド間で受け渡してよい(Sendable は手で保証する)
struct PartnerPhotoImage: @unchecked Sendable, Equatable {
    let cgImage: CGImage

    var pixelWidth: Int { cgImage.width }
    var pixelHeight: Int { cgImage.height }

    /// 横 ÷ 縦(縦が 0 の壊れた画像は 1)
    var aspectRatio: CGFloat {
        cgImage.height == 0 ? 1 : CGFloat(cgImage.width) / CGFloat(cgImage.height)
    }

    /// 同じ画像のオブジェクトか(ピクセルの比較はしない — 取得し直した別オブジェクトは別物)
    static func == (lhs: PartnerPhotoImage, rhs: PartnerPhotoImage) -> Bool {
        lhs.cgImage === rhs.cgImage
    }
}

/// ダウンロードの上限とデコード後の大きさ
struct PartnerPhotoLimits: Equatable, Sendable {
    /// 受け取るバイト数の上限(超えたら途中で打ち切る。相手が極端に大きいファイルを置いても、端末のメモリを使い切らない)
    let maxBytes: Int
    /// デコード後の長辺(px)。これより大きい画像は縮小して持つ(拡大はしない)
    let maxPixelSize: Int

    /// サムネ(photo_thumb.jpg は 200KB 以下 — PhotoProcessor)。ホームのカードは幅 260pt 以下
    static let thumbnail = PartnerPhotoLimits(maxBytes: 512 * 1024, maxPixelSize: 800)
    /// 原寸(photo.jpg は長辺 2048px・JPEG 品質 0.85 — PhotoProcessor)。全画面で見るぶんだけ持つ
    static let original = PartnerPhotoLimits(maxBytes: 6 * 1024 * 1024, maxPixelSize: 1600)
    /// サムネが無いときの代わり: 原寸を取って、サムネの大きさまで縮める
    static let thumbnailFromOriginal = PartnerPhotoLimits(maxBytes: 6 * 1024 * 1024, maxPixelSize: 800)
}

// MARK: - 失敗理由

/// 署名・ダウンロードの失敗理由。ユーザーには見せない(失敗したら静かに写真を出さない — 罰なし・§3.5)ので、
/// 区別は「再取得すべきか」と「原寸で代用してよいか」を決めるためだけにある
enum PartnerPhotoError: Error, Equatable {
    /// 応答が返らない(オフライン・タイムアウト)
    case network
    /// 署名の要求が認証で弾かれた(401 / 403)
    case unauthorized
    /// 署名付き URL が失効・無効(ダウンロードが 400 / 401 / 403)。署名からやり直す
    case expired
    /// オブジェクトが無い、または RLS で読めない(404)
    case notFound
    /// 上記以外のサーバーエラー
    case server(status: Int)
    /// 上限を超えるサイズ(`PartnerPhotoLimits.maxBytes`)
    case tooLarge
    /// JPEG として読めない・大きすぎる画素数
    case invalidImage
    /// 署名の応答が読めない
    case invalidResponse
    /// 規約に合わないパス
    case invalidPath
}

// MARK: - 長押しメニューの取り付け口(T23)

/// 写真の長押しメニューの1項目。T23(審査対応一式)が「通報」「ブロック(ペア解消)」を入れる。
/// PV(#59)は写真の View に長押しメニューを付けられる形にしておくだけで、項目の中身(文言・動作)は持たない。
/// 項目が1つでもあれば長押しのメニューが付き、VoiceOver にも同じ操作がアクションとして出る
struct PartnerPhotoAction: Identifiable {
    let id: String
    /// メニューの文言(Strings に置いたものを渡す)
    let title: String
    /// SF Symbols の名前
    let systemImage: String
    /// 破壊的な操作(通報・ブロックなど)は赤で出す
    var isDestructive = false
    /// 長押ししたときの写真の指し先を受け取る
    let perform: (PartnerPhotoReference) -> Void
}
