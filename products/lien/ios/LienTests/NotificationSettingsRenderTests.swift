// NotificationSettingsRenderTests.swift — 通知の設定画面と、設定の「通知」の行を、実際に描いて一覧画像にする(T16 #16 の Opus レビュー: 描画の確認)
//
// 設定 → 通知の画面と、設定画面の「通知」セクション(右側にリマインドの要約が付く行)は、新しい画面なのに、CI の一覧画像が無く、
// 目で見た確認をしていなかった。Form は ImageRenderer では描けないので、UIKit のウィンドウに載せて描き、
// 通常と最大の文字サイズ・ライトとダーク・OS の通知が拒否されているとき、の画像を保存する。
// 保存先は PlantRenderTests と同じ 2 か所: XCTAttachment(xcresult)と ios/build/plant-render/(lien-ios の artifact「plant-render-sheets」)。
// 保存名は notification_ で始まる(plant_ / photo_ / bubble_ と区別)。
//
// 画像は**目で見るためのもの**で、画素の細かい期待は置かない。UIKit のウィンドウはシミュレータの状態(シーンの有無・
// 画面外の描画)に左右されるので、ウィンドウが取れなかった・空白だったときは、画像を保存せず(ログに残し)、テストは落とさない。
// UIKit を使うので、macOS の下見(macos-check)では走らせない(check.sh の EXCLUDE_TESTS)。

import SwiftUI
import UIKit
import XCTest
@testable import Lien

// MARK: - 描画用の部品

private final class RenderAuth: AuthServicing {
    var promise: Promise?
    var currentUserID: UUID? { UUID() }

    @discardableResult
    func signInAnonymously() async throws -> UUID { UUID() }
    func updateProfile(nickname: String, avatarEmoji: String, timezone: String) async throws {}
    func updateNicknameAndAvatar(nickname: String, avatarEmoji: String) async throws {}
    func accessToken() async throws -> String { "token" }
    func fetchProfile() async throws -> UserProfile { UserProfile(nickname: "あきら", avatarEmoji: "🌱") }
    func fetchMyPromise() async throws -> Promise? { promise }
    func signOut() async {}
}

private final class RenderAuthorizer: PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool { true }
}

@MainActor
final class NotificationSettingsRenderTests: XCTestCase {
    private let now = NotificationClock.date(2026, 10, 14, 12, 0)

    private struct Parts {
        let auth: RenderAuth
        let scheduler: ReminderScheduler
        let center: FakeNotificationCenter
    }

