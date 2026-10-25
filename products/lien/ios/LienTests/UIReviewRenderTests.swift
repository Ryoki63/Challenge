// UIReviewRenderTests.swift — UI/UX レビュー用に主要画面を PNG に描く(一時ハーネス)
//
// 目的: 画面を目で見てレビューするための画像を、実装そのものから作る。
// 出力: ios/build/ui-review/<name>.png(証拠。コミットしない)
//
// ImageRenderer は同じ run loop で続けて描くと前の結果や空の画像を返すことがあるので、
// 1メソッド1枚にし、描く前に run loop を1回まわす(StoreScreenshotRenderTests と同じ作法)。

import SwiftUI
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

    // MARK: - オンボーディング(1画面)

    func testRenderOnboarding() async throws {
        let model = OnboardingViewModel(
            authService: StubAuthService(),
            pushAuthorizer: NoopPushAuthorizer(),
            onFinished: {}
        )
        try await write(OnboardingView(viewModel: model, scrolls: false), name: "onboarding-tall", height: 1200)

        // 入力済み(ボタンが押せる状態)。上と同じ画面なので、色の確認用に2枚目を描く
        model.nickname = "あおい"
        model.agreedToTerms = true
        try await write(OnboardingView(viewModel: model, scrolls: false), name: "onboarding-filled", height: 1200)
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
