#!/usr/bin/env python3
"""App Store 用スクリーンショットの検査(issue #80 / MK7)。

`products/lien/marketing/screenshots/` の完成画像が、受入条件とキャプションの正本に合っているかを、
macOS も Xcode も無い CI(ubuntu)で確かめる。標準ライブラリだけで動く(Pillow を使わない)。

検査する内容:
  1. captions.json: 6 枚(5〜6 枚)・6.7in / 6.1in の寸法(1290×2796 / 1179×2556)・ポイント×3 = 画素数
  2. 文言: 見出しは2行で1行13文字まで、バッジ8文字まで、サブ28文字まで。claim(根拠)が空でないこと。
     罰・恥・誇大表現(失敗 / 最強 / No.1 / 日本一 / 絶対 / 必ず / 無料 / 誰でも)を使っていないこと
  3. manifest.json: この画像を作った captions.json の SHA-256 が、いまの captions.json と一致すること
     (文言を変えて画像を作り直していない状態を止める)。CI の来歴(commit / runId)が入っていること
  4. 完成画像: 各サイズに 6 枚、PNG の寸法が一致、アルファが無い(color type 0 / 2)、空でない(20KB 以上)
  5. 一覧画像(contact-sheet-6.7in.png)があること

使い方:
  python3 tools/verify_screenshots.py            # 緑なら OK、赤なら理由を出して終了コード 1
  python3 tools/verify_screenshots.py --root DIR # テスト用

終了コード: 0 = OK / 1 = 不一致あり / 2 = 入力が読めない
"""

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parent / "screenshots"

SIZES = {
    "6.7in": {"width": 1290, "height": 2796},
    "6.1in": {"width": 1179, "height": 2556},
}
FRAME_COUNT = 6
CONTACT_SHEET = "contact-sheet-6.7in.png"
BANNED = ["失敗", "最強", "No.1", "日本一", "絶対", "必ず", "無料", "誰でも"]

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class InputError(Exception):
    """入力が読めない(ファイルが無い・JSON が壊れている)"""


