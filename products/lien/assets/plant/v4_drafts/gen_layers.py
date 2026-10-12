#!/usr/bin/env python3
"""Lien 植物「タネの子」— 成長ルール(docs/GROWTH.md: 10段階・ふたりの葉)用の SVG レイヤー部品ジェネレータ。

全レイヤーは同じ 240×320 キャンバスに最終位置で描き、iOS は重ねるだけ(座標を持たない)。例外は3つ:
  - 右の葉・右の芽・右の花の塗り = 左のレイヤーをキャンバス中央(x=120)で左右反転
  - fx_peek = 段階ごとの「次に伸びる点」へ平行移動(PEEK_POS → peek_offsets.json)
  - bg_plate = ダークモードのときだけ最背面に敷く
重ね順と状態の対応は README.md を正とする。

使ってよい SVG 要素: path / 基本図形 / linearGradient・radialGradient(stop-opacity なし)/ opacity / transform
(filter・mask・clipPath・text・style・use・image・stop-opacity は使わない — 生成時に機械チェック)。
左右の塗り(petal / bud)が重ならないことも、描画した画素で機械チェックする。

使い方: python3 gen_layers.py   # layers/ composed/ svg/ png/ preview_*.png peek_offsets.json
"""

import json
import math
import os
import re
import shutil
import subprocess
from xml.dom import minidom

import gen_v4 as g
from gen_v4 import f, OUT, SW

HERE = os.path.dirname(os.path.abspath(__file__))
LAYER_DIR = os.path.join(HERE, "layers")
COMP_DIR = os.path.join(HERE, "composed")
TMP_DIR = os.path.join(HERE, "_tmp")
W, H = g.W, g.H
CX = g.CX

SW_SMALL = 3.2                # 小さい部品(小葉・つぼみ・冠)の線幅(40pt で塊にならないように)
PETAL_DEFAULT = "#FFB3C7"     # v1.0 の既定の花色。petal_sN はこの単色で塗る(iOS はコード側で着色)
PETAL_COLORS = {"pink": "#FFB3C7", "yellow": "#FFDD73", "blue": "#A9D8FF", "white": "#FFFFFF", "lilac": "#D9C2FF"}
CENTER = "#F6A94E"            # 花芯(どの花色とも見分けられる琥珀色)
ZZZ = "#8798AE"               # すやすやの zzz(ライト/ダーク両方で見える青みグレー)
PLATE = "#FFF7EA"             # ダークモード時の背面プレート

FUTABA_BASE = (CX, 113.0)     # ふたりの葉の付け根(全段階共通)
B = (CX, 112.0)               # 段階2以降の「ふたりの茎」の付け根
TWIST_TOP, TWIST_CROSS = 102.0, 88.0   # ひとひねり(交差)は葉より上の y=88〜102


# ---------------------------------------------------------------------------
# 共通の小道具
# ---------------------------------------------------------------------------
def leaf(x, y, length, angle, side, width_ratio=0.5, sw=SW):
    """付け根 (x, y) から伸びる葉(2トーン+葉脈)。angle=水平からの仰角。side=+1 右 / -1 左。"""
    L = length
    Wd = L * width_ratio
    outer = (f"M0 0 C{f(L * 0.22)} {f(-Wd * 0.95)} {f(L * 0.78)} {f(-Wd * 0.85)} {f(L)} 0 "
             f"C{f(L * 0.74)} {f(Wd * 0.75)} {f(L * 0.24)} {f(Wd * 0.8)} 0 0 Z")
    upper = (f"M0 0 C{f(L * 0.22)} {f(-Wd * 0.95)} {f(L * 0.78)} {f(-Wd * 0.85)} {f(L)} 0 "
             f"C{f(L * 0.7)} 0 {f(L * 0.3)} {f(-Wd * 0.05)} 0 0 Z")
    vein = f"M{f(L * 0.14)} {f(-Wd * 0.02)} Q{f(L * 0.5)} {f(-Wd * 0.08)} {f(L * 0.8)} 0"
    sx = 1 if side > 0 else -1
    tr = f"translate({f(x)} {f(y)}) scale({sx} 1) rotate({f(-angle)})"
    return (f'<g transform="{tr}">'
            f'<path d="{outer}" fill="{g.LEAF}"/>'
            f'<path d="{upper}" fill="{g.LEAF_LIGHT}"/>'
            f'<path d="{vein}" fill="none" stroke="{g.VEIN}" stroke-width="{f(max(1.6, sw * 0.55))}" stroke-linecap="round" opacity="0.9"/>'
            f'<path d="{outer}" fill="none" stroke="{OUT}" stroke-width="{f(sw)}" stroke-linejoin="round"/>'
            f'</g>')


def stem(d, width=5.2, sw=SW):
    return (f'<path d="{d}" fill="none" stroke="{OUT}" stroke-width="{f(width + sw * 2 - 1)}" stroke-linecap="round" stroke-linejoin="round"/>'
            f'<path d="{d}" fill="none" stroke="{g.STEM}" stroke-width="{f(width)}" stroke-linecap="round" stroke-linejoin="round"/>')


def soft_glow(cx, cy, r, color="#FFF3A8", rings=4, top=0.55, rx_scale=1.0):
    """stop-opacity を使わない光: 不透明度の低い同心円を重ねる。"""
    out = ""
    for i in range(rings):
        rr = r * (1 - i / rings)
        op = top / rings
        out += (f'<ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rr * rx_scale)}" ry="{f(rr)}" fill="{color}" '
                f'opacity="{op:.3f}"/>')
    return out


def cubic_d(segs):
    p0 = segs[0][0]
    out = f"M{f(p0[0])} {f(p0[1])}"
    for _, p1, p2, p3 in segs:
        out += f" C{f(p1[0])} {f(p1[1])} {f(p2[0])} {f(p2[1])} {f(p3[0])} {f(p3[1])}"
    return out


def mirror_pt(p):
    return (2 * CX - p[0], p[1])


def mirror_segs(segs):
    return [tuple(mirror_pt(p) for p in s) for s in segs]


MIRROR_OPEN = f'<g transform="translate({f(2 * CX)} 0) scale(-1 1)">'


# ---------------------------------------------------------------------------
# ふたりの葉・段階0の芽(左だけ描く。右は反転)
# ---------------------------------------------------------------------------
def futaba_stem():
    return stem(f"M{f(CX)} {f(g.HEAD_ANCHOR[1] + 4)} L{f(CX)} {f(FUTABA_BASE[1] + 1)}", 5.5)


