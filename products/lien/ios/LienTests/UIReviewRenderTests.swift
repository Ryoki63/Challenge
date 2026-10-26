// UIReviewRenderTests.swift — UI/UX レビュー用に主要画面を PNG に描く(一時ハーネス)
//
// 目的: 画面を目で見てレビューするための画像を、実装そのものから作る。
// 出力: ios/build/ui-review/<name>.png(証拠。コミットしない)
//
// ImageRenderer は同じ run loop で続けて描くと前の結果や空の画像を返すことがあるので、
// 1メソッド1枚にし、描く前に run loop を1回まわす(StoreScreenshotRenderTests と同じ作法)。
//
// ImageRenderer は ScrollView・Form・List・NavigationStack の中身を描けず、黄色の「禁止」マークの代わりになる
// (settings / promise-setup / pairing の画像がそう。既知の制限で、アプリの不具合ではない)。
// Form の中の見た目を見たい画面(プロフィール編集・設定のプロフィール行)は、NotificationSettingsRenderTests と同じく
// UIKit のウィンドウに載せて描く(writeFromWindow)。ウィンドウが取れない・空白だったときは、画像を保存せず(ログに残し)、
// テストは落とさない(シミュレータの状態に左右されるため)。
// UIKit を使うので、macOS の下見(macos-check)では走らせない(check.sh の EXCLUDE_TESTS)。

import SwiftUI
import UIKit
import XCTest
@testable import Lien

