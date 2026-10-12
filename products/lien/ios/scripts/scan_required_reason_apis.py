#!/usr/bin/env python3
"""アプリ(.app)に入った実行ファイルの「必須理由 API」の使用を棚卸しする(issue #28)。

  python3 scan_required_reason_apis.py PATH/TO/Lien.app [--strict-symbols]

App Store Connect は、必須理由 API(UserDefaults・ファイルのタイムスタンプ・起動時刻・ディスク容量・
キーボード)を使うバイナリに宣言が無いと ITMS-91053 でアップロードを弾く。自前のコードは
LienTests/PrivacyManifestTests がソースから検査するが、**依存パッケージ(supabase-swift とその推移依存)
は静的にリンクされて実行ファイルの中に入る**ので、ソースではなく出来上がったバイナリを見る。

  - 高い確度 : `nm -u` の未定義シンボル(_stat・_mach_absolute_time など、C の関数そのもの)
  - 低い確度 : `strings` に出る API 名(Swift / Objective-C のメタデータ。無関係な型のプロパティ名が混じりうる)
各実行ファイルについて、見つかったカテゴリが「そのバンドルのマニフェスト」「アプリ内のどれかのマニフェスト」で
宣言されているかを表にする。--strict-symbols なら、高い確度の検出が宣言されていないときに終了コード 1。

出力は人が読む表(GitHub の step summary にも使う)。Python 3.9+ の標準ライブラリだけで動く。
"""

import argparse
import os
import plistlib
import re
import subprocess
import sys

PREFIX = "NSPrivacyAccessedAPICategory"

# カテゴリ → (未定義シンボルの正規表現, strings の文字列)
CATEGORIES = {
    PREFIX + "FileTimestamp": (
        r"_(stat|fstat|lstat|fstatat|getattrlist|fgetattrlist|getattrlistat|getattrlistbulk)",
        ["creationDate", "modificationDate", "fileModificationDate", "fileCreationDate", "NSFileCreationDate",
         "NSFileModificationDate", "contentModificationDateKey", "creationDateKey", "attributesOfItem"],
    ),
    PREFIX + "SystemBootTime": (
        r"_mach_absolute_time",
        ["systemUptime"],
    ),
    PREFIX + "DiskSpace": (
        r"_(statfs|statvfs|fstatfs|fstatvfs)",
        ["volumeAvailableCapacity", "volumeTotalCapacity", "systemFreeSize", "systemSize",
         "NSFileSystemFreeSize", "NSFileSystemSize"],
    ),
    PREFIX + "ActiveKeyboards": (
        None,
        ["activeInputModes"],
    ),
    PREFIX + "UserDefaults": (
        None,
        ["NSUserDefaults", "UserDefaults"],
    ),
}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", check=False).stdout


def find_executables(app):
    """(バンドル名, バンドルのパス, 実行ファイルのパス) の一覧。アプリ本体・拡張・埋め込みフレームワーク"""
    found = []
    name = os.path.splitext(os.path.basename(app))[0]
    found.append((name, app, os.path.join(app, name)))
    plugins = os.path.join(app, "PlugIns")
    if os.path.isdir(plugins):
        for entry in sorted(os.listdir(plugins)):
            if entry.endswith(".appex"):
                bundle = os.path.join(plugins, entry)
                exe = os.path.splitext(entry)[0]
                found.append((exe, bundle, os.path.join(bundle, exe)))
    frameworks = os.path.join(app, "Frameworks")
    if os.path.isdir(frameworks):
        for entry in sorted(os.listdir(frameworks)):
            if entry.endswith(".framework"):
                bundle = os.path.join(frameworks, entry)
                exe = os.path.splitext(entry)[0]
                found.append((exe, bundle, os.path.join(bundle, exe)))
    return [item for item in found if os.path.isfile(item[2])]


def read_manifest(path):
    """マニフェストが宣言している必須理由 API のカテゴリ → 理由コード(読めなければ None)"""
    try:
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    declared = {}
    for entry in data.get("NSPrivacyAccessedAPITypes", []) or []:
        declared[entry.get("NSPrivacyAccessedAPIType", "?")] = entry.get("NSPrivacyAccessedAPITypeReasons", []) or []
    return declared


