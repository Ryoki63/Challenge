#!/usr/bin/env python3
"""植物の SVG レイヤーとアセットカタログの自己検証(CI の plant-assets ジョブでも実行する)。

確かめること(1つでも外れたら終了コード 1。問題はすべて出してから終わる):
  1. 期待するレイヤー34点がそろっている(svg/ に過不足なし)
  2. 全レイヤーが XML として妥当で、viewBox が "0 0 240 320"(width / height も 240 / 320)
  3. 許可した要素・属性だけを使っている
       許可: svg / defs / g / path / rect / circle / ellipse / line / polyline / polygon /
             linearGradient / radialGradient / stop
       失敗: filter・mask・clipPath・text・style・use・image などの要素、style・filter・mask・clip-path・
             href の属性、stop-opacity(iOS の SVG 描画で崩れる・外部参照になる)
  4. url(#id) の参照先が同じファイルの中にある
  5. 花の塗り petal_s6〜s9 は既定の花色 #FFB3C7 の単色で、左右反転したものと重ならない
     (塗りと線を別レイヤーにしても輪郭が透けない条件。iOS はコード側で着色するので色の約束も要る)
  6. PlantAssets.xcassets に、レイヤーごとの imageset(plant_<レイヤー名>.imageset)が過不足なくある。
     中身は svg/ の SVG と一字一句同じで、preserves-vector-representation = true、template にしていない
  7. peek_offsets.json(のぞきの位置)と layer_stacks.json(重ね順の基準)が読めて、レイヤー名が実在する

使い方: python3 tools/verify_assets.py [--root products/lien/assets/plant]
標準ライブラリだけ(Python 3.9+)。
"""

import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import svg_geom  # noqa: E402

DEFAULT_ROOT = os.path.normpath(os.path.join(HERE, ".."))

ASSET_PREFIX = "plant_"
CANVAS = (240, 320)
VIEWBOX = "0 0 240 320"
DEFAULT_PETAL = "#FFB3C7"
MAX_LAYER_BYTES = 64 * 1024

EXPECTED_LAYERS = sorted(
    ["bg_plate", "pot_back", "pot_front", "body", "hands_rim", "arms_up", "solo_seed",
     "nub_closed", "nub_lit", "leaf_open", "leaf_folded",
     "face_normal", "face_happy", "face_look_l", "face_look_r", "face_sleep", "face_wow",
     "fx_sparkle", "fx_zzz", "fx_celebrate", "fx_soil_glow", "fx_peek"]
    + ["head_s%d" % n for n in range(2, 10)]
    + ["petal_s%d" % n for n in range(6, 10)]
)
PETAL_LAYERS = ["petal_s%d" % n for n in range(6, 10)]
PEEK_STAGES = ["s%d" % n for n in range(3, 9)]

ALLOWED_ELEMENTS = {
    "svg", "defs", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
    "linearGradient", "radialGradient", "stop",
}
# 理由つきで名指しするもの(許可リストに無い要素は、ここに無くてもすべて失敗)
FORBIDDEN_ELEMENTS = {"filter", "mask", "clipPath", "text", "tspan", "style", "use", "image", "foreignObject",
                      "script", "pattern", "marker", "symbol", "switch", "animate", "animateTransform", "set"}
FORBIDDEN_ATTRIBUTES = {"style", "filter", "mask", "clip-path", "clip", "href", "stop-opacity"}


def local_name(name):
    return name.split("}")[-1]


