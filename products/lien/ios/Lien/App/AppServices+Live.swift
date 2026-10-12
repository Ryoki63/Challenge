// AppServices+Live.swift — Live 構成の組み立てと Live / Stub の切替(issue #55)
//
// supabase-swift(SupabaseService)を参照するのは Lien ターゲットのこのファイルだけに留める。
// Edge Functions のクライアントはすべて URLSession ベースで、JWT は SupabaseService.accessToken()
// (supabase-swift のセッション。期限切れは自動更新)から供給する。

import Foundation
import WidgetKit

extension AppServices {
    /// 標準構成: Config(Supabase URL / anon key)があれば Live、無ければ Stub
    static func make(bundle: Bundle = .main) -> AppServices {
        let pushAuthorizer = PushManager()
        let reloadWidgets: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
        guard let config = Config.load(bundle: bundle) else {
            return stub(
                store: AppGroupStore.standard(bundle: bundle),
                pushAuthorizer: pushAuthorizer,
                reloadWidgets: reloadWidgets
            )
        }
        return live(
            config: config,
            store: AppGroupStore.standard(bundle: bundle) ?? AppGroupStore.localFallback(),
            pushAuthorizer: pushAuthorizer,
            reloadWidgets: reloadWidgets
        )
    }

    static func live(
        config: Config,
        store: AppGroupStore,
        pushAuthorizer: PushAuthorizing,
        session: URLSession = .shared,
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
        let nudgeReact = LiveNudgeReactService(
            api: EdgeFunctionNudgeReactClient(
                baseURL: baseURL,
                tokenProvider: tokenProvider,
                session: session
            ),
            partnerCheckins: PostgRESTPartnerCheckinResolver(
                baseURL: baseURL,
                apiKey: config.supabaseAnonKey,
                tokenProvider: tokenProvider,
                currentUserID: { supabase.currentUserID },
                session: session
            )
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
            reloadWidgets: reloadWidgets
        )
    }
}
