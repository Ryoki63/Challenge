# -*- coding: utf-8 -*-
"""テストファイルから XCTestCase のクラスと test メソッドを拾って main.swift を作る(scripts/macos-check 専用)。

使い方: python3 gen_runner.py <出力する main.swift> <テストファイル...>
環境変数 ONLY(正規表現)で、実行するテストを "クラス名.メソッド名" で絞れる(生成された main.swift が読む)。
Python 3.9 でも動くよう、ファイルを utf-8 で読む(日本語を含む長い行を標準入力に流さない)。
"""
import io
import re
import sys

CLASS_RE = re.compile(r"^\s*(?:@MainActor\s+)?(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b")
FUNC_RE = re.compile(r"^\s*func\s+(test\w*)\s*\(\s*\)\s*(async\s+)?(throws\s+)?(?:async\s+)?\{")
PRIVATE_FUNC_RE = re.compile(r"^\s*(?:private|fileprivate)\s+func\s+(test\w*)")


def main():
    out_path = sys.argv[1]
    files = sys.argv[2:]
    classes = []  # (name, [method names])
    for path in files:
        with io.open(path, encoding="utf-8") as f:
            current = None
            for line in f:
                m = CLASS_RE.match(line)
                if m and not line.strip().startswith("//"):
                    current = (m.group(1), [])
                    classes.append(current)
                    continue
                if current is None:
                    continue
                if PRIVATE_FUNC_RE.match(line):
                    continue
                fm = FUNC_RE.match(line)
                if fm:
                    current[1].append(fm.group(1))

    lines = []
    lines.append("import Foundation")
    lines.append("import XCTest")
    lines.append("")
    lines.append("nonisolated(unsafe) var passedCount = 0")
    lines.append("nonisolated(unsafe) var failedNames: [String] = []")
    lines.append("let onlyPattern: String? = ProcessInfo.processInfo.environment[\"ONLY\"]")
    lines.append("")
    lines.append("@MainActor func runOne(_ name: String, _ body: () async throws -> Void) async {")
    lines.append("    if let only = onlyPattern, name.range(of: only, options: .regularExpression) == nil { return }")
    lines.append("    XCTestShim.currentTest = name")
    lines.append("    let before = XCTestShim.failures.count")
    lines.append("    do { try await body() } catch is XCTUnwrapError { } catch { XCTestShim.failures.append(\"\\(name) :: threw \\(error)\") }")
    lines.append("    if XCTestShim.failures.count == before { passedCount += 1; print(\"PASS \\(name)\") }")
    lines.append("    else { failedNames.append(name); print(\"FAIL \\(name)\") }")
    lines.append("}")
    lines.append("")
    lines.append("@MainActor func runAll() async {")
    for cls, methods in classes:
        for method in methods:
            lines.append(
                "    await runOne(\"%s.%s\") { let t = %s(); try t.setUpWithError(); t.setUp(); defer { t.tearDown(); try? t.tearDownWithError() }; try await t.%s() }"
                % (cls, method, cls, method)
            )
    lines.append("    print(\"\\n=== passed \\(passedCount), failed \\(failedNames.count), assertions \\(XCTestShim.assertionCount)\")")
    lines.append("    for f in XCTestShim.failures { print(\"  \" + f) }")
    lines.append("    exit(failedNames.isEmpty ? 0 : 1)")
    lines.append("}")
    lines.append("")
    lines.append("Task { @MainActor in await runAll() }")
    lines.append("dispatchMain()")
    with io.open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("classes: %d, tests: %d" % (len(classes), sum(len(m) for _, m in classes)))


main()