def check_svg_text(layer, text):
    """1 レイヤーの SVG の検査。問題の文字列のリストを返す。"""
    problems = []
    if len(text.encode("utf-8")) > MAX_LAYER_BYTES:
        problems.append("%s: %d バイト — 上限 %d バイトを超えている" % (layer, len(text.encode("utf-8")), MAX_LAYER_BYTES))
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        return problems + ["%s: XML として不正: %s" % (layer, e)]

    if root.tag != "{http://www.w3.org/2000/svg}svg":
        problems.append("%s: ルート要素が SVG 名前空間の <svg> ではない(%s)" % (layer, root.tag))
    if root.attrib.get("viewBox") != VIEWBOX:
        problems.append("%s: viewBox が %r ではない(%r)" % (layer, VIEWBOX, root.attrib.get("viewBox")))
    for key, want in (("width", CANVAS[0]), ("height", CANVAS[1])):
        if root.attrib.get(key) != str(want):
            problems.append("%s: %s が %d ではない(%r)" % (layer, key, want, root.attrib.get(key)))

    ids = set()
    refs = set()
    for el in root.iter():
        tag = local_name(el.tag)
        if tag in FORBIDDEN_ELEMENTS:
            problems.append("%s: 使えない要素 <%s>" % (layer, tag))
        elif tag not in ALLOWED_ELEMENTS:
            problems.append("%s: 許可していない要素 <%s>" % (layer, tag))
        for attr, value in el.attrib.items():
            name = local_name(attr)
            if name in FORBIDDEN_ATTRIBUTES:
                problems.append("%s: 使えない属性 %s(<%s>)" % (layer, name, tag))
            if name.startswith("on"):
                problems.append("%s: イベント属性 %s(<%s>)" % (layer, name, tag))
            if name == "id":
                ids.add(value)
            for m in re.finditer(r"url\(\s*#?([^)\s]*)\s*\)", value):
                refs.add(m.group(0) if not m.group(0).startswith("url(#") else m.group(1))
    for ref in sorted(refs):
        if ref.startswith("url("):
            problems.append("%s: 外部参照 %s" % (layer, ref))
        elif ref not in ids:
            problems.append("%s: url(#%s) の参照先がファイル内にない" % (layer, ref))
    return problems


def check_petal(layer, text):
    """花の塗りの色の約束と、左右の塗りが重ならないこと。"""
    problems = []
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return problems  # check_svg_text が報告する
    fills = set()
    for el in root.iter():
        if local_name(el.tag) == "path" and el.attrib.get("fill", "none") != "none":
            fills.add(el.attrib.get("fill"))
    if fills != {DEFAULT_PETAL}:
        problems.append("%s: 花の塗りは既定の花色 %s の単色であること(iOS がコード側で着色する)。実際: %s"
                        % (layer, DEFAULT_PETAL, sorted(fills)))
    try:
        area, widest, _ = svg_geom.mirror_overlap(text, axis=CANVAS[0] / 2.0, height=CANVAS[1])
    except ValueError as e:
        problems.append("%s: 塗りを走査できない: %s" % (layer, e))
    else:
        if area > 1e-6:
            problems.append("%s: 左右の花の塗りが重なっている(面積 %.3f、最大幅 %.3f)" % (layer, area, widest))
    return problems


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def check_layers(root):
    problems = []
    svg_dir = os.path.join(root, "svg")
    if not os.path.isdir(svg_dir):
        return ["svg/ がない(python3 tools/gen_layers.py で生成する)"], {}
    files = sorted(os.listdir(svg_dir))
    names = sorted(n[:-4] for n in files if n.endswith(".svg"))
    others = [n for n in files if not n.endswith(".svg")]
    missing = [n for n in EXPECTED_LAYERS if n not in names]
    extra = [n for n in names if n not in EXPECTED_LAYERS]
    if missing:
        problems.append("期待するレイヤーが足りない(%d点): %s" % (len(missing), ", ".join(missing)))
    if extra:
        problems.append("期待していないレイヤーがある: %s" % ", ".join(extra))
    if others:
        problems.append("svg/ に SVG 以外のファイルがある: %s" % ", ".join(others))
    texts = {}
    for name in names:
        text = read(os.path.join(svg_dir, name + ".svg")).decode("utf-8", errors="replace")
        texts[name] = text
        problems += check_svg_text(name, text)
        if name in PETAL_LAYERS:
            problems += check_petal(name, text)
    return problems, texts


def load_json(path, problems, label):
    try:
        return json.loads(read(path).decode("utf-8"))
    except (OSError, ValueError) as e:
        problems.append("%s が読めない: %s" % (label, e))
        return None