def leaf_open():
    return futaba_stem() + leaf(FUTABA_BASE[0], FUTABA_BASE[1], 44, 18, -1, 0.5)


def leaf_folded():
    """眠っている葉(就眠運動): 同じ色・同じ長さ。中央脈で2つ折りに合わせた、ふっくらした形で、
    外側へ 46° に立てる(中央の頭の植物を隠さない)。しおれ・垂れ・変色はしない。"""
    L, Wd = 44.0, 44.0 * 0.38
    outer = (f"M0 0 C{f(L * 0.2)} {f(-Wd * 0.9)} {f(L * 0.75)} {f(-Wd * 0.85)} {f(L)} 0 "
             f"C{f(L * 0.75)} {f(Wd * 0.55)} {f(L * 0.2)} {f(Wd * 0.6)} 0 0 Z")
    light = (f"M{f(L * 0.06)} {f(-Wd * 0.1)} C{f(L * 0.24)} {f(-Wd * 0.8)} {f(L * 0.72)} {f(-Wd * 0.74)} {f(L * 0.95)} {f(-Wd * 0.04)} "
             f"C{f(L * 0.7)} {f(-Wd * 0.18)} {f(L * 0.3)} {f(-Wd * 0.2)} {f(L * 0.06)} {f(-Wd * 0.1)} Z")
    fold = f"M{f(L * 0.05)} {f(Wd * 0.02)} C{f(L * 0.3)} {f(Wd * 0.12)} {f(L * 0.7)} {f(Wd * 0.12)} {f(L * 0.97)} {f(Wd * 0.01)}"
    x, y = FUTABA_BASE
    tr = f"translate({f(x)} {f(y)}) scale(-1 1) rotate(-46)"
    return (futaba_stem() + f'<g transform="{tr}">'
            f'<path d="{outer}" fill="{g.LEAF}"/>'
            f'<path d="{light}" fill="{g.LEAF_LIGHT}"/>'
            f'<path d="{fold}" fill="none" stroke="{g.LEAF_DARK}" stroke-width="2.6" stroke-linecap="round" opacity="0.85"/>'
            f'<path d="{outer}" fill="none" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'</g>')


NUB_POS = (CX - 10, 135.0)


def nub_closed():
    """段階0の芽(閉じている): 小さなしずく形。"""
    x, y = NUB_POS
    return (f'<path d="M{f(x)} {f(y - 15)} C{f(x + 7)} {f(y - 9)} {f(x + 8)} {f(y - 1)} {f(x + 5)} {f(y + 3)} '
            f'C{f(x + 2)} {f(y + 6)} {f(x - 2)} {f(y + 6)} {f(x - 5)} {f(y + 3)} C{f(x - 8)} {f(y - 1)} {f(x - 7)} {f(y - 9)} {f(x)} {f(y - 15)} Z" '
            f'fill="{g.LEAF}" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<path d="M{f(x - 1.5)} {f(y - 10)} C{f(x - 4)} {f(y - 6)} {f(x - 4)} {f(y - 2)} {f(x - 3)} {f(y)}" fill="none" '
            f'stroke="{g.LEAF_LIGHT}" stroke-width="2.6" stroke-linecap="round"/>')


def nub_lit():
    """段階0の芽(光る=その人がチェックインした): 背が伸びて先がふたつにひらく(形で区別)+光。"""
    x, y = NUB_POS
    return (soft_glow(x, y - 16, 15, rings=4, top=0.8)
            + stem(f"M{f(x)} {f(y + 2)} L{f(x)} {f(y - 10)}", 4.2, SW_SMALL)
            + leaf(x, y - 10, 12, 52, -1, 0.62, SW_SMALL) + leaf(x, y - 10, 12, 52, +1, 0.62, SW_SMALL)
            + g.sparkle(x - 13, y - 27, 5.5, g.SPARK))


# ---------------------------------------------------------------------------
# 頭の植物(段階2〜9)。「ふたつ」が主役。葉より上に重ねる
# ---------------------------------------------------------------------------
def twin_left(stage):
    """左の茎のセグメント列。右は鏡像。"""
    bx, by = B
    if stage == 2:   # めばえ: 2本の小さな芽。先の丸い葉どうしが寄って、ハートの上の丸みになる
        return [(B, (bx - 4, by - 8), (bx - 14, by - 14), (bx - 12, by - 26))]
    if stage == 3:   # わかば: V字に伸び、それぞれの先に小さな葉が1対
        return [(B, (bx - 6, by - 10), (bx - 20, by - 26), (bx - 14, by - 44))]
    trunk = (B, (bx, by - 3), (bx, by - 7), (bx, TWIST_TOP))
    twist = ((bx, TWIST_TOP), (bx + 8, TWIST_TOP - 4), (bx + 8, TWIST_CROSS + 4), (bx, TWIST_CROSS))
    c = (bx, TWIST_CROSS)
    if stage == 4:   # よりそい: ひとひねりして伸び、先端どうしが触れ合う
        return [trunk, twist, (c, (bx - 8, c[1] - 8), (bx - 22, c[1] - 22), (bx - 7, c[1] - 36))]
    if stage in (5, 6, 7):  # つぼみ / いろづき / ほころび
        return [trunk, twist, (c, (bx - 10, c[1] - 6), (bx - 44, c[1] - 14), (bx - 27, c[1] - 32))]
    # 8 ふたりざき / 9 みのり: 2本の茎のすき間がハート形
    return [trunk, twist, (c, (bx - 10, c[1] - 6), (bx - 56, c[1] - 16), (bx - 29, c[1] - 36))]


def _bud(x, y, angle, scale, opened):
    """つぼみ。返り値 (petal_fill, line_art)。opened: 0=緑 / 1=先が色づく / 2=花びらがのぞく(冠)"""
    s = scale
    tr = f"translate({f(x)} {f(y)}) rotate({f(angle)}) scale({f(s)})"
    sw = f(SW_SMALL / s)
    body = "M0 -22 C10 -14 13 -3 10 4 C7 10 -7 10 -10 4 C-13 -3 -10 -14 0 -22 Z"
    sepal = "M-11 3 Q-7 -6 0 1 Q7 -6 11 3 Q7 12 0 11 Q-7 12 -11 3 Z"
    if opened == 0:
        art = (f'<g transform="{tr}"><path d="{body}" fill="{g.LEAF_LIGHT}" stroke="{OUT}" stroke-width="{sw}" stroke-linejoin="round"/>'
               f'<path d="M-5 -14 Q-1 -4 0 6 M5 -14 Q1 -4 0 6" fill="none" stroke="{g.LEAF_DARK}" stroke-width="{f(1.8 / s)}" opacity="0.6"/>'
               f'<path d="M1 -17 C5 -12 6 -6 5 -2" fill="none" stroke="#FFFFFF" stroke-width="{f(2.6 / s)}" stroke-linecap="round" opacity="0.6"/>'
               f'<path d="{sepal}" fill="{g.LEAF}" stroke="{OUT}" stroke-width="{sw}" stroke-linejoin="round"/></g>')
        return "", art
    if opened == 1:
        # いろづき: 上半分(4〜5割)が花の色。割れ目の線で「ひらきかけ」を形でも示す
        fill = f'<g transform="{tr}"><path d="{body}" fill="{PETAL_DEFAULT}"/></g>'
        green = "M-11.8 1 C-12.4 -3 -12 -6 -10.6 -8 Q0 -3 10.6 -8 C12 -6 12.4 -3 11.8 1 C9 9 -9 9 -11.8 1 Z"
        art = (f'<g transform="{tr}"><path d="{green}" fill="{g.LEAF_LIGHT}"/>'
               f'<path d="M0 -21 Q-2 -14 -4 -7 M0 -21 Q2 -14 4 -7" fill="none" stroke="{OUT}" stroke-width="{f(1.8 / s)}" stroke-linecap="round" opacity="0.7"/>'
               f'<path d="{body}" fill="none" stroke="{OUT}" stroke-width="{sw}" stroke-linejoin="round"/>'
               f'<path d="M3 -16 C6 -12 7 -8 6 -5" fill="none" stroke="#FFFFFF" stroke-width="{f(2.6 / s)}" stroke-linecap="round" opacity="0.7"/>'
               f'<path d="{sepal}" fill="{g.LEAF}" stroke="{OUT}" stroke-width="{sw}" stroke-linejoin="round"/></g>')
        return fill, art
    crown = ("M-11 -2 C-15 -12 -15 -23 -9 -25 C-6 -26 -4 -22 -3 -19 "
             "C-3 -26 3 -26 3 -19 C4 -22 6 -26 9 -25 C15 -23 15 -12 11 -2 Z")
    fill = f'<g transform="{tr}"><path d="{crown}" fill="{PETAL_DEFAULT}"/></g>'
    cup = "M-12 -6 C-12 4 -6 9 0 9 C6 9 12 4 12 -6 Q6 -2 0 -7 Q-6 -2 -12 -6 Z"
    art = (f'<g transform="{tr}">'
           f'<path d="M-3 -18 Q-3.5 -10 -4 -4 M3 -18 Q3.5 -10 4 -4" fill="none" stroke="{OUT}" stroke-width="{f(1.8 / s)}" stroke-linecap="round" opacity="0.8"/>'
           f'<path d="M-8 -20 C-10 -16 -10 -12 -9 -9" fill="none" stroke="#FFFFFF" stroke-width="{f(2.6 / s)}" stroke-linecap="round" opacity="0.6"/>'
           f'<path d="{crown}" fill="none" stroke="{OUT}" stroke-width="{sw}" stroke-linejoin="round"/>'
           f'<path d="{cup}" fill="{g.LEAF_LIGHT}" stroke="{OUT}" stroke-width="{sw}" stroke-linejoin="round"/>'
           f'<path d="{sepal}" transform="translate(0 3)" fill="{g.LEAF}" stroke="{OUT}" stroke-width="{sw}" stroke-linejoin="round"/></g>')
    return fill, art


# --- 花(5弁)。花びらの和集合の外形線+仕切り線(塗りと線を別レイヤーにしても輪郭が透けない)
def _ray_ellipse(theta, cx, cy, a, b, phi):
    dx, dy = math.cos(theta), math.sin(theta)
    cp, sp = math.cos(-phi), math.sin(-phi)
    ox, oy = (-cx) * cp - (-cy) * sp, (-cx) * sp + (-cy) * cp
    vx, vy = dx * cp - dy * sp, dx * sp + dy * cp
    A = (vx / a) ** 2 + (vy / b) ** 2
    Bq = 2 * (ox * vx / a ** 2 + oy * vy / b ** 2)
    C = (ox / a) ** 2 + (oy / b) ** 2 - 1
    disc = Bq * Bq - 4 * A * C
    if disc < 0:
        return 0.0
    return max((-Bq + math.sqrt(disc)) / (2 * A), 0.0)


def flower_geom(r, petals=5):
    pr, dist = r * 0.52, r * 0.5
    out = []
    for k in range(petals):
        a = -90 + k * 360 / petals
        out.append((dist * math.cos(math.radians(a)), dist * math.sin(math.radians(a)), pr * 0.92, pr * 1.08,
                    math.radians(a + 90), a))
    return out


def flower_radius(theta, ells):
    return max(_ray_ellipse(theta, cx, cy, ea, eb, ph) for cx, cy, ea, eb, ph, _ in ells)


def flower_outline_d(r, petals=5, n=150):
    ells = flower_geom(r, petals)
    pts = []
    for i in range(n):
        th = 2 * math.pi * i / n
        rr = flower_radius(th, ells)
        pts.append((rr * math.cos(th), rr * math.sin(th)))
    return "M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z"


def _flower(x, y, r, angle, petals=5):
    ells = flower_geom(r, petals)
    outline = flower_outline_d(r, petals)
    tr = f"translate({f(x)} {f(y)}) rotate({f(angle)})"
    fill = f'<g transform="{tr}"><path d="{outline}" fill="{PETAL_DEFAULT}"/></g>'
    art = f'<g transform="{tr}">'
    for cx, cy, ea, eb, ph, a in ells:
        hx, hy = cx * 0.82, cy * 0.82
        art += (f'<ellipse cx="{f(hx)}" cy="{f(hy)}" rx="{f(ea * 0.5)}" ry="{f(eb * 0.6)}" '
                f'transform="rotate({f(a + 90)} {f(hx)} {f(hy)})" fill="#FFFFFF" opacity="0.42"/>')
    for k in range(petals):
        th = math.radians(-90 + (k + 0.5) * 360 / petals)
        rv = flower_radius(th, ells)
        r0 = r * 0.36
        art += (f'<path d="M{f(r0 * math.cos(th))} {f(r0 * math.sin(th))} L{f(rv * 0.97 * math.cos(th))} {f(rv * 0.97 * math.sin(th))}" '
                f'stroke="{OUT}" stroke-width="{f(SW * 0.6)}" stroke-linecap="round" opacity="0.85"/>')
    art += f'<path d="{outline}" fill="none" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
    art += f'<circle cx="0" cy="0" r="{f(r * 0.36)}" fill="{CENTER}" stroke="{OUT}" stroke-width="{SW}"/>'
    art += f'<circle cx="{f(-r * 0.1)}" cy="{f(-r * 0.12)}" r="{f(r * 0.12)}" fill="#FFFFFF" opacity="0.75"/>'
    art += '</g>'
    return fill, art


def flower_outer_r(r, angle_world, fangle, petals=5):
    return flower_radius(math.radians(angle_world - fangle), flower_geom(r, petals))


def split_bezier(p0, p1, p2, p3, t):
    def lerp(a, b):
        return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    a1, b1, c1 = lerp(p0, p1), lerp(p1, p2), lerp(p2, p3)
    a2, b2 = lerp(a1, b1), lerp(b1, c1)
    return (p0, a1, a2, lerp(a2, b2))


def trim_to_flower(seg, fx, fy, r, fangle):
    """茎の最後のセグメントを、花の外形の輪郭線の下で止める(花の塗りの上に茎が出ないように)。"""
    t = 1.0
    while t > 0.2:
        px, py = g.bez(*seg, t)
        ang = math.degrees(math.atan2(py - fy, px - fx))
        if math.hypot(px - fx, py - fy) >= flower_outer_r(r, ang, fangle) - 1.5:
            break
        t -= 0.01
    return split_bezier(*seg, t)


def heart_seed(x, y, s):
    """みのり: 2本の茎のすき間に光る、ハート形の「ふたりのタネ」(光は茎より下に描く)。"""
    d = (f"M{f(x)} {f(y + 9 * s)} C{f(x - 15 * s)} {f(y - 1 * s)} {f(x - 11 * s)} {f(y - 14 * s)} {f(x - 4 * s)} {f(y - 12 * s)} "
         f"C{f(x - 1 * s)} {f(y - 11 * s)} {f(x)} {f(y - 8 * s)} {f(x)} {f(y - 7 * s)} "
         f"C{f(x)} {f(y - 8 * s)} {f(x + 1 * s)} {f(y - 11 * s)} {f(x + 4 * s)} {f(y - 12 * s)} "
         f"C{f(x + 11 * s)} {f(y - 14 * s)} {f(x + 15 * s)} {f(y - 1 * s)} {f(x)} {f(y + 9 * s)} Z")
    seed = (f'<defs><linearGradient id="gSeed" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="#FFE38A"/><stop offset="1" stop-color="#F5B848"/></linearGradient></defs>'
            f'<path d="{d}" fill="url(#gSeed)" stroke="{OUT}" stroke-width="{SW_SMALL}" stroke-linejoin="round"/>'
            f'<ellipse cx="{f(x - 5 * s)}" cy="{f(y - 6 * s)}" rx="{f(2.6 * s)}" ry="{f(1.8 * s)}" '
            f'transform="rotate(-30 {f(x - 5 * s)} {f(y - 6 * s)})" fill="#FFFFFF" opacity="0.9"/>')
    glow = soft_glow(x, y - 2 * s, 22 * s, rings=4, top=0.7)
    return glow, seed


SEED_POS = (CX, 79.0, 0.82)


def head(stage):
    """段階 stage の頭の植物。返り値 (head_svg, petal_left_svg)。
    head は左右両方を含む。petal は左の花・つぼみだけ(右は iOS が左右反転して重ねる=左右で別の色にできる)。"""
    left = twin_left(stage)
    right = mirror_segs(left)
    art, petal = "", ""
    w = 4.4 if stage == 2 else 5.0
    small_sw = SW_SMALL

    if stage in (8, 9):
        fr = 26 if stage == 8 else 28
        fpos = []
        stems_out = []
        for sx, sg in ((-1, left), (1, right)):
            tx, ty = sg[-1][3]
            fx, fy = CX + sx * 30.5, ty - 8
            fang = sx * 14
            fpos.append((sx, fx, fy, fang))
            stems_out.append(sg[:-1] + [trim_to_flower(sg[-1], fx, fy, fr, fang)])
        if stage == 9:
            glow, seed = heart_seed(*SEED_POS)
            art += glow
        art += stem(cubic_d(stems_out[0]), w) + stem(cubic_d(stems_out[1]), w)
        ts = (0.36, 0.64) if stage == 8 else (0.26, 0.5, 0.74)
        for t in ts:
            for sx, sg in ((-1, left), (1, right)):
                lx, ly = g.bez(*sg[-1], t)
                art += leaf(lx, ly, 20 if t < 0.6 else 17, 26, sx, 0.5, small_sw)
        if stage == 9:
            art += seed
        for sx, fx, fy, fang in fpos:
            pf, pa = _flower(fx, fy, fr, fang)
            if sx < 0:
                petal += pf
            art += pa
        return art, petal

    art += stem(cubic_d(left), w) + stem(cubic_d(right), w)
    if stage == 2:
        for sx, sg in ((-1, left), (1, right)):
            tx, ty = sg[-1][3]
            art += leaf(tx, ty + 1, 18, 58, -sx, 0.74, small_sw)
        return art, petal
    if stage == 3:
        for sg in (left, right):
            tx, ty = sg[-1][3]
            art += leaf(tx, ty + 1, 19, 30, -1, 0.55, small_sw) + leaf(tx, ty + 1, 19, 30, +1, 0.55, small_sw)
        return art, petal
    # 4〜7: 茎の途中の葉
    ts = (0.5,) if stage == 4 else (0.34, 0.62)
    for t in ts:
        for sx, sg in ((-1, left), (1, right)):
            lx, ly = g.bez(*sg[-1], t)
            art += leaf(lx, ly, 18, 26, sx, 0.5, small_sw)
    if stage == 4:
        # 先端の小さな葉が内側で触れ合う(寄り添い)
        for sx, sg in ((-1, left), (1, right)):
            tx, ty = sg[-1][3]
            art += leaf(tx, ty + 1, 17, 44, -sx, 0.55, small_sw) + leaf(tx, ty + 1, 15, 60, sx, 0.55, small_sw)
        return art, petal
    opened = {5: 0, 6: 1, 7: 2}[stage]
    scale = {5: 1.1, 6: 1.3, 7: 1.35}[stage]
    for sx, sg in ((-1, left), (1, right)):
        tx, ty = sg[-1][3]
        pf, pa = _bud(tx, ty + 2, -sx * 10, scale, opened)
        if sx < 0:
            petal += pf
        art += pa
    return art, petal


# ---------------------------------------------------------------------------
# 表情(6種)
# ---------------------------------------------------------------------------
def face_look(dx):
    """ひらいた葉の方をうれしそうに見る。dx<0 で左(自分の葉)、dx>0 で右(相手の葉)。"""
    out = g.blush(0, 0.7)
    for sx in (-1, 1):
        x = CX + sx * g.EYE_DX
        ex, ey = x + dx * 6.5, g.EYE_Y - 4
        out += f'<ellipse cx="{f(ex)}" cy="{f(ey)}" rx="7.2" ry="9.4" fill="{g.EYE}"/>'
        out += f'<circle cx="{f(ex + dx * 2.4)}" cy="{f(ey - 3.8)}" r="2.9" fill="#FFFFFF"/>'
        out += f'<circle cx="{f(ex - dx * 2.2)}" cy="{f(ey + 3.6)}" r="1.1" fill="#FFFFFF" opacity="0.8"/>'
    y, mx = 196.0, CX + dx * 4
    out += (f'<path d="M{f(mx - 8.5)} {f(y)} Q{f(mx)} {f(y + 10)} {f(mx + 8.5)} {f(y)}" fill="none" '
            f'stroke="{g.EYE}" stroke-width="3.6" stroke-linecap="round"/>')
    return out


def face_wow():
    out = g.blush(0, 0.8)
    for sx in (-1, 1):
        x, y = CX + sx * g.EYE_DX, g.EYE_Y - 1
        out += f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="8.4" ry="10.2" fill="{g.EYE}"/>'
        out += f'<circle cx="{f(x + 2.6)}" cy="{f(y - 4)}" r="3.4" fill="#FFFFFF"/>'
        out += f'<circle cx="{f(x - 3)}" cy="{f(y + 4.2)}" r="1.6" fill="#FFFFFF"/>'
    out += (f'<ellipse cx="{f(CX)}" cy="198" rx="5.4" ry="6.2" fill="#B5473F" stroke="{g.EYE}" stroke-width="3"/>'
            f'<ellipse cx="{f(CX)}" cy="200.5" rx="3" ry="2.2" fill="#FF8C8C"/>')
    return out


FACES = {
    "face_normal": lambda: g.face("normal"),
    "face_happy": lambda: g.face("happy"),
    "face_look_l": lambda: face_look(-1),
    "face_look_r": lambda: face_look(+1),
    "face_sleep": lambda: g.face("sleep"),
    "face_wow": face_wow,
}


# ---------------------------------------------------------------------------
# 体まわり・鉢・背面
# ---------------------------------------------------------------------------
def pot_back():
    """鉢の口の土+地面の影(影もレイヤーに含める=iOS とプレビューを一致させる)。"""
    return g.ground_shadow() + g.soil_in_pot()


def arms_up():
    """喜び: 体の横から出る太く短いミトン型の腕(体の背後に描く)。"""
    out = ""
    for sx in (-1, 1):
        d = f"M{f(CX + sx * 62)} 210 Q{f(CX + sx * 80)} 204 {f(CX + sx * 84)} 186"
        out += (f'<path d="{d}" fill="none" stroke="{OUT}" stroke-width="{f(19 + SW * 2 - 1)}" stroke-linecap="round"/>'
                f'<path d="{d}" fill="none" stroke="{g.BODY_MID}" stroke-width="19" stroke-linecap="round"/>'
                f'<ellipse cx="{f(CX + sx * 82)}" cy="186" rx="3.4" ry="2.2" fill="#FFFFFF" opacity="0.7"/>')
    return out


def solo_seed():
    """ソロ: 鉢の土の中で眠るタネの子(顔が少しのぞく)。clipPath を使わず、縮小した体の下端を鉢で隠す。"""
    return (f'<g transform="translate(0 21) translate({f(CX)} 232) scale(0.84) translate({f(-CX)} -232)">'
            f'{g.body()}{g.face("sleep")}</g>')


def bg_plate():
    """ダークモードのときだけ最背面に敷くクリーム色のプレート(こげ茶の輪郭を暗い背景に沈ませない)。"""
    return f'<rect x="4" y="4" width="232" height="312" rx="44" ry="44" fill="{PLATE}"/>'


# ---------------------------------------------------------------------------
# 効果
# ---------------------------------------------------------------------------
def fx_sparkle():
    return (g.sparkle(30, 60, 11) + g.sparkle(212, 84, 13) + g.sparkle(226, 250, 7, g.SPARK_LIGHT)
            + g.sparkle(14, 244, 8, g.SPARK_LIGHT)
            + f'<circle cx="52" cy="100" r="3" fill="{g.SPARK}"/><circle cx="194" cy="50" r="3" fill="{g.SPARK}"/>')


def fx_zzz():
    def z(x, y, size, op):
        d = f"M{f(x)} {f(y)} L{f(x + size)} {f(y)} L{f(x)} {f(y + size * 1.1)} L{f(x + size)} {f(y + size * 1.1)}"
        return (f'<path d="{d}" fill="none" stroke="{ZZZ}" stroke-width="3.6" stroke-linecap="round" '
                f'stroke-linejoin="round" opacity="{op}"/>')
    return z(184, 124, 13, 1) + z(204, 100, 9, 0.8)


def fx_soil_glow():
    """ソロで自分がチェックインした: 土がほのかに光る(solo_seed の背後に置く)。"""
    return (soft_glow(CX, 206, 58, rings=5, top=0.85, rx_scale=1.8)
            + g.sparkle(40, 176, 7) + g.sparkle(204, 168, 9) + g.sparkle(178, 146, 5, g.SPARK_LIGHT))


def fx_celebrate():
    """段階アップ: 外周の紙ふぶきとキラキラ(キャラには重ねない)。"""
    out = ""
    conf = [(22, 40, "#FF9DB5", 20), (60, 18, "#8FD6FF", -15), (182, 22, "#FFD45E", 35), (220, 58, "#A8E07E", -30),
            (16, 120, "#FFD45E", 10), (226, 140, "#FF9DB5", -20), (28, 250, "#8FD6FF", 25), (214, 262, "#A8E07E", -10),
            (100, 10, "#A8E07E", 45), (148, 12, "#FF9DB5", -40)]
    for x, y, c, a in conf:
        out += (f'<rect x="{f(x - 5)}" y="{f(y - 3)}" width="10" height="6" rx="2" ry="2" fill="{c}" '
                f'transform="rotate({a} {x} {y})" stroke="{OUT}" stroke-width="1.6"/>')
    return (out + g.sparkle(44, 84, 10) + g.sparkle(198, 108, 12) + g.sparkle(26, 176, 8, g.SPARK_LIGHT)
            + g.sparkle(216, 196, 9, g.SPARK_LIGHT) + g.sparkle(70, 36, 6) + g.sparkle(176, 30, 7))


PEEK_CENTER = (CX, 160.0)
# のぞき(光る小さな芽)を出す位置 = 次の段階で何かが出てくる場所(左右対称の中央)
PEEK_POS = {"s3": (CX, 76.0), "s4": (CX, 34.0), "s5": (CX, 52.0), "s6": (CX, 52.0), "s7": (CX, 52.0), "s8": (CX, 76.0)}


def fx_peek():
    x, y = PEEK_CENTER
    return (soft_glow(x, y - 2, 13, rings=4, top=0.85)
            + f'<path d="M{f(x)} {f(y - 9)} C{f(x + 5)} {f(y - 5)} {f(x + 6)} {f(y + 1)} {f(x + 3.5)} {f(y + 3.5)} '
              f'C{f(x + 1.5)} {f(y + 5.5)} {f(x - 1.5)} {f(y + 5.5)} {f(x - 3.5)} {f(y + 3.5)} C{f(x - 6)} {f(y + 1)} {f(x - 5)} {f(y - 5)} {f(x)} {f(y - 9)} Z" '
              f'fill="{g.LEAF_LIGHT}" stroke="{OUT}" stroke-width="{SW_SMALL}" stroke-linejoin="round"/>'
            + g.sparkle(x + 10, y - 10, 4.5, g.SPARK))


def peek_offsets():
    return {k: {"dx": round(px - PEEK_CENTER[0], 1), "dy": round(py - PEEK_CENTER[1], 1)} for k, (px, py) in PEEK_POS.items()}


# ---------------------------------------------------------------------------
# レイヤー定義・合成
# ---------------------------------------------------------------------------
def layer_specs():
    specs = {
        "bg_plate": bg_plate, "pot_back": pot_back, "pot_front": g.pot, "body": g.body,
        "hands_rim": g.hands_on_rim, "arms_up": arms_up, "solo_seed": solo_seed,
        "nub_closed": nub_closed, "nub_lit": nub_lit, "leaf_open": leaf_open, "leaf_folded": leaf_folded,
        "fx_sparkle": fx_sparkle, "fx_zzz": fx_zzz, "fx_celebrate": fx_celebrate,
        "fx_soil_glow": fx_soil_glow, "fx_peek": fx_peek,
    }
    specs.update(FACES)
    for st in range(2, 10):
        specs[f"head_s{st}"] = (lambda st=st: head(st)[0])
        if head(st)[1]:
            specs[f"petal_s{st}"] = (lambda st=st: head(st)[1])
    return specs


def wrap(inner):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">'
            f'{g.defs()}{inner}</svg>\n')


