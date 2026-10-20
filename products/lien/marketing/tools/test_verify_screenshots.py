#!/usr/bin/env python3
"""verify_screenshots.py の検査ロジックの単体テスト(issue #80 / MK7)。

CI(`store-metadata` ジョブ)とローカルの両方で実行する:
  cd products/lien/marketing && python3 -m unittest discover -s tools -p "test_*.py"

検査を壊しても気づけるように、緑になる例だけでなく、赤になる例
(アルファ付き PNG・寸法違い・キャプションの作り直し忘れ・画像の欠け・余計な画像・
長すぎる見出し・禁止表現・根拠の無い claim・来歴の無い manifest)を固定する。
PNG は標準ライブラリ(zlib + struct)で作る。Pillow は使わない。
"""

import hashlib
import json
import os
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import verify_screenshots as vs  # noqa: E402  (sys.path の追加後に読み込む)


# MARK: - テスト用の PNG

def png_bytes(width, height, color_type=2, pixel=(210, 225, 200)):
    """単色の PNG を作る(color_type 2 = RGB / 6 = RGBA / 0 = グレー)。"""
    channels = {0: 1, 2: 3, 6: 4}[color_type]
    color = bytes(pixel[:channels])
    raw = (b"\x00" + color * width) * height

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


# MARK: - テスト用の screenshots/ を作る

def default_captions():
    frames = []
    for index in range(vs.FRAME_COUNT):
        frames.append({
            "id": "%02d_frame" % (index + 1),
            "scene": "home_both",
            "badge": "約束はひとつ",
            "accent": "#82C95C",
            "headline": ["約束は、", "ひとつだけ。"],
            "sub": "ふたりで決めて、毎日つづける習慣アプリ",
            "claim": "CONCEPT §5・REQUIREMENTS §3.4: 約束は1人1つ。",
        })
    return {
        "version": 1,
        "updated": "2026-10-20",
        "note": "テスト",
        "sizes": {
            "6.7in": {"width": 1290, "height": 2796, "pointWidth": 430, "pointHeight": 932, "device": "iPhone 15 Pro Max"},
            "6.1in": {"width": 1179, "height": 2556, "pointWidth": 393, "pointHeight": 852, "device": "iPhone 15 Pro"},
        },
        "frames": frames,
    }


def default_manifest(root, captions):
    return {
        "generatedAt": "2026-10-20T15:00:00+09:00",
        "catalogVersion": 1,
        "catalogUpdated": captions["updated"],
        "captionsSHA256": hashlib.sha256((root / "captions.json").read_bytes()).hexdigest(),
        "sizes": {
            key: {"width": size["width"], "height": size["height"], "device": size["device"]}
            for key, size in captions["sizes"].items()
        },
        "frames": [
            {
                "id": frame["id"],
                "scene": frame["scene"],
                "files": {key: "%s/%s.png" % (key, frame["id"]) for key in captions["sizes"]},
            }
            for frame in captions["frames"]
        ],
        "provenance": {"commit": "0123456789abcdef", "runId": "1234567890", "workflow": "lien-ios", "repository": "Ryoki63/Challenge"},
    }


def build_fixture(directory, captions=None, manifest=None, png=None, skip=(), extra=()):
    """screenshots/ を作って返す。png(width, height) で画像の作り方を差し替えられる。"""
    root = Path(directory) / "screenshots"
    root.mkdir(parents=True, exist_ok=True)
    captions = captions or default_captions()
    (root / "captions.json").write_text(json.dumps(captions, ensure_ascii=False, indent=2), encoding="utf-8")

    make_png = png or (lambda width, height: png_bytes(width, height))
    for key, size in captions["sizes"].items():
        folder = root / key
        folder.mkdir(exist_ok=True)
        for frame in captions["frames"]:
            if (key, frame["id"]) in skip:
                continue
            (folder / ("%s.png" % frame["id"])).write_bytes(make_png(size["width"], size["height"]))
        for name in extra:
            (folder / name).write_bytes(make_png(size["width"], size["height"]))

    (root / vs.CONTACT_SHEET).write_bytes(make_png(1290, 1600))
    if manifest is None:
        manifest = default_manifest(root, captions)
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return root


class VerifyScreenshotsTests(unittest.TestCase):
    def testValidFixtureIsGreen(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp)
            self.assertEqual(vs.verify(root), [])

    def testAlphaPngIsRejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp, png=lambda width, height: png_bytes(width, height, color_type=6))
            errors = vs.verify(root)
            self.assertTrue(any("アルファ付き" in error for error in errors), errors)

    def testWrongSizeIsRejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp, png=lambda width, height: png_bytes(width - 1, height))
            errors = vs.verify(root)
            self.assertTrue(any("寸法が" in error for error in errors), errors)

    def testStaleCaptionsHashIsRejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp)
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            manifest["captionsSHA256"] = "0" * 64
            (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
            errors = vs.verify(root)
            self.assertTrue(any("SHA-256 が違う" in error for error in errors), errors)

    def testMissingImageIsRejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp, skip={("6.1in", "03_frame")})
            errors = vs.verify(root)
            self.assertTrue(any("6.1in/03_frame.png" in error for error in errors), errors)

    def testExtraImageIsRejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp, extra=["99_old.png"])
            errors = vs.verify(root)
            self.assertTrue(any("captions.json に無い画像" in error for error in errors), errors)

    def testLongHeadlineIsRejected(self):
        captions = default_captions()
        captions["frames"][0]["headline"] = ["できない日があっても、だいじょうぶ", "それでも大丈夫"]
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp, captions=captions)
            errors = vs.verify(root)
            self.assertTrue(any("見出しが長すぎる" in error for error in errors), errors)

    def testBannedWordIsRejected(self):
        captions = default_captions()
        captions["frames"][0]["sub"] = "必ず続く習慣アプリ"
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp, captions=captions)
            errors = vs.verify(root)
            self.assertTrue(any("使わない表現「必ず」" in error for error in errors), errors)

    def testClaimWithoutEvidenceIsRejected(self):
        captions = default_captions()
        captions["frames"][0]["claim"] = "毎日つづく習慣アプリです"
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp, captions=captions)
            errors = vs.verify(root)
            self.assertTrue(any("根拠の節" in error for error in errors), errors)

    def testManifestWithoutProvenanceIsRejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp)
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            manifest["provenance"] = {}
            (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
            errors = vs.verify(root)
            self.assertTrue(any("来歴" in error for error in errors), errors)

    def testMissingManifestIsRejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp)
            (root / "manifest.json").unlink()
            errors = vs.verify(root)
            self.assertTrue(any("manifest.json がありません" in error for error in errors), errors)

    def testNotAPngIsRejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = build_fixture(tmp)
            (root / "6.7in" / "01_frame.png").write_bytes(b"not a png")
            errors = vs.verify(root)
            self.assertTrue(any("PNG ではありません" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
