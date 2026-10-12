#!/usr/bin/env python3
"""xcresult に入れたテストの添付ファイル(XCTAttachment)を、人が読める名前の PNG として取り出す(issue #56)。

  python3 export_attachments.py PATH/TO/Lien.xcresult OUT_DIR [--prefix plant_]

lien-ios が `xcodebuild test -resultBundlePath` で作った xcresult から、PlantRenderTests が保存した
実描画の一覧画像を取り出し、GitHub Actions の artifact にするためのもの。

  1. `xcrun xcresulttool export attachments --path XCRESULT --output-path TMP` で添付を書き出す
     (Xcode 16 以降。TMP/manifest.json に「テスト → 添付(exportedFileName / suggestedHumanReadableName)」が入る)
  2. suggestedHumanReadableName(例 `plant_01_states_light.png_0_<UUID>.png`)から、連番と UUID を取り除いた
     読みやすい名前(`plant_01_states_light.png`)で OUT_DIR へコピーする。--prefix で始まる名前だけ
     (指定しなければ全部)

終了コード: 0 = 1枚以上取り出せた / 1 = 添付が無かった / 2 = xcresulttool が使えない・失敗した
`--from-dir DIR` は、すでに書き出し済みのディレクトリ(manifest.json つき)を使う(単体テスト用)。
Python 3.9+ の標準ライブラリだけ。
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

UUID_SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")


def iter_attachments(node):
    """manifest.json の中から exportedFileName を持つ辞書(= 添付1件)を、構造によらず全部拾う。"""
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node
        for value in node.values():
            for found in iter_attachments(value):
                yield found
    elif isinstance(node, list):
        for value in node:
            for found in iter_attachments(value):
                yield found


def clean_name(suggested, exported):
    """suggestedHumanReadableName から連番と UUID を取り除く。無ければ書き出されたファイル名のまま。"""
    if not suggested:
        return exported
    stem, ext = os.path.splitext(suggested)
    stem = UUID_SUFFIX.sub("", stem)
    # attachment.name に拡張子を含めたとき("x.png")の二重の拡張子を 1 つにする
    if ext and stem.lower().endswith(ext.lower()):
        stem = stem[: -len(ext)]
    name = (stem + ext) if ext else stem
    return re.sub(r"[\\/:*?\"<>|]", "_", name) or exported


def collect(export_dir, out_dir, prefix):
    manifest_path = os.path.join(export_dir, "manifest.json")
    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    os.makedirs(out_dir, exist_ok=True)
    copied, used = [], set()
    for attachment in iter_attachments(manifest):
        exported = attachment["exportedFileName"]
        source = os.path.join(export_dir, exported)
        if not os.path.isfile(source):
            continue
        name = clean_name(attachment.get("suggestedHumanReadableName"), exported)
        if prefix and not name.startswith(prefix):
            continue
        # 同じ名前が複数あれば(再試行など)連番を付ける
        candidate, n = name, 1
        while candidate in used:
            stem, ext = os.path.splitext(name)
            candidate = "%s_%d%s" % (stem, n, ext)
            n += 1
        used.add(candidate)
        shutil.copyfile(source, os.path.join(out_dir, candidate))
        copied.append(candidate)
    return copied


def main(argv=None):
    ap = argparse.ArgumentParser(description="xcresult の添付ファイルを人が読める名前で取り出す")
    ap.add_argument("xcresult", help="xcodebuild -resultBundlePath で作った .xcresult")
    ap.add_argument("out_dir", help="取り出し先のディレクトリ")
    ap.add_argument("--prefix", default="", help="この文字列で始まる名前の添付だけ取り出す(既定: 全部)")
    ap.add_argument("--from-dir", help="書き出し済みのディレクトリ(manifest.json つき)を使う。単体テスト用")
    args = ap.parse_args(argv)

    cleanup = None
    export_dir = args.from_dir
    if not export_dir:
        if not os.path.isdir(args.xcresult):
            print("xcresult が見つかりません: %s" % args.xcresult, file=sys.stderr)
            return 2
        export_dir = cleanup = tempfile.mkdtemp(prefix="xcresult-attachments-")
        cmd = ["xcrun", "xcresulttool", "export", "attachments", "--path", args.xcresult, "--output-path", export_dir]
        result = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
        if result.returncode != 0:
            print("xcresulttool が失敗しました(終了コード %d):\n%s%s" % (result.returncode, result.stdout, result.stderr),
                  file=sys.stderr)
            shutil.rmtree(cleanup, ignore_errors=True)
            return 2
    try:
        if not os.path.isfile(os.path.join(export_dir, "manifest.json")):
            print("manifest.json がありません: %s" % export_dir, file=sys.stderr)
            return 2
        copied = collect(export_dir, args.out_dir, args.prefix)
    finally:
        if cleanup:
            shutil.rmtree(cleanup, ignore_errors=True)
    if not copied:
        print("取り出せる添付がありません(prefix=%r)" % args.prefix, file=sys.stderr)
        return 1
    for name in sorted(copied):
        size = os.path.getsize(os.path.join(args.out_dir, name))
        print("%8d  %s" % (size, name))
    print("%d 件を %s に取り出しました" % (len(copied), args.out_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
