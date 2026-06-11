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
}
