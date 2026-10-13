// PartnerPhotoService.swift — 相手の今日の写真を取ってくる(PV / issue #59 / REQUIREMENTS §3.11)
//
// 3つの部品をつなぐ:
//   1. PartnerCheckinResolving  : 相手の当日の checkins 行(PostgREST。photo_path まで)
//   2. PhotoURLSigning          : photos バケットの署名付き URL(Storage。利用者の JWT でクライアントが作る)
//   3. PartnerPhotoImageLoading : 署名付き URL からの取得と縮小(メモリ上だけ)
//
// 流れ(ホームの PartnerPhotoModel が呼ぶ):
//   loadThumbnail : 行を読む → photo_path を検証 → サムネ(photo_thumb.jpg)の署名付き URL → 取得
//                   サムネが無い・読めないときは原寸から代わりを作る
//   loadOriginal  : タップしたときだけ。原寸(photo.jpg)の署名付き URL → 取得(全画面ぶんの大きさ)
//
// 署名付き URL は短寿命(3600 秒)で、使う直前に作る。取得が「失効」で弾かれたら(端末の時計のずれや
// 取得の遅れ)署名からやり直して1回だけ再試行する。どこにも保存しない。
//
// ペア解消後は RLS(checkins_select_pair / photos_select_pair_member)が行も署名も弾くので、
// 何も取れない(DESIGN §5.7 の3番)。ここでは特別扱いをしない。

import Foundation

// MARK: - 抽象

/// サムネの取得結果(写真の指し先つき)
struct PartnerPhotoThumbnail: Equatable, Sendable {
    let reference: PartnerPhotoReference
    let image: PartnerPhotoImage
}

protocol PartnerPhotoProviding: AnyObject {
    /// 相手の `dateLocal` のチェックインに添えられた写真のサムネ。
    /// 相手の行が無い・photo_path が無い・規約に合わないパス(別のペア・別の日のものを含む)のときは nil。
    /// 通信や認証の失敗は throw する(呼び出し側は静かに「出さない」にする)
    func loadThumbnail(pairID: String, dateLocal: String) async throws -> PartnerPhotoThumbnail?

    /// 原寸(全画面ぶんの大きさに縮めたもの)。サムネをタップしたときだけ呼ぶ
    func loadOriginal(of reference: PartnerPhotoReference) async throws -> PartnerPhotoImage
}

// MARK: - 本実装

final class LivePartnerPhotoService: PartnerPhotoProviding {
    private let checkins: PartnerCheckinResolving
    private let signer: PhotoURLSigning
    private let loader: PartnerPhotoImageLoading

    init(
        checkins: PartnerCheckinResolving,
        signer: PhotoURLSigning,
        loader: PartnerPhotoImageLoading
    ) {
        self.checkins = checkins
        self.signer = signer
        self.loader = loader
    }

    func loadThumbnail(pairID: String, dateLocal: String) async throws -> PartnerPhotoThumbnail? {
        let row: PartnerCheckin?
        do {
            row = try await checkins.partnerCheckin(dateLocal: dateLocal)
        } catch {
            throw PartnerPhotoError.normalizingConnectivity(error)
        }
        guard
            let row,
            let rawPath = row.photoPath,
            let path = PartnerPhotoPath(rawPath),
            // 今のペアの、今日の写真だけを出す(別のペア・別の日のパスが混ざっても出さない)
            path.pairID == pairID.lowercased(),
            path.dateLocal == dateLocal
        else { return nil }

        let reference = PartnerPhotoReference(
            pairID: path.pairID,
            dateLocal: path.dateLocal,
            photoPath: path.original
        )
        let image: PartnerPhotoImage
        do {
            image = try await fetch(objectPath: path.thumbnail, limits: .thumbnail)
        } catch let error as PartnerPhotoError where error.allowsOriginalFallback {
            // サムネが無い・壊れている・大きすぎる: 原寸を取って、サムネの大きさまで縮めて代わりにする
            image = try await fetch(objectPath: path.original, limits: .thumbnailFromOriginal)
        }
        return PartnerPhotoThumbnail(reference: reference, image: image)
    }

    func loadOriginal(of reference: PartnerPhotoReference) async throws -> PartnerPhotoImage {
        guard let path = PartnerPhotoPath(reference.photoPath) else { throw PartnerPhotoError.invalidPath }
        return try await fetch(objectPath: path.original, limits: .original)
    }

    // MARK: private

    /// 署名付き URL を作って取る。署名付き URL の失効で弾かれたら、署名からやり直して1回だけ再試行する
    private func fetch(objectPath: String, limits: PartnerPhotoLimits) async throws -> PartnerPhotoImage {
        let signed = try await sign(objectPath)
        do {
            return try await loader.loadImage(from: signed.url, limits: limits)
        } catch PartnerPhotoError.expired {
            let renewed = try await sign(objectPath)
            return try await loader.loadImage(from: renewed.url, limits: limits)
        }
    }

    /// 署名付き URL を作る。トークンの更新が通信の失敗で落ちたとき(URLError)も、`.network` にそろえる
    private func sign(_ objectPath: String) async throws -> SignedPhotoURL {
        do {
            return try await signer.signedURL(forPath: objectPath)
        } catch {
            throw PartnerPhotoError.normalizingConnectivity(error)
        }
    }
}

extension PartnerPhotoError {
    /// 行の読み取りや署名(トークンの取得を含む)で起きた失敗のうち、**通信が切れていただけ**のものを `.network` にそろえる
    /// (それ以外は、そのまま)。
    ///   - PostgRESTPartnerCheckinResolver は、応答が返らない失敗を NudgeReactClientError.network にして投げる
    ///   - トークンの更新(supabase-swift)は、オフラインだと URLError をそのまま投げる
    /// そろえないと、PartnerPhotoModel が「読めなくなった」と取り違えて、出している今日の写真まで捨て、
    /// 読めなかった日として覚えてしまう(取り直しの間隔の間、電波が戻っても出ない)。
    /// 取り消し(URLError.cancelled)は失敗ではないので CancellationError にする(取り消された取得の結果は捨てられる)
    static func normalizingConnectivity(_ error: Error) -> Error {
        if let client = error as? NudgeReactClientError, client == .network {
            return PartnerPhotoError.network
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : PartnerPhotoError.network
        }
        return error
    }

    /// サムネが取れなかったとき、原寸で代わりを作ってよいか。
    /// サムネそのものが無い・壊れている・大きすぎる(= 原寸なら読めるかもしれない)ときだけ。
    /// 通信が切れている・認証で弾かれた・失効が続くときは、原寸でも同じ結果なので試さない
    var allowsOriginalFallback: Bool {
        switch self {
        case .notFound, .server, .tooLarge, .invalidImage, .invalidResponse:
            return true
        case .network, .unauthorized, .expired, .invalidPath:
            return false
        }
    }
}