FORBIDDEN = re.compile(r"<(filter|mask|clipPath|text|style|use|image)\b|stop-opacity")

LAYERS = {}


def tint(svg_fragment, color):
    return svg_fragment.replace(PETAL_DEFAULT, color)


def compose(stage, me="open", partner="open", face="face_normal", fx=(), solo=False,
            color_me=PETAL_DEFAULT, color_partner=PETAL_DEFAULT, soil_glow=False, peek=False, dark=False):
    """プレビュー用の合成。iOS 側(PlantLayers)と同じ重ね順(README.md)。"""
    L = LAYERS
    parts = [L["bg_plate"]] if dark else []
    parts.append(L["pot_back"])
    if solo:
        if soil_glow:
            parts.append(L["fx_soil_glow"])
        parts += [L["solo_seed"], L["pot_front"], L["fx_zzz"]]
        return wrap("".join(parts))
    if stage == 0:
        left = L["nub_lit"] if me == "open" else L["nub_closed"]
        right = L["nub_lit"] if partner == "open" else L["nub_closed"]
    else:
        left = L["leaf_open"] if me == "open" else L["leaf_folded"]
        right = L["leaf_open"] if partner == "open" else L["leaf_folded"]
    parts += [left, MIRROR_OPEN + right + "</g>"]
    if f"petal_s{stage}" in L:
        parts.append(tint(L[f"petal_s{stage}"], color_me))
        parts.append(MIRROR_OPEN + tint(L[f"petal_s{stage}"], color_partner) + "</g>")
    if stage >= 2:
        parts.append(L[f"head_s{stage}"])
    happy = face in ("face_happy", "face_wow")
    if happy:
        parts.append(L["arms_up"])
    parts += [L["body"], L[face], L["pot_front"]]
    if not happy:
        parts.append(L["hands_rim"])
    if peek and f"s{stage}" in PEEK_POS:
        px, py = PEEK_POS[f"s{stage}"]
        parts.append(f'<g transform="translate({f(px - PEEK_CENTER[0])} {f(py - PEEK_CENTER[1])})">{L["fx_peek"]}</g>')
    for name in fx:
        parts.append(L[name])
    return wrap("".join(parts))