def check_catalog(root, texts):
    problems = []
    xc = os.path.join(root, "PlantAssets.xcassets")
    if not os.path.isdir(xc):
        return ["PlantAssets.xcassets がない(python3 tools/build_asset_catalog.py で生成する)"]
    top = load_json(os.path.join(xc, "Contents.json"), problems, "PlantAssets.xcassets/Contents.json")
    if isinstance(top, dict) and "info" not in top:
        problems.append("PlantAssets.xcassets/Contents.json に info がない")
    entries = sorted(os.listdir(xc))
    want = ["%s%s.imageset" % (ASSET_PREFIX, n) for n in EXPECTED_LAYERS]
    have = [e for e in entries if e.endswith(".imageset")]
    for w in want:
        if w not in have:
            problems.append("imageset がない: %s" % w)
    for h in have:
        if h not in want:
            problems.append("期待していない imageset: %s(旧ドット絵が残っていないか)" % h)
    strays = [e for e in entries if not e.endswith(".imageset") and e != "Contents.json"]
    if strays:
        problems.append("PlantAssets.xcassets に想定外のファイルがある: %s" % ", ".join(strays))

    for layer in EXPECTED_LAYERS:
        folder = os.path.join(xc, "%s%s.imageset" % (ASSET_PREFIX, layer))
        if not os.path.isdir(folder):
            continue
        label = "%s%s.imageset" % (ASSET_PREFIX, layer)
        contents = load_json(os.path.join(folder, "Contents.json"), problems, label + "/Contents.json")
        svg_name = "%s%s.svg" % (ASSET_PREFIX, layer)
        if isinstance(contents, dict):
            images = contents.get("images")
            if not (isinstance(images, list) and len(images) == 1
                    and images[0].get("filename") == svg_name and images[0].get("idiom") == "universal"):
                problems.append("%s/Contents.json の images が [{filename: %s, idiom: universal}] ではない" % (label, svg_name))
            props = contents.get("properties") or {}
            if props.get("preserves-vector-representation") is not True:
                problems.append("%s: preserves-vector-representation が true ではない(ベクターのまま拡大できない)" % label)
            if props.get("template-rendering-intent") == "template":
                problems.append("%s: template にしない(元の色のまま入れ、着色はコード側)" % label)
        files = sorted(os.listdir(folder))
        if files != sorted(["Contents.json", svg_name]):
            problems.append("%s の中身が Contents.json と %s だけではない: %s" % (label, svg_name, files))
        svg_path = os.path.join(folder, svg_name)
        if os.path.isfile(svg_path) and layer in texts:
            if read(svg_path) != texts[layer].encode("utf-8"):
                problems.append("%s の SVG が svg/%s.svg と違う(build_asset_catalog.py を実行し直す)" % (label, layer))
    return problems


def check_data_files(root):
    problems = []
    peek = load_json(os.path.join(root, "peek_offsets.json"), problems, "peek_offsets.json")
    if isinstance(peek, dict):
        if sorted(peek) != sorted(PEEK_STAGES):
            problems.append("peek_offsets.json のキーが %s ではない: %s" % (PEEK_STAGES, sorted(peek)))
        for key, value in peek.items():
            if not (isinstance(value, dict) and all(isinstance(value.get(k), (int, float)) for k in ("dx", "dy"))):
                problems.append("peek_offsets.json[%s] が {dx, dy} の数値ではない" % key)
    stacks = load_json(os.path.join(root, "layer_stacks.json"), problems, "layer_stacks.json")
    if isinstance(stacks, dict):
        cases = stacks.get("cases")
        if stacks.get("version") != 1 or not isinstance(cases, list) or not cases:
            problems.append("layer_stacks.json の形が違う(version 1 と cases が要る)")
        else:
            known = set(EXPECTED_LAYERS)
            unknown = set()
            stages = set()
            for case in cases:
                stages.add(case.get("stage"))
                for token in str(case.get("layers", "")).split():
                    name = token.split("|")[0]
                    if name not in known:
                        unknown.add(name)
            if unknown:
                problems.append("layer_stacks.json に存在しないレイヤー名がある: %s" % ", ".join(sorted(unknown)))
            if stages != set(range(10)):
                problems.append("layer_stacks.json が全段階 0〜9 を含んでいない: %s" % sorted(stages))
    return problems


def verify(root=DEFAULT_ROOT):
    problems, texts = check_layers(root)
    problems += check_catalog(root, texts)
    problems += check_data_files(root)
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser(description="植物の SVG レイヤーとアセットカタログの検証")
    ap.add_argument("--root", default=DEFAULT_ROOT, help="products/lien/assets/plant(既定: このスクリプトの親)")
    args = ap.parse_args(argv)
    problems = verify(args.root)
    if problems:
        print("NG: %d 件" % len(problems))
        for p in problems:
            print("  - " + p)
        return 1
    print("OK: レイヤー %d点(viewBox %s・許可した要素だけ)/ imageset %d / 花の塗り %d点は左右が重ならない"
          % (len(EXPECTED_LAYERS), VIEWBOX, len(EXPECTED_LAYERS), len(PETAL_LAYERS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
