// ModerationViewModel.swift — ホームでの通報とブロックの状態(T23 #23 / App Store ガイドライン 1.2)
//
// ホームで相手のコンテンツ(写真・ニックネーム・約束の文・植物の名前)を長押しすると、次の2つが選べる:
//   - 通報: 対象の ID を入れた運営宛のメールの下書きを開く(ReportComposer)。開く前に1回確認する
//   - ブロック(= ペア解消): 確認の2段階(DestructiveFlow)を経てペアを解消する。解消すると相手との共有はすべて止まる
//
// このクラスは「どの確認を出すか」の状態を持つだけで、メールを開く操作(openURL)は View が行う。
// ペアの解消そのものは AccountOperating(AppModel)。設定画面の「ペアを解消する」と同じ操作・同じ確認の流れ

import Foundation
import Observation

@MainActor
@Observable
final class ModerationViewModel {
    /// 確認(「この内容を通報しますか?」)を出している通報の対象。nil なら確認は出ていない
    private(set) var pendingReport: ReportTarget?
    /// メールを開けなかった(メールアプリが無い・宛先が不正)ときのアラートを出すか
    var showsMailFailure = false

    /// ブロック(= ペアの解消)。ホームから長押しで始める。確認は2段階
    let block: DestructiveFlow

    private let store: AppGroupStore?
    private let now: () -> Date
    private let email: String

    init(
        store: AppGroupStore?,
        account: AccountOperating,
        now: @escaping () -> Date = Date.init,
        email: String = SupportLinks.contactEmail
    ) {
        self.store = store
        self.now = now
        self.email = email
        self.block = DestructiveFlow(
            errorText: Strings.Dissolve.errorMessage,
            operation: { [account] in try await account.dissolvePair() }
        )
    }

    // MARK: 通報

    /// 長押しメニューの「通報」。確認を出す
    func requestReport(_ target: ReportTarget) {
        pendingReport = target
    }

    /// 通報の確認の「やめる」
    func cancelReport() {
        pendingReport = nil
    }

    /// 通報の確認の「メールを開く」。開く mailto を返す(組み立てられなければ、失敗のアラートを出して nil)
    func confirmReport() -> URL? {
        guard let target = pendingReport else { return nil }
        pendingReport = nil
        guard let url = ReportComposer.reportURL(target: target, context: context, email: email) else {
            showsMailFailure = true
            return nil
        }
        return url
    }

    /// メールを開こうとして、OS に開けないと言われた
    func mailOpenFailed() {
        showsMailFailure = true
    }

    private var context: ReportContext {
        ReportContext.current(pairId: store?.loadSnapshot()?.pairId, now: now())
    }

    // MARK: ブロック

    /// 長押しメニューの「ブロック(ペアを解消)」。説明の画面を出す(確認の1段階目)
    func requestBlock() {
        block.begin()
    }

    // MARK: 後始末

    /// 開いている確認をすべて閉じる(サインアウト・アカウント削除のあと。次のアカウントでホームに戻ったとき、
    /// 前のアカウントの確認が出てこないように)。実行中のブロックは止めない
    func reset() {
        pendingReport = nil
        showsMailFailure = false
        block.cancel()
    }
}

// MARK: - 相手の写真の長押しメニューの項目

extension ModerationViewModel {
    /// 相手の今日の写真(PartnerPhotoView)の長押しメニュー: 通報(対象は長押しした写真の指し先)とブロック(ペア解消)。
    /// PartnerPhotoModel(actions:) に渡す。VoiceOver にも同じ操作がアクションとして出る
    var photoActions: [PartnerPhotoAction] {
        [
            PartnerPhotoAction(
                id: "report",
                title: Strings.Report.menuReportPhoto,
                systemImage: "flag",
                perform: { [weak self] reference in self?.requestReport(.photo(reference)) }
            ),
            PartnerPhotoAction(
                id: "block",
                title: Strings.Report.menuBlock,
                systemImage: "hand.raised",
                isDestructive: true,
                perform: { [weak self] _ in self?.requestBlock() }
            ),
        ]
    }
}
