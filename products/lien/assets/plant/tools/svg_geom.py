#!/usr/bin/env python3
"""植物レイヤー SVG の塗り(fill)を、外部ツールなしの純 Python で走査する小さな幾何ライブラリ。

用途: 「左右の花の塗り(petal_sN とその左右反転)が1画素も重ならない」ことの検査。
塗りと線を別レイヤーにしても輪郭が透けないための条件で、アート側の約束
(mapping.md「花の塗り」)。以前はヘッドレス Chrome + Pillow でラスタライズして調べていたが、
CI(ubuntu)には Chrome も Pillow も無いので、パスを折れ線にして走査線で塗りの区間を出す方式に置き換えた
(Chrome の描画と面積が 0.2% 以内で一致することを確かめてある)。

対応する構文は、レイヤー生成(gen_layers.py)が実際に出すものだけ:
  - 要素: svg / g / path(defs の中身は読まない)。fill が none のパスは塗りではないので読み飛ばす
  - transform: translate / rotate(中心つきも可)/ scale
  - パス: 絶対座標の M L C Q Z
それ以外が出てきたら黙って読み飛ばさず ValueError にする(アートが別の構文を使い始めたら気づけるように)。

標準ライブラリだけ(Python 3.9+)。
"""

import math
import re
import xml.etree.ElementTree as ET

IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

