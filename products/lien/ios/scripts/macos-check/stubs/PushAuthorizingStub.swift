// PushAuthorizingStub.swift — Lien/Core/PushManager.swift(UIKit / UserNotifications に依存)の代わり。
// AppServices が使う抽象(PushAuthorizing)だけを、macOS でコンパイルできる形で置く。
// PushManager.swift の protocol PushAuthorizing を変えたら、ここも同じに直す。
import Foundation

protocol PushAuthorizing {
    @discardableResult
    func requestAuthorization() async -> Bool
}
