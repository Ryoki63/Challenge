// PartnerPhotoModel+State.swift — ホームの相手の写真の「状態」と「覚えていること」の型(PV / issue #59)
//
// PartnerPhotoModel.swift を 300 行の目安(DESIGN §9-4)に収めるため、型だけをここに分けた(振る舞いは持たない)。

import Foundation

extension PartnerPhotoModel {
    /// ホームのカードの状態
    enum State: Equatable {
        /// 何も出さない
        case hidden
        /// 取りに行っている(枠だけ出す)
        case loading
        /// サムネを出す
        case ready(PartnerPhotoThumbnail)
    }

    /// タップで開く全画面の状態
    enum Viewer: Equatable {
        case closed
        /// 原寸が届くまでは、サムネを大きく出して、取れたら差し替える。取れなかったとき(failed)も、サムネのまま出す
        case open(thumbnail: PartnerPhotoImage, original: Original)

        /// 原寸の写真の状態
        enum Original: Equatable {
            /// 取りに行っている(スピナーを出す)
            case loading
            /// 取れた(サムネと差し替える)
            case loaded(PartnerPhotoImage)
            /// 取れなかった(スピナーを止める。文言は出さず、サムネのまま — 罰なし・§3.5。閉じて開き直せば取り直す)
            case failed
        }
    }
}

// MARK: - 覚えていること(メモリだけ。モデルの内部で使う)

extension PartnerPhotoModel {
    /// 写真の持ち主の区画(ペア, 日付)。ペア ID は小文字
    struct Key: Equatable {
        let pairID: String
        let dateLocal: String
    }

    /// 取れた写真(サムネ1枚)と、取れた時刻
    struct CacheEntry {
        let key: Key
        let thumbnail: PartnerPhotoThumbnail
        let loadedAt: Date
    }

    /// 読めなかった(ペア, 日付)と、その時刻。`unreadableRetryInterval` の間は取り直さない
    struct UnreadableEntry {
        let key: Key
        let at: Date
    }

    /// 取得の依頼。generation は、古い取得の結果が新しい状態を上書きしないための世代
    struct FetchRequest {
        let key: Key
        let generation: Int
    }
}

// MARK: - 全画面の表示用

extension PartnerPhotoModel.Viewer {
    /// 全画面に出す画像: 原寸が届いたら原寸、それまで(と、取れなかったとき)はサムネ。閉じているときは nil
    var displayedImage: PartnerPhotoImage? {
        guard case .open(let thumbnail, let original) = self else { return nil }
        if case .loaded(let image) = original { return image }
        return thumbnail
    }

    /// 原寸を取りに行っている間か(スピナーを出す。取れなかったあと・閉じているときは出さない)
    var isLoadingOriginal: Bool {
        guard case .open(_, let original) = self else { return false }
        return original == .loading
    }
}
