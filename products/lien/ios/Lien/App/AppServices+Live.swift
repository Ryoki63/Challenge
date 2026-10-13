// AppServices+Live.swift — Live 構成の組み立てと Live / Stub の切替(issue #55)
//
// supabase-swift(SupabaseService)を参照するのは Lien ターゲットのこのファイルだけに留める。
// Edge Functions のクライアントはすべて URLSession ベースで、JWT は SupabaseService.accessToken()
// (supabase-swift のセッション。期限切れは自動更新)から供給する。

import Foundation
import WidgetKit

extension AppServices {
    /// 標準構成: Config(Supabase URL / anon key)があれば Live。
    /// 無いときは policy に従う — Debug は Stub、**Release は起動時に明示エラーで止まる**(issue #28。
    /// 接続情報の無い Stub のビルドを TestFlight / App Store に出さない)
    static func make(
        bundle: Bundle = .main,
        whenConfigMissing policy: Config.MissingPolicy = .buildDefault
    ) -> AppServices {
        do {
            return try makeChecked(bundle: bundle, whenConfigMissing: policy)
        } catch {
            fatalError("[Lien] \(error)")
        }
    }

    /// `make` の本体。Config が無く policy が `.fatal` のときは `Config.MissingError` を投げる
    /// (fatalError にするのは make だけ。テストはこちらを呼んで致命の経路を確かめる)
    static func makeChecked(
        bundle: Bundle = .main,
        whenConfigMissing policy: Config.MissingPolicy
    ) throws -> AppServices {
        let loadedConfig = Config.load(bundle: bundle)
        if loadedConfig == nil, policy == .fatal { throw Config.MissingError() }

        let pushAuthorizer = PushManager()
        let reloadWidgets: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
        // App Group が解決できない署名なしビルドでも、アプリ本体は動き続ける(ウィジェット・NSE とは共有されない)
        let store = AppGroupStore.standard(bundle: bundle) ?? AppGroupStore.localFallback()
        guard let config = loadedConfig else {
            return stub(store: store, pushAuthorizer: pushAuthorizer, reloadWidgets: reloadWidgets)
        }
        return live(config: config, store: store, pushAuthorizer: pushAuthorizer, reloadWidgets: reloadWidgets)
    }

    static func live(
        config: Config,
        store: AppGroupStore,
        pushAuthorizer: PushAuthorizing,
        session: URLSession = .shared,
        photoSession: URLSession? = nil,
        reloadWidgets: @escaping () -> Void
    ) -> AppServices {
        let supabase = SupabaseService(config: config)
        let tokenProvider: () async throws -> String = { try await supabase.accessToken() }
        let baseURL = config.supabaseURL

        let queue = PendingOpsQueue(store: store)
        let checkinService = CheckinService(
            api: EdgeFunctionCheckinClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                session: session
            ),
            queue: queue
        )
        // 相手の当日の checkins 行(PostgREST)。リアクションの対象 id と、相手の今日の写真の photo_path の両方に使う
        let partnerCheckins = PostgRESTPartnerCheckinResolver(
            baseURL: baseURL,
            apiKey: config.supabaseAnonKey,
            tokenProvider: tokenProvider,
            currentUserID: { supabase.currentUserID },
            session: session
        )
        let nudgeReact = LiveNudgeReactService(
            api: EdgeFunctionNudgeReactClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                session: session
            ),
            partnerCheckins: partnerCheckins
        )
        // 相手の今日の写真(PV #59): 署名付き URL はクライアントが RLS の範囲で作る(新しい関数は増やさない)。
        // 画像は専用の ephemeral セッションで取る(photoSession を省くと、ディスクにもキャッシュにも残さない)
        let partnerPhotos = LivePartnerPhotoService(
            checkins: partnerCheckins,
            signer: StoragePhotoURLSigner(
                baseURL: baseURL,
                apiKey: config.supabaseAnonKey,
                tokenProvider: tokenProvider,
                session: session
            ),
            loader: URLSessionPartnerPhotoLoader(session: photoSession)
        )

        return AppServices(
            isLive: true,
            auth: supabase,
            pushAuthorizer: pushAuthorizer,
            inviteClient: EdgeFunctionInviteClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                session: session
            ),
            promiseClient: EdgeFunctionPromiseClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                session: session
            ),
            snapshotClient: EdgeFunctionSnapshotClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                session: session
            ),
            checkinService: checkinService,
            nudgeService: nudgeReact,
            reactionService: nudgeReact,
            pendingOps: queue,
            store: store,
            pushTokenSync: PushTokenSync(
                registrar: supabase,
                currentUserID: { supabase.currentUserID },
                ledger: UserDefaultsPushRegistrationLedger()
            ),
            reloadWidgets: reloadWidgets,
            partnerPhotos: partnerPhotos,
            accountClient: EdgeFunctionAccountClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                session: session
            ),
            sessionVerifier: GoTrueSessionVerifier(
                baseURL: baseURL,
                apiKey: config.supabaseAnonKey,
                tokenProvider: tokenProvider,
                session: session
            ),
            plantNaming: EdgeFunctionPlantNaming(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                session: session
            ),
            plantMemory: UserDefaultsPlantMemoryStore(),
            // ローカル通知(T16 #16)。リマインドの時刻をまだ知らないとき(この版へ更新した直後・再インストール直後)は、
            // サーバーの約束の remind_at から一度読む。読めなければ nil(予約せず、あとで読み直す)
            reminders: makeReminders(store: store, reminderLoader: {
                do {
                    let promise = try await supabase.fetchMyPromise()
                    return ReminderPreference(remindAt: promise?.remindAt)
                } catch {
                    return nil
                }
            })
        )
    }
}