_TRANSFORM_ITEM = re.compile(r"\s*([A-Za-z]+)\s*\(([^)]*)\)\s*,?\s*")
_PATH_TOKEN = re.compile(r"[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
CUBIC_STEPS = 24
QUAD_STEPS = 16


def matmul(m1, m2):
    """アフィン行列 (a, b, c, d, e, f)(x' = a·x + c·y + e / y' = b·x + d·y + f)の積 m1 · m2。"""
    a1, b1, c1, d1, e1, f1 = m1
    a2, b2, c2, d2, e2, f2 = m2
    return (
        a1 * a2 + c1 * b2,
        b1 * a2 + d1 * b2,
        a1 * c2 + c1 * d2,
        b1 * c2 + d1 * d2,
        a1 * e2 + c1 * f2 + e1,
        b1 * e2 + d1 * f2 + f1,
    )


def apply_matrix(m, p):
    a, b, c, d, e, f = m
    return (a * p[0] + c * p[1] + e, b * p[0] + d * p[1] + f)


def parse_transform(text):
    """SVG の transform 属性(translate / rotate / scale の並び)を行列にする。"""
    m = IDENTITY
    pos = 0
    text = text.strip()
    while pos < len(text):
        item = _TRANSFORM_ITEM.match(text, pos)
        if not item:
            raise ValueError("transform を解釈できません: %r" % text)
        pos = item.end()
        name = item.group(1)
        args = [float(x) for x in re.split(r"[\s,]+", item.group(2).strip()) if x]
        if name == "translate" and len(args) in (1, 2):
            t = (1.0, 0.0, 0.0, 1.0, args[0], args[1] if len(args) == 2 else 0.0)
        elif name == "scale" and len(args) in (1, 2):
            t = (args[0], 0.0, 0.0, args[1] if len(args) == 2 else args[0], 0.0, 0.0)
        elif name == "rotate" and len(args) in (1, 3):
            rad = math.radians(args[0])
            cos_a, sin_a = math.cos(rad), math.sin(rad)
            t = (cos_a, sin_a, -sin_a, cos_a, 0.0, 0.0)
            if len(args) == 3:
                about = (1.0, 0.0, 0.0, 1.0, args[1], args[2])
                back = (1.0, 0.0, 0.0, 1.0, -args[1], -args[2])
                t = matmul(matmul(about, t), back)
        else:
            raise ValueError("未対応の transform です: %s(%s)" % (name, item.group(2)))
        m = matmul(m, t)
    return m


def flatten_path(d, matrix=IDENTITY):
    """パス d(絶対座標の M L C Q Z)を、変換後の折れ線(サブパスごとの点列)にする。"""
    tokens = _PATH_TOKEN.findall(d)
    if "".join(tokens) != re.sub(r"[\s,]+", "", d):
        raise ValueError("パスを解釈できません: %r" % d[:80])
    arity = {"M": 2, "L": 2, "C": 6, "Q": 4, "Z": 0}
    polys, current, pos, start, cmd, i = [], [], None, None, None, 0
    while i < len(tokens):
        if tokens[i].isalpha():
            cmd = tokens[i]
            if cmd not in arity:
                raise ValueError("未対応のパスコマンドです: %s(対応: M L C Q Z の絶対座標のみ)" % cmd)
            i += 1
            if cmd == "Z":
                if current:
                    polys.append(current)
                current, pos = [], start
                continue
        if cmd is None:
            raise ValueError("パスがコマンドで始まっていません: %r" % d[:80])
        n = arity[cmd]
        if n == 0 or i + n > len(tokens) or any(t.isalpha() for t in tokens[i:i + n]):
            raise ValueError("パスの座標が足りません: %r" % d[:80])
        v = [float(t) for t in tokens[i:i + n]]
        i += n
        if cmd == "M":
            if current:
                polys.append(current)
            pos = start = (v[0], v[1])
            current = [apply_matrix(matrix, pos)]
            cmd = "L"  # M の後に続く座標は暗黙の L
        elif cmd == "L":
            pos = (v[0], v[1])
            current.append(apply_matrix(matrix, pos))
        elif cmd == "C":
            p0, p1, p2, p3 = pos, (v[0], v[1]), (v[2], v[3]), (v[4], v[5])
            for k in range(1, CUBIC_STEPS + 1):
                u = k / CUBIC_STEPS
                w = 1.0 - u
                x = w * w * w * p0[0] + 3 * w * w * u * p1[0] + 3 * w * u * u * p2[0] + u * u * u * p3[0]
                y = w * w * w * p0[1] + 3 * w * w * u * p1[1] + 3 * w * u * u * p2[1] + u * u * u * p3[1]
                current.append(apply_matrix(matrix, (x, y)))
            pos = p3
        else:  # Q
            p0, p1, p2 = pos, (v[0], v[1]), (v[2], v[3])
            for k in range(1, QUAD_STEPS + 1):
                u = k / QUAD_STEPS
                w = 1.0 - u
                x = w * w * p0[0] + 2 * w * u * p1[0] + u * u * p2[0]
                y = w * w * p0[1] + 2 * w * u * p1[1] + u * u * p2[1]
                current.append(apply_matrix(matrix, (x, y)))
            pos = p2
    if current:
        polys.append(current)
    return polys


def fill_polygons(svg_text):
    """SVG 全体の塗り(fill が none でない path)を、キャンバス座標の多角形の一覧にする。"""
    root = ET.fromstring(svg_text)
    polys = []

    def walk(el, matrix):
        tag = el.tag.split("}")[-1]
        if tag == "defs":
            return
        if "transform" in el.attrib:
            matrix = matmul(matrix, parse_transform(el.attrib["transform"]))
        if tag == "path":
            if el.attrib.get("fill", "black") != "none":
                polys.extend(flatten_path(el.attrib["d"], matrix))
        elif tag not in ("svg", "g"):
            raise ValueError("塗りの走査が対応していない要素です: <%s>" % tag)
        for child in el:
            walk(child, matrix)

    walk(root, IDENTITY)
    return polys


def spans_at(polys, y):
    """水平線 y が多角形の塗り(非ゼロ巻き数)を横切る区間 [(x0, x1), ...](x の昇順)。"""
    crossings = []
    for poly in polys:
        n = len(poly)
        for k in range(n):
            x0, y0 = poly[k]
            x1, y1 = poly[(k + 1) % n]
            if y0 == y1:
                continue
            if (y0 <= y < y1) or (y1 <= y < y0):
                x = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
                crossings.append((x, 1 if y1 > y0 else -1))
    crossings.sort()
    spans, winding, start = [], 0, 0.0
    for x, direction in crossings:
        before = winding
        winding += direction
        if before == 0 and winding != 0:
            start = x
        elif before != 0 and winding == 0:
            spans.append((start, x))
    return spans


def mirror_overlap(svg_text, axis=120.0, step=0.25, height=320.0):
    """塗りを x=axis で左右反転したものと、元の塗りとの重なりを調べる。

    返り値 (area, widest, min_gap):
      area   : 重なった面積(キャンバス単位²)。0 なら重ならない
      widest : 1本の走査線で重なった最大の幅
      min_gap: 重ならない走査線での、元の塗りと反転した塗りの最小のすき間(重なりがあれば最小のすき間は 0 以下を含まない)
    """
    polys = fill_polygons(svg_text)
    area, widest, min_gap = 0.0, 0.0, float("inf")
    y = step / 2.0
    while y < height:
        spans = spans_at(polys, y)
        mirrored = [(2 * axis - e, 2 * axis - s) for s, e in spans]
        for s1, e1 in spans:
            for s2, e2 in mirrored:
                overlap = min(e1, e2) - max(s1, s2)
                if overlap > 0:
                    area += overlap * step
                    widest = max(widest, overlap)
                else:
                    min_gap = min(min_gap, -overlap)
        y += step
    return area, widest, min_gap
