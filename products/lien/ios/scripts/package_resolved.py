#!/usr/bin/env python3
"""Package.resolved の比較(issue #28)。

  python3 package_resolved.py compare COMMITTED RESOLVED

COMMITTED はリポジトリにコミットした ios/Package.resolved、RESOLVED は `xcodebuild -resolvePackageDependencies`
の後の .xcodeproj 内のファイル。**ピン(パッケージ・場所・版・コミット)が同じか**だけを比べる。
originHash・インデント・キーの並びの違いは無視する(Xcode の版で変わりうるため)。

食い違ったら、差分と「新しい内容」(ios/Package.resolved に貼る候補)を出して終了コード 1。
Python 3.9+ の標準ライブラリだけで動く。
"""

import json
import sys


def load_pins(path):
    """{identity: (location, version, revision)}。Package.resolved の v1 / v2 / v3 に対応"""
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    pins = data.get("pins")
    if pins is None:  # v1: {"object": {"pins": [...]}}
        pins = (data.get("object") or {}).get("pins", [])
    result = {}
    for pin in pins:
        identity = pin.get("identity") or str(pin.get("package", "")).lower()
        state = pin.get("state") or {}
        location = pin.get("location") or pin.get("repositoryURL")
        result[identity] = (location, state.get("version"), state.get("revision"))
    return result


def diff(committed, resolved):
    """人が読める差分の行のリスト(同じなら空)"""
    lines = []
    for identity in sorted(set(committed) | set(resolved)):
        old, new = committed.get(identity), resolved.get(identity)
        if old == new:
            continue
        if old is None:
            lines.append(f"  追加 : {identity} {new[1]} ({new[2]})")
        elif new is None:
            lines.append(f"  削除 : {identity} {old[1]} ({old[2]})")
        else:
            lines.append(f"  変更 : {identity} {old[1]} ({old[2]}) -> {new[1]} ({new[2]}) / 場所 {old[0]} -> {new[0]}")
    return lines


def compare(committed_path, resolved_path, out=sys.stdout):
    committed = load_pins(committed_path)
    resolved = load_pins(resolved_path)
    lines = diff(committed, resolved)
    if not lines:
        print(f"Package.resolved: OK({len(committed)} パッケージが固定どおり)", file=out)
        return 0
    print("Package.resolved が、project.yml から解決した結果と食い違っています:", file=out)
    for line in lines:
        print(line, file=out)
    print(
        "project.yml の版を変えたときは、下の「新しい内容」を products/lien/ios/Package.resolved に貼ってコミットしてください。",
        file=out,
    )
    print("----- 新しい Package.resolved ここから -----", file=out)
    with open(resolved_path, encoding="utf-8") as fh:
        print(fh.read().rstrip("\n"), file=out)
    print("----- 新しい Package.resolved ここまで -----", file=out)
    return 1


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 3 or argv[0] != "compare":
        print(__doc__, file=sys.stderr)
        return 2
    return compare(argv[1], argv[2])


if __name__ == "__main__":
    sys.exit(main())
