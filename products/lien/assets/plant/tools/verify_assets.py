#!/usr/bin/env python3
"""T09 完了条件の自己検証(CI でも実行)。

検証内容:
  1. png/ に 13 枚(EXPECTED と一致、過不足なし)・各 16x24・RGBA・PNG シグネチャ
  2. PlantAssets.xcassets に 13 imageset + ルート Contents.json。
     各 Contents.json が valid JSON で、参照する PNG が存在し原寸と一致
  3. preview/ に contact_sheet.png と 13 枚の @8x(128x192)

使い方:
  python3 verify_assets.py   # 失敗時 exit 1
"""

import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLANT_DIR = os.path.normpath(os.path.join(HERE, ".."))
PNG_DIR = os.path.join(PLANT_DIR, "png")
PREVIEW_DIR = os.path.join(PLANT_DIR, "preview")
XCASSETS_DIR = os.path.join(PLANT_DIR, "PlantAssets.xcassets")

EXPECTED = [
    "soil",
    "stage1_normal", "stage1_happy",
    "stage2_normal", "stage2_happy",
    "stage3_normal", "stage3_happy",
    "stage4_normal", "stage4_happy",
    "stage5_normal", "stage5_happy",
    "stage2_sad", "stage5_sad",
]
W, H, SCALE = 16, 24, 8

errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


def png_header(path):
    """(width, height, bit_depth, color_type) を返す。PNG でなければ None。"""
    try:
        with open(path, "rb") as f:
            head = f.read(33)
    except OSError:
        return None
    if len(head) < 33 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    w, h = struct.unpack(">II", head[16:24])
    bit_depth, color_type = head[24], head[25]
    return (w, h, bit_depth, color_type)


def main():
    # 1) 原寸 PNG 13枚
    actual = sorted(f for f in os.listdir(PNG_DIR) if f.endswith(".png")) if os.path.isdir(PNG_DIR) else []
    check(actual == sorted(n + ".png" for n in EXPECTED),
          "png/ mismatch: %s" % actual)
    for name in EXPECTED:
        hdr = png_header(os.path.join(PNG_DIR, name + ".png"))
        check(hdr is not None, "%s.png: not a valid PNG" % name)
        if hdr:
            check(hdr[0] == W and hdr[1] == H, "%s.png: %sx%s != %dx%d" % (name, hdr[0], hdr[1], W, H))
            check(hdr[2] == 8 and hdr[3] == 6, "%s.png: expected 8-bit RGBA" % name)

    # 2) Asset Catalog
    root_json = os.path.join(XCASSETS_DIR, "Contents.json")
    check(os.path.isfile(root_json), "missing %s" % root_json)
    if os.path.isfile(root_json):
        with open(root_json, "r", encoding="utf-8") as f:
            json.load(f)
    imagesets = sorted(d for d in os.listdir(XCASSETS_DIR)
                       if d.endswith(".imageset")) if os.path.isdir(XCASSETS_DIR) else []
    check(imagesets == sorted("plant_%s.imageset" % n for n in EXPECTED),
          "imagesets mismatch: %s" % imagesets)
    for name in EXPECTED:
        iset = os.path.join(XCASSETS_DIR, "plant_%s.imageset" % name)
        cj = os.path.join(iset, "Contents.json")
        check(os.path.isfile(cj), "missing %s" % cj)
        if not os.path.isfile(cj):
            continue
        with open(cj, "r", encoding="utf-8") as f:
            data = json.load(f)
        images = data.get("images", [])
        check(len(images) == 1 and images[0].get("idiom") == "universal",
              "%s: unexpected images entry" % cj)
        filename = images[0].get("filename", "")
        png_path = os.path.join(iset, filename)
        check(os.path.isfile(png_path), "%s: referenced png missing (%s)" % (cj, filename))
        hdr = png_header(png_path)
        check(hdr is not None and hdr[0] == W and hdr[1] == H,
              "%s: catalog png must be %dx%d" % (png_path, W, H))

    # 3) プレビュー
    sheet = png_header(os.path.join(PREVIEW_DIR, "contact_sheet.png"))
    check(sheet is not None, "missing preview/contact_sheet.png")
    for name in EXPECTED:
        hdr = png_header(os.path.join(PREVIEW_DIR, name + "@8x.png"))
        check(hdr is not None and hdr[0] == W * SCALE and hdr[1] == H * SCALE,
              "preview/%s@8x.png: expected %dx%d" % (name, W * SCALE, H * SCALE))

    if errors:
        for e in errors:
            print("NG: %s" % e)
        return 1
    print("OK: 13 sprites / 13 imagesets / previews all verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
