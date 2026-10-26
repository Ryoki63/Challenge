// ProfileEditViewModel.swift — プロフィール(ニックネームとアイコン)の編集の状態管理(REQUIREMENTS §3.15 / T23 #23)
//
// 設定のプロフィール欄から開く編集画面の下書きと保存。
//   - 検証はオンボーディングのニックネームと同じ(NicknameRules: 前後の空白を除いて、空は不可・8字まで。
//     DB の check と同じ Unicode コードポイント数)。アイコンはオンボと同じタネの子のイラスト12種(LienAvatar)から選ぶ
//   - 保存は users の nickname / avatar_emoji だけを更新する(AuthServicing.updateNicknameAndAvatar)。
//     avatar_emoji 列には、アイコンの id(LienAvatar.rawValue。例: "sprout")を入れる。
//     timezone は書かない(日付の判定に効くので、名前を直すたびに端末の値で上書きしない)
//   - 失敗しても何も失われない(下書きはそのまま。責めない一言を出して、もう一度できる)
//   - 相手への知らせは送らない。相手の画面・ウィジェットには、次の同期(前面復帰・push 受信)で新しい名前が反映される
//
// 画面ごとに 1 つ作る(SettingsViewModel.makeProfileEditor)。保存できたら onSaved で設定画面の表示を更新する。

import Foundation
import Observation

@MainActor
@Observable
final class ProfileEditViewModel {
    // MARK: - 入力状態(View からバインド)

    var nickname: String
    /// 選んだアイコン(タネの子のイラスト12種)。保存するときは id(rawValue)を avatar_emoji 列に入れる
    var avatar: LienAvatar

    // MARK: - 画面状態

    private(set) var isSaving = false
    /// 保存に失敗したときの一言(責めない文言)。次の保存の試みで消える
    private(set) var errorMessage: String?

    // MARK: - 依存

    /// 編集を始めたときの(あるいは直近に保存できた)プロフィール。変更の有無の基準
    private(set) var saved: UserProfile
    private let auth: AuthServicing
    private let onSaved: (UserProfile) -> Void

    /// - profile: いまサーバーに保存されているプロフィール。アイコンは LienAvatar.resolve で読み替える
    ///   (旧版の絵文字は近いイラスト。未設定(空)や対応する絵の無い値は、既定の「ふたば」を初期値にする)
    /// - onSaved: 保存できたときに呼ぶ(設定画面の表示を更新する)
    init(
        profile: UserProfile,
        auth: AuthServicing,
        onSaved: @escaping (UserProfile) -> Void
    ) {
        self.saved = profile
        self.auth = auth
        self.onSaved = onSaved
        self.nickname = profile.nickname
        self.avatar = LienAvatar.resolve(profile.avatarEmoji)
    }

    // MARK: - 検証

    /// 前後の空白・改行を除いた保存用ニックネーム
    var trimmedNickname: String {
        NicknameRules.trimmed(nickname)
    }

    /// nil なら保存できる中身。オンボーディングと同じ規則
    var nicknameError: NicknameError? {
        NicknameRules.validate(nickname)
    }

    /// 保存済みの値から変わっているか(変わっていなければ保存ボタンは押せない)。
    /// アイコンは、保存済みの値が表す絵(LienAvatar(stored:))と比べる。旧版の絵文字(🌱 など)が保存されていて
    /// 対応するイラストを選んだままなら変更なし。未設定(空)や対応する絵の無い値(🐶 など)だったときは、
    /// 初期値の「ふたば」を選んだままでも変更あり(そのまま保存して、アイコンの id を残せる)
    var hasChanges: Bool {
        trimmedNickname != saved.nickname || avatar != LienAvatar(stored: saved.avatarEmoji)
    }

    var canSave: Bool {
        nicknameError == nil && hasChanges && !isSaving
    }

    // MARK: - 保存

    /// 保存する。成功したら true(画面は閉じてよい)。検証に通らない・変更が無い・保存中なら何もしない(false)。
    /// 失敗(通信など)は errorMessage を立てて false。下書きはそのまま残り、もう一度できる
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let newNickname = trimmedNickname
        let newAvatar = avatar.rawValue
        do {
            try await auth.updateNicknameAndAvatar(nickname: newNickname, avatarEmoji: newAvatar)
        } catch {
            errorMessage = Strings.Settings.profileSaveError
            return false
        }
        // 保存した値(id)を基準にし直す。以後は、選んだ絵が同じなら変更なし
        let profile = UserProfile(nickname: newNickname, avatarEmoji: newAvatar)
        saved = profile
        nickname = newNickname // 前後の空白を除いた値に揃える(保存した値と画面の値を一致させる)
        onSaved(profile)
        return true
    }
}