    private func makeParts(
        authorization: NotificationAuthorization = .authorized,
        remindAt: String? = "20:30"
    ) -> Parts {
        let auth = RenderAuth()
        auth.promise = Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: remindAt)
        let center = FakeNotificationCenter()
        center.authorization = authorization
        let store = InMemoryNotificationPreferencesStore(NotificationPreferences(reminder: ReminderPreference(remindAt: remindAt)))
        let snapshot = NotificationSnapshots.paired(updatedAt: now)
        let current = now
        let scheduler = ReminderScheduler(
            center: center,
            preferences: store,
            snapshotSource: { snapshot },
            now: { current },
            calendar: { NotificationClock.calendar() }
        )
        return Parts(auth: auth, scheduler: scheduler, center: center)
    }

    /// 通知の設定画面(読み込み済みの状態)と、その状態管理
    private func settingsScreen(_ parts: Parts) async -> (screen: AnyView, viewModel: NotificationSettingsViewModel) {
        let viewModel = NotificationSettingsViewModel(
            auth: parts.auth,
            promiseClient: StubPromiseAPIClient(),
            reminders: parts.scheduler,
            authorizer: RenderAuthorizer()
        )
        await viewModel.load() // 読み込み済みの状態で描く(読み込み中の表示を撮らない)
        return (AnyView(NavigationStack { NotificationSettingsView(viewModel: viewModel) }), viewModel)
    }

    private func settingsRow(_ parts: Parts) -> some View {
        NavigationStack {
            Form {
                NotificationSettingsSection(
                    auth: parts.auth,
                    promiseClient: StubPromiseAPIClient(),
                    reminders: parts.scheduler,
                    pushAuthorizer: RenderAuthorizer(),
                    savedPromise: Promise(id: "p-1", title: "筋トレ", emoji: "💪", remindAt: "20:30"),
                    onReminderSaved: { _ in }
                )
            }
            .navigationTitle(Strings.Settings.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 描く

    /// 画面を UIKit のウィンドウに載せて、画像にする。ウィンドウが取れない・空白のときは nil
    private func render<Content: View>(
        _ content: Content,
        size: DynamicTypeSize,
        dark: Bool,
        height: CGFloat
    ) async -> UIImage? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let host = UIHostingController(
            rootView: content
                .environment(\.dynamicTypeSize, size)
                .environment(\.colorScheme, dark ? .dark : .light)
        )
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 500_000_000) // Form の初期描画が落ち着くのを待つ
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 2 // 3x のシミュレータでも、画像が大きくなりすぎないように
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard isNotBlank(image) else {
            print("[NotificationSettingsRenderTests] 空白の画像だったので保存しません(ウィンドウの高さ \(height))")
            return nil
        }
        return image
    }

    private func save(_ name: String, _ image: UIImage, file: StaticString = #filePath) {
        guard let png = image.pngData() else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + ".png"
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = SourceTree.iosRoot(from: file)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("plant-render", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent(name + ".png"))
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

    // MARK: - 一覧画像

    func testRenderTheNotificationSettingsScreenAtEveryTextSize() async {
        var rendered = 0
        for (label, size, dark, height) in [
            ("standard_light", DynamicTypeSize.large, false, CGFloat(1000)),
            ("standard_dark", .large, true, 1000),
            ("accessibility5_light", .accessibility5, false, 3200),
            ("accessibility5_dark", .accessibility5, true, 3200),
        ] {
            let (screen, viewModel) = await settingsScreen(makeParts())
            XCTAssertEqual(viewModel.loadState, .loaded)
            XCTAssertTrue(viewModel.canEditReminder, "リマインドの操作が出る状態を描く")
            guard let image = await render(screen, size: size, dark: dark, height: height) else { continue }
            save("notification_settings_\(label)", image)
            rendered += 1
        }
        print("[NotificationSettingsRenderTests] 通知の設定画面: \(rendered) 枚")
    }

    func testRenderTheScreenWhenNotificationsAreDeniedAndWhenThereIsNoReminder() async {
        let (denied, deniedModel) = await settingsScreen(makeParts(authorization: .denied))
        XCTAssertEqual(deniedModel.authorization, .denied, "拒否の案内が出る状態を描く")
        if let image = await render(denied, size: .large, dark: false, height: 1100) {
            save("notification_settings_denied_light", image)
        }
        let (off, offModel) = await settingsScreen(makeParts(remindAt: nil))
        XCTAssertFalse(offModel.reminderEnabled, "リマインドがオフの状態を描く")
        if let image = await render(off, size: .large, dark: false, height: 1000) {
            save("notification_settings_reminder_off_light", image)
        }
    }

    func testRenderTheNotificationRowInTheSettingsScreen() async {
        var rendered = 0
        for (label, size, dark, height) in [
            ("standard_light", DynamicTypeSize.large, false, CGFloat(420)),
            ("standard_dark", .large, true, 420),
            ("accessibility5_light", .accessibility5, false, 1000),
        ] {
            let row = settingsRow(makeParts())
            guard let image = await render(row, size: size, dark: dark, height: height) else { continue }
            save("notification_settings_row_\(label)", image)
            rendered += 1
        }
        print("[NotificationSettingsRenderTests] 設定の行: \(rendered) 枚")
    }
}
