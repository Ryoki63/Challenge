// DeviceTokenStoreTests.swift — APNs デバイストークンの hex 化(issue #8 準備②)

import XCTest
@testable import Lien

final class DeviceTokenStoreTests: XCTestCase {
    /// APNs の慣例形式: 小文字 hex・区切りなし・0 埋め2桁(seed-pair.sh にそのまま渡す形式)
    func testHexStringEncodesLowercasePaddedBytes() {
        let data = Data([0x00, 0x0a, 0xff, 0x12, 0xb0])
        XCTAssertEqual(DeviceTokenStore.hexString(from: data), "000aff12b0")
    }

    func testHexStringOfEmptyDataIsEmpty() {
        XCTAssertEqual(DeviceTokenStore.hexString(from: Data()), "")
    }

    @MainActor
    func testUpdateStoresHexToken() {
        let store = DeviceTokenStore()
        XCTAssertNil(store.deviceTokenHex)
        store.update(deviceToken: Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertEqual(store.deviceTokenHex, "deadbeef")
    }

    // MARK: onUpdate フック(PushTokenSync への橋渡し — issue #55)

    @MainActor
    func testOnUpdateIsCalledForEachNewToken() {
        let store = DeviceTokenStore()
        var received: [String] = []
        store.onUpdate = { received.append($0) }
        store.update(deviceToken: Data([0x01]))
        store.update(deviceToken: Data([0x02]))
        XCTAssertEqual(received, ["01", "02"])
    }

    @MainActor
    func testSettingOnUpdateReplaysAlreadyReceivedToken() {
        // フック設定前(LienApp.init より前)にトークンが届いていても取りこぼさない
        let store = DeviceTokenStore()
        store.update(deviceToken: Data([0xab]))
        var received: [String] = []
        store.onUpdate = { received.append($0) }
        XCTAssertEqual(received, ["ab"])
    }

    @MainActor
    func testRemoteNotificationRelayCallsHandler() async {
        let relay = RemoteNotificationRelay()
        var count = 0
        relay.handler = { count += 1 }
        await relay.notify()
        await relay.notify()
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testRemoteNotificationRelayWithoutHandlerIsNoOp() async {
        let relay = RemoteNotificationRelay()
        await relay.notify() // handler 未設定でも落ちない
    }
}