@MainActor
final class UIReviewRenderTests: XCTestCase {
    private let width: CGFloat = 393
    private let height: CGFloat = 852

    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/ui-review", isDirectory: true)
    }

    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private func write(_ view: some View, name: String, height overrideHeight: CGFloat? = nil) async throws {
        await settle()
        let wrapped = view
            .frame(width: width, height: overrideHeight ?? height, alignment: .top)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, .light)
            .tint(LienColors.accent)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            throw NSError(domain: "UIReviewRenderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "UIReviewRenderTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// 画面を UIKit のウィンドウに載せて画像にし、ui-review/ に保存する(Form・NavigationStack は ImageRenderer では描けないため)。
    /// 保存できたら true。ウィンドウが取れない・空白だったときは false(ログに残す。テストは落とさない)。
    /// 高さは 2000pt まで(3200pt では drawHierarchy が空白を返した。NotificationSettingsRenderTests と同じ)
    private func writeFromWindow(
        _ content: some View,
        name: String,
        width windowWidth: CGFloat = 402,
        height windowHeight: CGFloat = 852,
        dark: Bool = false,
        settleSeconds: Double = 0.6
    ) async -> Bool {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            print("[UIReviewRenderTests] \(name): UIWindowScene が取れないので描きません")
            return false
        }
        let host = UIHostingController(
            rootView: content
                .environment(\.colorScheme, dark ? .dark : .light)
                // アプリ本体(RootView)と同じブランド色
                .tint(LienColors.accent)
        )
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // Form の初期描画と、画面が .task で読み込む値(設定のプロフィール)が落ち着くのを待つ
        try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 2 // 3x のシミュレータでも、画像が大きくなりすぎないように
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard isNotBlank(image), let png = image.pngData() else {
            print("[UIReviewRenderTests] \(name): 空白の画像だったので保存しません(ウィンドウ \(windowWidth)×\(windowHeight))")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        } catch {
            print("[UIReviewRenderTests] \(name): 保存できません: \(error)")
            return false
        }
        return true
    }

    /// 描けた画像が、空白(1 色)だけでないか。ウィンドウに載らず真っ白・真っ黒だった画像を、保存しないための確認
    private func isNotBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, let provider = cg.dataProvider, let bytes = provider.data as Data? else { return false }
        guard bytes.count > 8 else { return false }
        let first = (bytes[0], bytes[1], bytes[2])
        var index = 4
        while index < bytes.count - 3 {
            if (bytes[index], bytes[index + 1], bytes[index + 2]) != first { return true }
            index += 4 * 7
        }
        return false
    }

    // MARK: - オンボーディング(1画面)

    func testRenderOnboarding() async throws {
        let model = OnboardingViewModel(
            authService: StubAuthService(),
            pushAuthorizer: NoopPushAuthorizer(),
            onFinished: {}
        )
        try await write(OnboardingView(viewModel: model, scrolls: false), name: "onboarding-tall", height: 1200)

        // 入力済み(ボタンが押せる状態)。上と同じ画面なので、色の確認用に2枚目を描く。
        // アイコンは最初の「ふたば」以外(いちご)を選んだ状態にして、輪とチェックが選んだ絵に付くのを見る
        model.nickname = "あおい"
        model.avatar = .strawberry
        model.agreedToTerms = true
        try await write(OnboardingView(viewModel: model, scrolls: false), name: "onboarding-filled", height: 1200)
    }

    // MARK: - アイコンの選択(選ぶ部品だけ)

    func testRenderAvatarPicker() async throws {
        // いちごを選んだ状態(輪 + 右下のチェック)。オンボーディングと同じ左右 24pt の余白で、393pt の画面に置く
        try await write(
            AvatarPicker(selection: .constant(.strawberry)).padding(LienSpacing.l),
            name: "avatar-picker",
            height: 300
        )
    }

    // MARK: - プロフィール編集(Form なので UIKit のウィンドウで描く)

    func testRenderProfileEdit() async {
        var rendered = 0
        // 標準の幅(402pt)のライトとダーク、幅の狭い画面(320pt。Form の行の中身が 256pt ほどに縮む)
        for (label, windowWidth, dark) in [
            ("", CGFloat(402), false),
            ("-dark", 402, true),
            ("-320", 320, false),
        ] {
            let editor = ProfileEditViewModel(
                profile: UserProfile(nickname: "あおい", avatarEmoji: LienAvatar.strawberry.rawValue),
                auth: StubAuthService(),
                onSaved: { _ in }
            )
            let screen = NavigationStack { ProfileEditView(editor: editor) }
            if await writeFromWindow(screen, name: "profile-edit\(label)", width: windowWidth, dark: dark) {
                rendered += 1
            }
        }
        print("[UIReviewRenderTests] プロフィール編集: \(rendered) 枚")
    }

    // MARK: - 設定のプロフィール行(Form なので UIKit のウィンドウで描く)

    func testRenderSettingsProfileRow() async throws {
        var rendered = 0
        // 保存されている値が、イラストの id のとき(いちご)と、旧版の絵文字で近いイラストが無いとき(🐶 → 既定の「ふたば」)
        for (label, stored) in [("", LienAvatar.strawberry.rawValue), ("-legacy", "🐶")] {
            let auth = StubAuthService()
            try await auth.signInAnonymously()
            try await auth.updateNicknameAndAvatar(nickname: "あおい", avatarEmoji: stored)
            let screen = NavigationStack {
                SettingsView(
                    auth: auth,
                    store: nil,
                    account: NoopAccountOperator(),
                    promiseClient: StubPromiseAPIClient(),
                    reminders: nil,
                    pushAuthorizer: NoopPushAuthorizer(),
                    onPromiseSaved: { _ in },
                    onReminderSaved: { _ in }
                )
            }
            if await writeFromWindow(screen, name: "settings-profile-row\(label)") {
                rendered += 1
            }
        }
        print("[UIReviewRenderTests] 設定のプロフィール行: \(rendered) 枚")
    }

    // MARK: - 約束設定

    func testRenderPromiseSetup() async throws {
        try await write(
            NavigationStack { PromiseSetupView(client: StubPromiseAPIClient(), store: nil) },
            name: "promise-setup"
        )
    }

    // MARK: - 招待

    func testRenderPairing() async throws {
        try await write(
            NavigationStack {
                PairingView(
                    inviteClient: StubInviteClient(),
                    store: nil,
                    pendingInviteToken: .constant(nil),
                    onPaired: {}
                )
            },
            name: "pairing"
        )
    }

    // MARK: - 設定

    func testRenderSettings() async throws {
        let view = SettingsView(
            auth: StubAuthService(),
            store: nil,
            account: NoopAccountOperator(),
            promiseClient: StubPromiseAPIClient(),
            reminders: nil,
            pushAuthorizer: NoopPushAuthorizer(),
            onPromiseSaved: { _ in },
            onReminderSaved: { _ in }
        )
        try await write(NavigationStack { view }, name: "settings")
    }

    // MARK: - ペイウォール

    func testRenderPaywall() async throws {
        let model = PaywallViewModel(
            context: .ticketEmpty,
            client: MockPurchasesClient(),
            entitlements: EntitlementStore()
        )
        await model.load()
        try await write(PaywallView(model: model), name: "paywall")
    }

    // MARK: - ホーム(状態違い)

    private func homeView(_ snapshot: PairSnapshot, onInvite: (() -> Void)? = nil) throws -> some View {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lien-ui-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppGroupStore(containerURL: directory)
        try store.saveSnapshot(snapshot)
        let model = HomeViewModel(store: store, checkinService: LocalEchoCheckinService())
        model.load()
        // ImageRenderer は ScrollView を描けないので、中身だけを描く(StoreScreenshotRenderTests と同じ)
        return VStack(spacing: 0) {
            SnapshotContent(viewModel: model, snapshot: snapshot, onInvite: onInvite, moderation: nil)
                .padding(LienSpacing.l)
            Spacer(minLength: 0)
        }
        .safeAreaInset(edge: .bottom) {
            HomeActionBar(viewModel: model)
        }
    }

    func testRenderHomeWaiting() async throws {
        try await write(
            try homeView(PairSnapshot.previewValue(todayMeDone: false, todayPartnerDone: true)),
            name: "home-waiting"
        )
    }

    func testRenderHomeBothDone() async throws {
        try await write(
            try homeView(PairSnapshot.previewValue(todayMeDone: true, todayPartnerDone: true, plantMood: .happy)),
            name: "home-both-done"
        )
    }

    func testRenderHomeSolo() async throws {
        try await write(
            try homeView(
                PairSnapshot.previewValue(pairId: nil, todayPartnerDone: false, plantStage: 0, plantMood: .normal, ticketBalance: nil),
                onInvite: {}
            ),
            name: "home-solo"
        )
    }
}

// MARK: - スタブ

private struct NoopPushAuthorizer: PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool { false }
}

@MainActor
private final class NoopAccountOperator: AccountOperating {
    func dissolvePair() async throws {}
    func deleteAccount() async throws {}
    func signOut() async {}
}
