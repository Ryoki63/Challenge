// AppServices.swift — アプリ全体の依存の束(Live / Stub)と Stub 構成(issue #55)
//
// LienApp.swift に散らばっていた生成処理をここへ集約する。
//   - Config(Supabase URL / anon key)があれば Live(AppServices+Live.swift の make / live)
//   - 無ければ Stub(本ファイルの stub)。CI(Secrets.xcconfig が無い環境)や、まだ Supabase に
//     つなぎたくない開発ビルドでも、ネットワークを一切使わずに画面遷移まで動く。
//     ただし Release ビルドでは Stub に落とさず、起動時に明示エラーで止まる(Config.MissingPolicy — issue #28)
//
// View / ViewModel は個々のプロトコル(AuthServicing / InviteClient / ...)だけを知り、
// どちらの構成かを意識しない。差し替えはこのファイルの組み立てだけで完結する。

import Foundation

struct AppServices {
    /// true = 実 Supabase につながる構成
    let isLive: Bool
    let auth: AuthServicing
    let pushAuthorizer: PushAuthorizing
    let inviteClient: InviteClient
    let promiseClient: PromiseAPIClient
    let snapshotClient: SnapshotClient
    /// チェックイン(+当日取消・写真添付・キュー再送の能力。HomeViewModel が as? で能力検出する)
    let checkinService: CheckinPerforming
    /// つつく / リアクション。nil のときは checkinService の能力検出に任せる
    /// (Stub 構成の LocalEchoCheckinService がモック適合している)
    let nudgeService: NudgeSending?
    let reactionService: Reacting?
    /// 未送信キュー(スナップショット同期が「端末の方が新しい」ことを判定するのに使う)。Stub 構成は nil
    let pendingOps: PendingOpsQueue?
    let store: AppGroupStore?
    let pushTokenSync: PushTokenSync
    let reloadWidgets: () -> Void
    /// 相手の今日の写真の取得(PV #59)。Live 構成だけ。Stub 構成は nil で、ホームは写真を出さない
    /// (末尾に既定値つきで足したので、これを渡さない既存の組み立てはそのまま動く)
    var partnerPhotos: PartnerPhotoProviding?
    /// ペアの解消(= ブロック)・アカウントの削除(T23 #23)。nil のときは、それらの操作が失敗として扱われる
    /// (AccountClientError.unavailable)。Live / Stub のどちらの構成でも AppServices.make が入れる
    var accountClient: AccountAPIClient?
    /// 認証サーバーへ直接ログイン状態をたしかめる口(T23 #23)。「ログイン状態を確認できません」の確認を出す前と、
    /// アカウントの削除の応答だけ取りこぼしたときに使う。Live 構成だけ。nil のとき(Stub 構成)は、たしかめずに自分たちの
    /// サーバーの答えをそのまま信じる
    var sessionVerifier: SessionVerifying?
    /// 植物の名前を付ける・変える(plant-name — PB #57)。Live / Stub のどちらの構成でも AppServices が入れる。
    /// nil のとき(これを渡さない既存の組み立て・プレビュー)は、ホームは名前付けの導線を出さない
    var plantNaming: PlantNaming?
    /// 植物の体験の「もう見せたか」の記録(段階アップの演出・名前の知らせ・おかえり・ひとこと — PB #57。端末の UserDefaults)。
    /// nil のとき(これを渡さない既存の組み立て・テスト)は、ホームがメモリ内の記録で動く(保存しない)。
    /// アカウントの削除・サインアウトの後始末で消す(AppModel.endSession)
    var plantMemory: PlantMemoryStoring?
    /// 端末のローカル通知(リマインド・ストリーク危機)の予約と設定(T16 #16)。nil のとき(これを渡さない既存の組み立て・テスト)は、
    /// ローカル通知を扱わない。Live / Stub のどちらの構成でも AppServices が入れる。アカウントの削除・サインアウトの後始末で
    /// 設定と予約を消す(AppModel.endSession)
    var reminders: ReminderManaging?
}

extension AppServices {
    /// Config 未設定(CI・Secrets なし)用の構成。サーバーを一切呼ばない。
    /// 同期(StubSnapshotClient)は端末の snapshot をそのまま返すので、端末内の状態を巻き戻さない
    static func stub(
        store: AppGroupStore?,
        pushAuthorizer: PushAuthorizing,
        reloadWidgets: @escaping () -> Void = {}
    ) -> AppServices {
        let auth = StubAuthService()
        return AppServices(
            isLive: false,
            auth: auth,
            pushAuthorizer: pushAuthorizer,
            inviteClient: StubInviteClient(store: store),
            promiseClient: StubPromiseAPIClient(),
            snapshotClient: StubSnapshotClient(store: store),
            checkinService: LocalEchoCheckinService(),
            nudgeService: nil,
            reactionService: nil,
            pendingOps: nil,
            store: store,
            pushTokenSync: PushTokenSync(
                registrar: auth,
                currentUserID: { auth.currentUserID },
                ledger: InMemoryPushRegistrationLedger()
            ),
            reloadWidgets: reloadWidgets,
            accountClient: StubAccountClient(store: store),
            plantNaming: StubPlantNaming(store: store),
            plantMemory: UserDefaultsPlantMemoryStore(),
            // サーバーの約束を持たない構成: リマインドの時刻は、約束を保存したとき(promiseSaved)に端末が覚える
            reminders: makeReminders(store: store, reminderLoader: nil)
        )
    }

    /// ローカル通知の予約(Live / Stub 共通)。本物の通知センターを使うが、組み立てだけでは OS に触れない。
    /// reminderLoader は、リマインドの時刻をまだ知らないときに、サーバーの約束から読む口(Live だけ)
    static func makeReminders(
        store: AppGroupStore?,
        reminderLoader: ReminderScheduler.ReminderLoader?
    ) -> ReminderManaging? {
        guard let store else { return nil }
        return ReminderScheduler(
            center: UserNotificationCenterScheduler(),
            preferences: AppGroupNotificationPreferencesStore(store: store),
            snapshotSource: { store.loadSnapshot() },
            reminderLoader: reminderLoader
        )
    }
}

extension AppGroupStore {
    /// App Group が解決できないとき(エンタイトルメント無しの署名なしビルドなど)の代替保存先。
    /// ウィジェット・NSE とは共有されないが、アプリ本体は動き続ける
    static func localFallback(fileManager: FileManager = .default) -> AppGroupStore {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return AppGroupStore(containerURL: base.appendingPathComponent("LienLocal", isDirectory: true))
    }
}
