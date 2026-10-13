// ViewShims.swift — SwiftUI の View を macOS の SDK で型検査するための、iOS 専用 API の代替。
// iOS にしか無い API を View が使うようになって型検査が落ちたら、ここに macOS 用の同名の代替を足す。
import SwiftUI

extension View {
    /// macOS には fullScreenCover が無いので sheet で代用する(型検査のためだけ)
    func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }
}

/// 約束設定の画面(Features/PromiseSetup/PromiseSetupView.swift)は iOS 専用の API を使うので、型検査の対象から外している。
/// 設定画面(SettingsView)が使うので、同じ初期化子を持つ代役を置く。PromiseSetupView の初期化子を変えたら、ここも同じに直す
struct PromiseSetupView: View {
    init(
        client: PromiseAPIClient,
        store: AppGroupStore?,
        existing: Promise? = nil,
        onSaved: @escaping (Promise) -> Void = { _ in }
    ) {}

    var body: some View { EmptyView() }
}
