#!/usr/bin/env python3
"""png/ の原寸スプライトから Xcode Asset Catalog(PlantAssets.xcassets)を生成する。

- imageset 名は `plant_<スプライト名>`(例: plant_stage1_normal)
- universal / single scale(ドット絵は SwiftUI 側で整数倍 + .interpolation(.none) 前提)
- ios/ ディレクトリには書き込まない(Xcode への結線は T13。DESIGN §2 の通り
  アセットの正本は assets/plant/ に置く)

使い方:
  python3 build_asset_catalog.py
"""

import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PNG_DIR = os.path.normpath(os.path.join(HERE, "..", "png"))
XCASSETS_DIR = os.path.normpath(os.path.join(HERE, "..", "PlantAssets.xcassets"))

EXPECTED = [
    "soil",
    "stage1_normal", "stage1_happy",
    "stage2_normal", "stage2_happy",
    "stage3_normal", "stage3_happy",
    "stage4_normal", "stage4_happy",
    "stage5_normal", "stage5_happy",
    "stage2_sad", "stage5_sad",
]

INFO = {"author": "xcode", "version": 1}


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def main():
    missing = [n for n in EXPECTED if not os.path.isfile(os.path.join(PNG_DIR, n + ".png"))]
    if missing:
        print("ERROR: missing source png(s): %s (run gen_sprites.py first)" % ", ".join(missing))
        return 1

    # 再生成のたびに同一内容になるよう、一度消してから作り直す(決定論)
    if os.path.isdir(XCASSETS_DIR):
        shutil.rmtree(XCASSETS_DIR)
    os.makedirs(XCASSETS_DIR)
    write_json(os.path.join(XCASSETS_DIR, "Contents.json"), {"info": INFO})

    for name in EXPECTED:
        imageset = os.path.join(XCASSETS_DIR, "plant_%s.imageset" % name)
        os.makedirs(imageset)
        shutil.copyfile(os.path.join(PNG_DIR, name + ".png"),
                        os.path.join(imageset, name + ".png"))
        write_json(os.path.join(imageset, "Contents.json"), {
            "images": [{"filename": name + ".png", "idiom": "universal"}],
            "info": INFO,
            "properties": {"template-rendering-intent": "original"},
        })

    print("OK: %d imagesets -> %s" % (len(EXPECTED), XCASSETS_DIR))
    return 0


if __name__ == "__main__":
    sys.exit(main())