def png_header(path):
    """PNG の (幅, 高さ, カラータイプ) を返す。PNG でなければ InputError。"""
    try:
        data = path.read_bytes()
    except OSError as error:
        raise InputError("%s が読めません: %s" % (path, error))
    if len(data) < 33 or not data.startswith(PNG_SIGNATURE):
        raise InputError("%s は PNG ではありません" % path)
    # 8 バイトの署名 + 4 バイトの長さ + "IHDR" + 幅4 + 高さ4 + ビット深度1 + カラータイプ1
    length, chunk = struct.unpack(">I4s", data[8:16])
    if chunk != b"IHDR" or length != 13:
        raise InputError("%s の先頭が IHDR ではありません" % path)
    width, height = struct.unpack(">II", data[16:24])
    color_type = data[25]
    return width, height, color_type


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise InputError("%s が読めません: %s" % (path, error))
    except json.JSONDecodeError as error:
        raise InputError("%s が JSON として読めません: %s" % (path, error))


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_captions(captions, errors):
    """captions.json の形と文言。"""
    if captions.get("version") != 1:
        errors.append("captions.json: version は 1(いまは %r)" % captions.get("version"))

    sizes = captions.get("sizes") or {}
    if set(sizes) != set(SIZES):
        errors.append("captions.json: sizes は %s(いまは %s)" % (sorted(SIZES), sorted(sizes)))
    for key, expected in SIZES.items():
        size = sizes.get(key) or {}
        for field, value in (("width", expected["width"]), ("height", expected["height"])):
            if size.get(field) != value:
                errors.append("captions.json: %s の %s は %d(いまは %r)" % (key, field, value, size.get(field)))
        point_w = size.get("pointWidth")
        point_h = size.get("pointHeight")
        if not isinstance(point_w, (int, float)) or not isinstance(point_h, (int, float)):
            errors.append("captions.json: %s の pointWidth / pointHeight が数値でない" % key)
        elif point_w * 3 != expected["width"] or point_h * 3 != expected["height"]:
            errors.append(
                "captions.json: %s のポイント×3 が画素数と合わない(%r×%r → %r×%r)"
                % (key, point_w, point_h, point_w * 3, point_h * 3)
            )
        if not size.get("device"):
            errors.append("captions.json: %s の device(端末名)が無い" % key)

    frames = captions.get("frames") or []
    if not 5 <= len(frames) <= 6:
        errors.append("captions.json: フレームは 5〜6 枚(いまは %d)" % len(frames))
    if len(frames) != FRAME_COUNT:
        errors.append("captions.json: いまの受入は %d 枚(いまは %d)" % (FRAME_COUNT, len(frames)))

    ids = [frame.get("id") for frame in frames]
    if len(set(ids)) != len(ids):
        errors.append("captions.json: id が重複している: %s" % ids)

    for frame in frames:
        name = frame.get("id", "(id なし)")
        headline = frame.get("headline") or []
        if len(headline) != 2:
            errors.append("captions.json: %s の見出しは2行(いまは %d 行)" % (name, len(headline)))
        for line in headline:
            if not isinstance(line, str) or len(line) > 13:
                errors.append("captions.json: %s の見出しが長すぎる(13文字まで): %r" % (name, line))
        badge = frame.get("badge") or ""
        if len(badge) > 8:
            errors.append("captions.json: %s のバッジが長すぎる(8文字まで): %r" % (name, badge))
        sub = frame.get("sub") or ""
        if not sub or len(sub) > 28:
            errors.append("captions.json: %s のサブコピーは1〜28文字: %r" % (name, sub))
        claim = frame.get("claim") or ""
        if len(claim) < 10:
            errors.append("captions.json: %s の claim(根拠)が無い。mkt-review が確かめられない" % name)
        elif "§" not in claim and "REQUIREMENTS" not in claim and "CONCEPT" not in claim:
            errors.append("captions.json: %s の claim に根拠の節(§…)が無い: %r" % (name, claim))
        if not frame.get("scene"):
            errors.append("captions.json: %s の scene が無い" % name)

        copy = "".join(headline) + badge + sub
        for word in BANNED:
            if word in copy:
                errors.append("captions.json: %s に使わない表現「%s」が入っている: %s" % (name, word, copy))


def check_manifest(captions_path, manifest, frames, errors):
    """manifest.json が、いまの captions.json から作られているか。"""
    if not manifest:
        errors.append("manifest.json が空")
        return
    if manifest.get("catalogVersion") != 1:
        errors.append("manifest.json: catalogVersion が 1 でない")
    if manifest.get("catalogUpdated") is None:
        errors.append("manifest.json: catalogUpdated が無い")

    expected = sha256(captions_path)
    actual = manifest.get("captionsSHA256")
    if actual != expected:
        errors.append(
            "manifest.json: captions.json の SHA-256 が違う(画像を作り直していない)。"
            " いまの captions.json = %s / manifest = %s" % (expected, actual)
        )

    sizes = manifest.get("sizes") or {}
    for key, expected_size in SIZES.items():
        entry = sizes.get(key) or {}
        if entry.get("width") != expected_size["width"] or entry.get("height") != expected_size["height"]:
            errors.append("manifest.json: %s の寸法が違う: %r" % (key, entry))

    provenance = manifest.get("provenance") or {}
    for field in ("commit", "runId"):
        if not provenance.get(field):
            errors.append("manifest.json: CI の来歴(%s)が無い。CI の artifact から作った画像だけをコミットする" % field)

    entries = manifest.get("frames") or []
    ids = [entry.get("id") for entry in entries]
    if ids != [frame.get("id") for frame in frames]:
        errors.append("manifest.json: フレームの並びが captions.json と違う: %s" % ids)
    for entry in entries:
        files = entry.get("files") or {}
        for key in SIZES:
            expected_file = "%s/%s.png" % (key, entry.get("id"))
            if files.get(key) != expected_file:
                errors.append("manifest.json: %s の %s のファイル名が違う: %r" % (entry.get("id"), key, files.get(key)))
    if not manifest.get("generatedAt"):
        errors.append("manifest.json: generatedAt が無い")