def all_manifests(app):
    """アプリ内の PrivacyInfo.xcprivacy すべて(相対パス → 宣言)。SPM のリソースバンドルのものも含む"""
    manifests = {}
    for root, _dirs, files in os.walk(app):
        if "PrivacyInfo.xcprivacy" in files:
            path = os.path.join(root, "PrivacyInfo.xcprivacy")
            manifests[os.path.relpath(path, os.path.dirname(app))] = read_manifest(path)
    return manifests


def scan_binary(executable):
    """カテゴリ → {"symbols": [...], "strings": [...], "evidence": {文字列: [出どころの行, ...]}}(見つかったものだけ)。
    evidence は strings の出力のうちその語を含む行(Swift の名前修飾に、使っているモジュール名が出る)"""
    undefined = run(["nm", "-u", executable]).splitlines()
    lines = run(["strings", "-a", executable]).splitlines()
    result = {}
    for category, (symbol_pattern, tokens) in CATEGORIES.items():
        symbols = []
        if symbol_pattern:
            regex = re.compile(r"^(" + symbol_pattern + r")(\$.*)?$")
            symbols = sorted({s.strip() for s in undefined if regex.match(s.strip())})
        strings = []
        evidence = {}
        for token in tokens:
            matched = sorted({line.strip() for line in lines if token in line}, key=len)
            if matched:
                strings.append(token)
                evidence[token] = matched[:3]
        if symbols or strings:
            result[category] = {"symbols": symbols, "strings": sorted(strings), "evidence": evidence}
    return result


def short(category):
    return category.replace(PREFIX, "")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app")
    parser.add_argument("--strict-symbols", action="store_true")
    args = parser.parse_args(argv)

    app = args.app.rstrip("/")
    if not os.path.isdir(app):
        print(f"::error::{app} がありません")
        return 2

    manifests = all_manifests(app)
    declared_anywhere = set()
    for declared in manifests.values():
        declared_anywhere |= set((declared or {}).keys())

    print("## 必須理由 API の棚卸し(出来上がった実行ファイル)")
    print()
    print("### プライバシーマニフェスト(アプリ内)")
    for path, declared in sorted(manifests.items()):
        if declared is None:
            print(f"- `{path}`: 読めません")
        elif not declared:
            print(f"- `{path}`: 必須理由 API の宣言なし")
        else:
            body = ", ".join(f"{short(c)}={'/'.join(r)}" for c, r in sorted(declared.items()))
            print(f"- `{path}`: {body}")
    print()

    missing_high = []
    for name, bundle, executable in find_executables(app):
        found = scan_binary(executable)
        own = read_manifest(os.path.join(bundle, "PrivacyInfo.xcprivacy")) or {}
        print(f"### {name}")
        if not found:
            print("- 検出なし")
            print()
            continue
        print("| カテゴリ | 確度 | 検出 | このバンドルで宣言 | アプリ内のどこかで宣言 |")
        print("|---|---|---|---|---|")
        for category, hit in sorted(found.items()):
            own_ok = "はい" if category in own else "**いいえ**"
            any_ok = "はい" if category in declared_anywhere else "**いいえ**"
            if hit["symbols"]:
                print(f"| {short(category)} | 高(シンボル) | `{' '.join(hit['symbols'])}` | {own_ok} | {any_ok} |")
                if category not in own:
                    missing_high.append((name, category, hit["symbols"]))
            if hit["strings"]:
                print(f"| {short(category)} | 低(文字列) | `{' '.join(hit['strings'])}` | {own_ok} | {any_ok} |")
        print()
        # 低い確度の検出は、どこから来たかを見て判断する(例: 依存パッケージのモジュール名が名前修飾に出る)
        for category, hit in sorted(found.items()):
            for token, samples in sorted(hit["evidence"].items()):
                if token in ("UserDefaults", "NSUserDefaults"):
                    continue  # 自前のコードが使っている(PrivacyManifestTests が宣言を検査する)
                for line in samples:
                    print(f"- `{token}` の出どころ: `{line[:150]}`")
        print()

    if missing_high:
        print("### 宣言が足りない可能性が高いもの(シンボル)")
        for name, category, symbols in missing_high:
            print(f"- {name}: {short(category)} ← {' '.join(symbols)}")
        print()
        if args.strict_symbols:
            print("::error::必須理由 API のシンボルを使っているのに、そのバンドルのマニフェストで宣言していません(上の表)")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
