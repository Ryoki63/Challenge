// XCTestShim.swift — 最小の XCTest 互換(scripts/macos-check/ 専用。アプリにもテストバンドルにも入らない)
//
// Command Line Tools だけの Mac には XCTest.framework が無いので、LienTests のテストを macOS 上で swiftc だけで
// 動かすために、テストが使う XCTest の API を必要な分だけ作り直したもの。本物の XCTest と挙動が違うところ
// (失敗してもテストを続ける・非同期の待ち・計測など)は持たない。LienTests が新しい API を使うようになったら、
// ここへ足す(check.sh の「テストのコンパイルに失敗」で気づく)。CI(lien-ios)の本物の XCTest が正本。

@_exported import Foundation

public enum XCTestShim {
    nonisolated(unsafe) public static var failures: [String] = []
    nonisolated(unsafe) public static var assertionCount = 0
    nonisolated(unsafe) public static var currentTest = ""

    public static func record(_ message: String, file: StaticString, line: UInt) {
        failures.append("\(currentTest) :: \(file):\(line): \(message)")
    }
}

open class XCTestCase {
    public required init() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
    open func setUp() {}
    open func tearDown() {}
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTestShim.record("XCTFail - \(message)", file: file, line: line)
}

public func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do { if !(try expression()) { XCTestShim.record("XCTAssertTrue failed - \(message())", file: file, line: line) } }
    catch { XCTestShim.record("XCTAssertTrue threw \(error)", file: file, line: line) }
}

public func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do { if try expression() { XCTestShim.record("XCTAssertFalse failed - \(message())", file: file, line: line) } }
    catch { XCTestShim.record("XCTAssertFalse threw \(error)", file: file, line: line) }
}

public func XCTAssertEqual<T: Equatable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do {
        let x = try a(), y = try b()
        if x != y { XCTestShim.record("XCTAssertEqual failed: (\"\(x)\") is not equal to (\"\(y)\") - \(message())", file: file, line: line) }
    } catch { XCTestShim.record("XCTAssertEqual threw \(error)", file: file, line: line) }
}

public func XCTAssertNotEqual<T: Equatable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do {
        let x = try a(), y = try b()
        if x == y { XCTestShim.record("XCTAssertNotEqual failed: (\"\(x)\") is equal to (\"\(y)\") - \(message())", file: file, line: line) }
    } catch { XCTestShim.record("XCTAssertNotEqual threw \(error)", file: file, line: line) }
}

public func XCTAssertNil(
    _ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do { if let v = try expression() { XCTestShim.record("XCTAssertNil failed: \"\(v)\" - \(message())", file: file, line: line) } }
    catch { XCTestShim.record("XCTAssertNil threw \(error)", file: file, line: line) }
}

public func XCTAssertNotNil(
    _ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do { if try expression() == nil { XCTestShim.record("XCTAssertNotNil failed - \(message())", file: file, line: line) } }
    catch { XCTestShim.record("XCTAssertNotNil threw \(error)", file: file, line: line) }
}

public func XCTAssertGreaterThan<T: Comparable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do { let x = try a(), y = try b(); if !(x > y) { XCTestShim.record("XCTAssertGreaterThan failed: (\"\(x)\") is not greater than (\"\(y)\") - \(message())", file: file, line: line) } }
    catch { XCTestShim.record("threw \(error)", file: file, line: line) }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do { let x = try a(), y = try b(); if !(x >= y) { XCTestShim.record("XCTAssertGreaterThanOrEqual failed: (\"\(x)\") < (\"\(y)\") - \(message())", file: file, line: line) } }
    catch { XCTestShim.record("threw \(error)", file: file, line: line) }
}

public func XCTAssertLessThan<T: Comparable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do { let x = try a(), y = try b(); if !(x < y) { XCTestShim.record("XCTAssertLessThan failed: (\"\(x)\") is not less than (\"\(y)\") - \(message())", file: file, line: line) } }
    catch { XCTestShim.record("threw \(error)", file: file, line: line) }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do { let x = try a(), y = try b(); if !(x <= y) { XCTestShim.record("XCTAssertLessThanOrEqual failed: (\"\(x)\") > (\"\(y)\") - \(message())", file: file, line: line) } }
    catch { XCTestShim.record("threw \(error)", file: file, line: line) }
}

public func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line, _ errorHandler: (_ error: Error) -> Void = { _ in }
) {
    XCTestShim.assertionCount += 1
    do {
        _ = try expression()
        XCTestShim.record("XCTAssertThrowsError failed: did not throw an error - \(message())", file: file, line: line)
    } catch { errorHandler(error) }
}

public func XCTAssertNoThrow<T>(
    _ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do { _ = try expression() }
    catch { XCTestShim.record("XCTAssertNoThrow failed: threw \(error) - \(message())", file: file, line: line) }
}

public struct XCTSkip: Error {}

public func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    XCTestShim.assertionCount += 1
    if let value = try expression() { return value }
    XCTestShim.record("XCTUnwrap failed: expected non-nil value of type \"\(T.self)\" - \(message())", file: file, line: line)
    throw XCTUnwrapError()
}

public struct XCTUnwrapError: Error {}

public func XCTAssertEqual<T: FloatingPoint>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTestShim.assertionCount += 1
    do {
        let x = try a(), y = try b()
        if !(abs(x - y) <= accuracy) { XCTestShim.record("XCTAssertEqual failed: (\"\(x)\") is not equal to (\"\(y)\") +/- (\"\(accuracy)\") - \(message())", file: file, line: line) }
    } catch { XCTestShim.record("XCTAssertEqual threw \(error)", file: file, line: line) }
}
