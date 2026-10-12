#!/usr/bin/env python3
"""svg/ のレイヤー SVG から Xcode のアセットカタログ(PlantAssets.xcassets)を生成する。

- imageset 名は `plant_<レイヤー名>`(例: plant_pot_back / plant_head_s5)。iOS の PlantLayers.assetPrefix と一致させる
- SVG をそのままコピーし、`preserves-vector-representation = true`(ベクターのまま拡大・ウィジェットでも鮮明)
- **元の色のまま入れる**(template にしない)。花の塗り(petal_sN)の着色は iOS のコード側で行う
  (`Image.renderingMode(.template)` + foregroundStyle)。着色し忘れても黒くならず、既定の花色で出る
- universal / single scale(ベクターなので 1x/2x/3x の別ファイルは要らない)
- 再生成のたびに作り直す(消したレイヤーが残らない・決定論)。ios/ には書き込まない
  (アセットの正本は assets/plant/。Xcode からは project.yml がこのフォルダを参照する)

使い方: python3 tools/build_asset_catalog.py   (先に python3 tools/gen_layers.py で svg/ を生成しておく)
標準ライブラリだけ(Python 3.9+)。
"""

import argparse
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.normpath(os.path.join(HERE, ".."))

ASSET_PREFIX = "plant_"
INFO = {"author": "xcode", "version": 1}


def write_json(path, obj):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")


def build(root=DEFAULT_ROOT):
    """root/svg/*.svg → root/PlantAssets.xcassets。作った imageset の数を返す。"""
    svg_dir = os.path.join(root, "svg")
    xcassets = os.path.join(root, "PlantAssets.xcassets")
    if not os.path.isdir(svg_dir):
        raise SystemExit("ERROR: %s がありません(先に python3 tools/gen_layers.py を実行してください)" % svg_dir)
    names = sorted(n[:-4] for n in os.listdir(svg_dir) if n.endswith(".svg"))
    if not names:
        raise SystemExit("ERROR: %s に SVG がありません" % svg_dir)

    if os.path.isdir(xcassets):
        shutil.rmtree(xcassets)
    os.makedirs(xcassets)
    write_json(os.path.join(xcassets, "Contents.json"), {"info": INFO})

    for name in names:
        asset = ASSET_PREFIX + name
        imageset = os.path.join(xcassets, asset + ".imageset")
        os.makedirs(imageset)
        shutil.copyfile(os.path.join(svg_dir, name + ".svg"), os.path.join(imageset, asset + ".svg"))
        write_json(os.path.join(imageset, "Contents.json"), {
            "images": [{"filename": asset + ".svg", "idiom": "universal"}],
            "info": INFO,
            "properties": {
                "preserves-vector-representation": True,
                "template-rendering-intent": "original",
            },
        })
    return len(names)


def main(argv=None):
    ap = argparse.ArgumentParser(description="svg/ から PlantAssets.xcassets を生成する")
    ap.add_argument("--root", default=DEFAULT_ROOT, help="products/lien/assets/plant(既定: このスクリプトの親)")
    args = ap.parse_args(argv)
    count = build(args.root)
    print("OK: %d imagesets -> %s" % (count, os.path.join(args.root, "PlantAssets.xcassets")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