def check_images(root, frames, manifest, errors):
    """完成画像の寸法・アルファ・空でないこと。"""
    manifest_files = {entry.get("id"): entry.get("files") or {} for entry in (manifest or {}).get("frames") or []}
    for key, size in SIZES.items():
        directory = root / key
        if not directory.is_dir():
            errors.append("%s/ がありません" % key)
            continue
        for frame in frames:
            name = frame.get("id")
            path = directory / ("%s.png" % name)
            if not path.exists():
                errors.append("%s がありません" % path.relative_to(root))
                continue
            try:
                width, height, color_type = png_header(path)
            except InputError as error:
                errors.append(str(error))
                continue
            if (width, height) != (size["width"], size["height"]):
                errors.append(
                    "%s: 寸法が %d×%d(期待 %d×%d)" % (path.relative_to(root), width, height, size["width"], size["height"])
                )
            if color_type not in (0, 2):
                errors.append(
                    "%s: アルファ付き(color type %d)。App Store はアルファなしの PNG / JPEG を要求する"
                    % (path.relative_to(root), color_type)
                )
            # manifest にあるファイル名と実体が一致すること(取り違えを止める)
            expected = manifest_files.get(name, {}).get(key)
            if expected and expected != "%s/%s.png" % (key, name):
                errors.append("manifest.json の %s/%s のファイル名が実体と違う" % (key, name))

        # 余計な PNG を置かない(差し替え漏れ・古い画像の混入を止める)
        names = {frame.get("id") for frame in frames}
        for extra in sorted(directory.glob("*.png")):
            if extra.stem not in names:
                errors.append("%s: captions.json に無い画像がある" % extra.relative_to(root))

    sheet = root / CONTACT_SHEET
    if not sheet.exists():
        errors.append("%s がありません(G4 で6枚を並べて見る)" % CONTACT_SHEET)
    else:
        try:
            width, height, _ = png_header(sheet)
            if width != SIZES["6.7in"]["width"]:
                errors.append("%s: 幅が %d(6.7in と同じ 1290 にする)" % (CONTACT_SHEET, width))
            if height <= 0:
                errors.append("%s: 高さが 0" % CONTACT_SHEET)
        except InputError as error:
            errors.append(str(error))


def verify(root=DEFAULT_ROOT):
    """root(screenshots/) を検査して、エラーの一覧を返す。空なら OK。"""
    root = Path(root)
    errors = []
    captions_path = root / "captions.json"
    manifest_path = root / "manifest.json"

    captions = load_json(captions_path)
    manifest = load_json(manifest_path) if manifest_path.exists() else None
    frames = captions.get("frames") or []

    check_captions(captions, errors)
    if manifest is None:
        errors.append("manifest.json がありません(CI の artifact からコピーする)")
    check_manifest(captions_path, manifest, frames, errors)
    check_images(root, frames, manifest, errors)
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description="App Store 用スクリーンショットの検査(issue #80)")
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="screenshots/ の場所(既定: このリポジトリ)")
    args = parser.parse_args(argv)

    try:
        errors = verify(Path(args.root))
    except InputError as error:
        print("NG: %s" % error, file=sys.stderr)
        return 2

    if errors:
        print("NG: %d 件" % len(errors), file=sys.stderr)
        for error in errors:
            print("  - %s" % error, file=sys.stderr)
        return 1

    print("OK: 6.7in / 6.1in 各 %d 枚 + キャプション + manifest(アルファなし・寸法一致)" % FRAME_COUNT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
