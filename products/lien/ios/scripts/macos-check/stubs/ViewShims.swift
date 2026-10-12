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