def render(svg_path, png_path, scale=2):
    g.render_png(svg_path, png_path, scale)


def check_petal_overlap():
    """左右の花の塗りが重ならないこと(塗りと線を分けても輪郭が透けない条件)を画素で確認する。"""
    from PIL import Image, ImageChops
    bad = []
    for st in range(2, 10):
        name = f"petal_s{st}"
        if name not in LAYERS:
            continue
        sp = os.path.join(LAYER_DIR, f"{name}.svg")
        pp = os.path.join(TMP_DIR, f"{name}.png")
        render(sp, pp, 2)
        a = Image.open(pp).convert("RGBA").split()[3].point(lambda v: 255 if v > 24 else 0)
        m = a.transpose(Image.FLIP_LEFT_RIGHT)
        overlap = ImageChops.multiply(a, m)
        n = sum(1 for v in overlap.getdata() if v)
        if n:
            bad.append((name, n))
    return bad


def sheet(cells, path, cols, cell_w=240, cell_h=320, title=None, bg="#FFF7EA", page="#F3E9DA", label_color="#8A6F5E"):
    pad, lab = 10, 30
    rows = math.ceil(len(cells) / cols)
    top = 44 if title else 0
    sw, sh = cols * (cell_w + pad) + pad, top + rows * (cell_h + lab + pad) + pad
    html = ""
    for i, (src, label) in enumerate(cells):
        x = pad + (i % cols) * (cell_w + pad)
        y = top + pad + (i // cols) * (cell_h + lab + pad)
        html += (f'<div style="position:absolute;left:{x}px;top:{y}px;width:{cell_w}px;height:{cell_h + lab}px;'
                 f'background:{bg};border-radius:18px"><img src="{src}" style="width:{cell_w}px;height:{cell_h}px;display:block">'
                 f'<div style="font:600 14px -apple-system,Hiragino Sans,Helvetica;color:{label_color};text-align:center">{label}</div></div>')
    if title:
        html = (f'<div style="position:absolute;left:{pad + 6}px;top:12px;font:700 20px -apple-system,Hiragino Sans,Helvetica;'
                f'color:{label_color}">{title}</div>') + html
    doc = (f'<!doctype html><html><head><meta charset="utf-8"></head>'
           f'<body style="margin:0;background:{page};width:{sw}px;height:{sh}px;position:relative">{html}</body></html>')
    hp = os.path.join(HERE, "_sheet.html")
    with open(hp, "w") as fh:
        fh.write(doc)
    subprocess.run([g.CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                    f"--window-size={sw},{sh}", "--force-device-scale-factor=1", f"--screenshot={path}", "file://" + hp],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.remove(hp)


STAGE_NAMES = ["たね", "ふたば", "めばえ", "わかば", "よりそい", "つぼみ", "いろづき", "ほころび", "ふたりざき", "みのり"]
STAGE_AT = [0, 1, 3, 7, 14, 21, 30, 45, 66, 100]
STATES = [("none", "folded", "folded", "face_normal", ()), ("me", "open", "folded", "face_look_l", ()),
          ("partner", "folded", "open", "face_look_r", ()), ("both", "open", "open", "face_happy", ("fx_sparkle",))]
STATE_LABEL = {"none": "ふたりともまだ", "me": "自分だけ完了", "partner": "相手だけ完了", "both": "ふたりそろった"}


def out(name, svg_text):
    p = os.path.join(COMP_DIR, f"{name}.svg")
    with open(p, "w") as fh:
        fh.write(svg_text)
    return f"composed/{name}.svg"


def build_previews():
    # 1) ソロ+10段階(ふたりの葉は両方ひらいた状態)
    cells = [(out("solo", compose(0, solo=True)), "ソロ(ペア前)")]
    for st in range(10):
        cells.append((out(f"growth_s{st}", compose(st, "open", "open", "face_normal")), f"{st} {STAGE_NAMES[st]}({STAGE_AT[st]}回)"))
    sheet(cells, os.path.join(HERE, "preview_growth.png"), cols=6, title="成長10段階(ふたりの葉は両方ひらいた状態)")

    # 2) 全段階 × 葉の4通り(毎朝の既定=ふたりともまだ を含む)
    cells = []
    for st in range(10):
        for key, me, pa, face, fx in STATES:
            cells.append((out(f"state_s{st}_{key}", compose(st, me, pa, face, fx)), f"{st} {STAGE_NAMES[st]}: {STATE_LABEL[key]}"))
    sheet(cells, os.path.join(HERE, "preview_states.png"), cols=8, cell_w=180, cell_h=240,
          title="全段階 × 今日の2人の状態(左の葉=自分 / 右の葉=相手。朝は「ふたりともまだ」から始まる)")

    # 3) 表情6種+ソロ+演出+のぞき
    cells = [
        (out("face_normal_s3", compose(3, "folded", "folded", "face_normal")), "ふつう"),
        (out("face_happy_s3", compose(3, "open", "open", "face_happy", ("fx_sparkle",))), "にっこり(ふたりそろった)"),
        (out("face_look_l_s3", compose(3, "open", "folded", "face_look_l")), "自分の葉を見る"),
        (out("face_look_r_s3", compose(3, "folded", "open", "face_look_r")), "相手の葉を見る"),
        (out("face_sleep_s3", compose(3, "folded", "folded", "face_sleep", ("fx_zzz",))), "すやすや"),
        (out("face_wow_s3", compose(3, "open", "open", "face_wow", ("fx_celebrate",))), "おどろき+段階アップ演出"),
        (out("solo", compose(0, solo=True)), "ソロ(ペア前)"),
        (out("solo_glow", compose(0, solo=True, soil_glow=True)), "ソロ: 自分がチェックイン"),
        (out("s0_me", compose(0, "open", "folded", "face_look_l")), "段階0: 自分の芽が光る"),
        (out("peek_s3", compose(3, "open", "folded", "face_look_l", peek=True)), "のぞき(わかば)"),
        (out("peek_s7", compose(7, "folded", "open", "face_look_r", peek=True)), "のぞき(ほころび)"),
        (out("peek_s8", compose(8, "open", "open", "face_normal", peek=True)), "のぞき(ふたりざき→みのり)"),
    ]
    sheet(cells, os.path.join(HERE, "preview_extras.png"), cols=6, title="表情6種・ソロ・段階0・演出・のぞき")

    # 4) 花の色(左右で別の色にできる)
    combos = [("pink", "pink"), ("pink", "blue"), ("yellow", "lilac"), ("white", "pink"), ("blue", "yellow")]
    cells = [(out(f"color_{a}_{b}", compose(8, "open", "open", "face_happy", color_me=PETAL_COLORS[a],
                                            color_partner=PETAL_COLORS[b])), f"自分 {a} × 相手 {b}") for a, b in combos]
    sheet(cells, os.path.join(HERE, "preview_colors.png"), cols=5,
          title="花の色(v1.1 で各自が自分の側の色を選ぶ — 左右の petal 層を別々に着色)")

    # 5) ダークモード(背面プレートあり)
    cells = [(out(f"dark_{n}", compose(*a, dark=True, **k)), lab) for n, a, k, lab in [
        ("solo", (0,), dict(solo=True), "ソロ"), ("s0", (0, "open", "folded", "face_look_l"), {}, "段階0"),
        ("s1", (1, "folded", "folded", "face_normal"), {}, "段階1(朝)"),
        ("s5", (5, "open", "folded", "face_look_l"), {}, "段階5"),
        ("s8", (8, "open", "open", "face_happy", ("fx_sparkle",)), {}, "段階8"),
        ("s9", (9, "open", "open", "face_normal"), {}, "段階9")]]
    sheet(cells, os.path.join(HERE, "preview_dark.png"), cols=6, title="ダークモード(植物の背面にクリーム色のプレートを敷く)",
          bg="#1C1C20", page="#111114", label_color="#C9C2BA")


def acceptance_sheet():
    """受け入れ基準 §9.5 の目視用: 全段階の朝(葉を閉じる)+段階9を 40/60/80pt(@3x 相当)・ライト/ダークで。"""
    from PIL import Image
    names = ["solo"] + [f"state_s{st}_none" for st in range(10)] + ["growth_s9"]
    light, dark = {}, {}
    for n in names:
        if n == "solo":
            args, kw = (0,), dict(solo=True)
        elif n == "growth_s9":
            args, kw = (9, "open", "open", "face_normal"), {}
        else:
            st = int(n.split("_s")[1].split("_")[0])
            args, kw = (st, "folded", "folded", "face_normal"), {}
        for store, is_dark in ((light, False), (dark, True)):
            sp = os.path.join(TMP_DIR, f"acc_{n}_{int(is_dark)}.svg")
            with open(sp, "w") as fh:
                fh.write(compose(*args, dark=is_dark, **kw))
            pth = sp[:-4] + ".png"
            render(sp, pth, 2)
            store[n] = Image.open(pth).convert("RGBA")
    pad = 14
    rows = []
    for src, bg in ((light, (255, 248, 236, 255)), (dark, (28, 28, 32, 255))):
        for pt in (40, 60, 80):
            hpx, wpx = pt * 3, int(pt * 3 * 0.75)
            rows.append(([src[n].resize((wpx, hpx), Image.LANCZOS) for n in names], bg))
    width = max(sum(im.width + pad for im in r) for r, _ in rows) + pad
    height = sum(r[0].height + pad for r, _ in rows) + pad
    canvas = Image.new("RGBA", (width, height), (255, 255, 255, 255))
    y = pad
    for r, bg in rows:
        x = pad
        for im in r:
            cell = Image.new("RGBA", im.size, bg)
            cell.alpha_composite(im)
            canvas.paste(cell, (x, y))
            x += im.width + pad
        y += r[0].height + pad
    canvas.save(os.path.join(HERE, "preview_acceptance.png"))


# 現行契約(PlantSprite.swift / mapping.md の 13 imageset)へのフォールバック。旧6段階ルールのまま進める場合用。
# 旧段階 → 新しい絵: 1芽→s1 / 2双葉→s3 / 3若葉→s4 / 4つぼみ→s5 / 5開花→s8。sad は同じ段階の「すやすや」。
OLD_TO_NEW = {1: 1, 2: 3, 3: 4, 4: 5, 5: 8}
CONTRACT13 = ["soil"] + [f"stage{i}_{m}" for i in range(1, 6) for m in ("normal", "happy")] + ["stage2_sad", "stage5_sad"]


def contract_frames():
    frames = {"soil": dict(solo=True)}
    for old, new in OLD_TO_NEW.items():
        frames[f"stage{old}_normal"] = dict(stage=new, me="open", partner="open", face="face_normal")
        frames[f"stage{old}_happy"] = dict(stage=new, me="open", partner="open", face="face_happy", fx=("fx_sparkle",))
        frames[f"stage{old}_sad"] = dict(stage=new, me="folded", partner="folded", face="face_sleep", fx=("fx_zzz",))
    return frames


def export_contract():
    svg_dir, png_dir = os.path.join(HERE, "svg"), os.path.join(HERE, "png")
    for d in (svg_dir, png_dir):
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
    frames = contract_frames()
    for name, kw in frames.items():
        kw = dict(kw)
        stage = kw.pop("stage", 0)
        sp = os.path.join(svg_dir, f"{name}.svg")
        with open(sp, "w") as fh:
            fh.write(compose(stage, **kw))
        render(sp, os.path.join(png_dir, f"{name}.png"), 2)
    extra = [n for n in frames if n not in CONTRACT13]
    sheet([(f"svg/{n}.svg", n) for n in CONTRACT13] + [(f"svg/{n}.svg", n + "(追加)") for n in extra],
          os.path.join(HERE, "contact_sheet.png"), cols=8, cell_w=180, cell_h=240,
          title="旧6段階ルール用フォールバック: 契約13枚+段階ごとの sad 3枚(PlantSprite の sad 対応表の更新が必要)")
    strip = ["solo"] + [f"growth_s{st}" for st in range(10)]
    sheet([(f"composed/{n}.svg", "") for n in strip], os.path.join(HERE, "growth_strip.png"), cols=11)


def main():
    global LAYERS
    LAYERS = {k: fn() for k, fn in layer_specs().items()}
    for d in (LAYER_DIR, COMP_DIR, TMP_DIR):
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
    bad = []
    for name, inner in sorted(LAYERS.items()):
        text = wrap(inner)
        if FORBIDDEN.search(text):
            bad.append(f"{name}: 禁止要素")
        try:
            minidom.parseString(text)
        except Exception as e:  # noqa: BLE001
            bad.append(f"{name}: {e}")
        with open(os.path.join(LAYER_DIR, f"{name}.svg"), "w") as fh:
            fh.write(text)
    if bad:
        raise SystemExit(f"レイヤーの検査に失敗: {bad}")
    overlap = check_petal_overlap()
    if overlap:
        raise SystemExit(f"左右の花の塗りが重なっている(画素数): {overlap}")
    with open(os.path.join(HERE, "peek_offsets.json"), "w") as fh:
        json.dump(peek_offsets(), fh, ensure_ascii=False, indent=1)
    build_previews()
    acceptance_sheet()
    export_contract()
    shutil.rmtree(TMP_DIR)
    print(f"layers: {len(LAYERS)} / petal overlap: none / peeks: {peek_offsets()}")


if __name__ == "__main__":
    main()
