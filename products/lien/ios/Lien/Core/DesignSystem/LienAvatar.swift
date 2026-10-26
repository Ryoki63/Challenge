// LienAvatar.swift — プロフィールのアイコン(タネの子のイラスト12種)
//
// 以前は絵文字24種から選んでいたが、アプリのマスコット「タネの子」を着替えさせた12種のイラストに置き換えた。
// 絵は assets/avatar/AvatarAssets.xcassets の `avatar_<id>`(円形のベクター。円の外は透明なので、マスクは要らない)。
// id と並び順は assets/avatar/avatars.json と同じで、LienAvatarTests が突き合わせる。
// 足すときは**末尾**に足す(id はサーバーに保存されるので、既存の id は変えない)。
//
// 保存先は、これまでどおり users.avatar_emoji 列(列名は変えない。DB の変更は要らない)。
// 列には絵文字ではなく、この enum の id(rawValue)を入れる。旧版が保存した絵文字や、空・知らない値は
// resolve(_:) で近いイラスト(無ければ既定)に読み替えて表示する。
// 名前(読み上げ用)は Strings.Avatar に置く(Strings.swift はウィジェットと共有するので、この enum を参照させない)。
// 選ぶ画面は AvatarPicker。

import SwiftUI

enum LienAvatar: String, CaseIterable, Identifiable, Sendable {
    case sprout
    case cactus
    case star
    case mushroom
    case clover
    case moon
    case tulip
    case sunflower
    case acorn
    case sakura
    case strawberry
    case drop

    var id: String { rawValue }

    /// 初めて選ぶときの絵(オンボーディングの最初の選択)。保存された値が読めないときの表示にも使う
    static let defaultAvatar: LienAvatar = .sprout

    /// アセットカタログの画像名(`avatar_sprout` など)
    var assetName: String { "avatar_\(rawValue)" }

    /// 読み上げ用の名前(「ふたば」など)
    var displayName: String {
        switch self {
        case .sprout: return Strings.Avatar.sprout
        case .cactus: return Strings.Avatar.cactus
        case .star: return Strings.Avatar.star
        case .mushroom: return Strings.Avatar.mushroom
        case .clover: return Strings.Avatar.clover
        case .moon: return Strings.Avatar.moon
        case .tulip: return Strings.Avatar.tulip
        case .sunflower: return Strings.Avatar.sunflower
        case .acorn: return Strings.Avatar.acorn
        case .sakura: return Strings.Avatar.sakura
        case .strawberry: return Strings.Avatar.strawberry
        case .drop: return Strings.Avatar.drop
        }
    }

    // MARK: - 保存された値 → アバター

    /// サーバーの users.avatar_emoji に入っている値から、対応するアバターを探す。
    /// - id(`sprout` など)ならそのアバター
    /// - 旧版の絵文字なら、近いイラスト(🌱→ふたば、🌷→チューリップ、🌻→ひまわり、🍀→クローバー、⭐️→ほし、
    ///   🌙→つき、🍓→いちご)
    /// - 対応する絵が無い(動物などの絵文字・空・知らない値)なら nil
    init?(stored: String) {
        if let avatar = LienAvatar(rawValue: stored) {
            self = avatar
            return
        }
        // 同じ絵文字でも、異体字セレクタ(U+FE0F)の有無で表記が分かれる(⭐ と ⭐️)ので、外してから引く
        let bare = String(String.UnicodeScalarView(stored.unicodeScalars.filter { $0.value != 0xFE0F }))
        guard let avatar = Self.legacyEmojiMap[bare] else { return nil }
        self = avatar
    }

    /// 保存された値を、表示するアバターに読み替える。対応する絵が無ければ既定のアバター(「ふたば」)
    static func resolve(_ stored: String) -> LienAvatar {
        LienAvatar(stored: stored) ?? defaultAvatar
    }

    /// 旧版の絵文字パレット(24種)のうち、近いイラストがあるもの(残りの 17種 は既定の「ふたば」になる)。
    /// キーは異体字セレクタなしの形(⭐ は U+2B50。旧パレットは ⭐️ = U+2B50 + U+FE0F で、init が U+FE0F を外してから引く)
    private static let legacyEmojiMap: [String: LienAvatar] = [
        "🌱": .sprout,
        "🌷": .tulip,
        "🌻": .sunflower,
        "🍀": .clover,
        "\u{2B50}": .star,
        "🌙": .moon,
        "🍓": .strawberry,
    ]
}

/// アバターを1枚だけ描く(設定の行など、大きさが決まっている場所用)。選ぶ画面の並びは AvatarPicker
struct AvatarImage: View {
    let avatar: LienAvatar
    /// 一辺の長さ(pt)。絵は円形なので縦横同じ
    var size: CGFloat

    var body: some View {
        Image(avatar.assetName)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(Strings.Avatar.label(avatar.displayName))
    }
}
