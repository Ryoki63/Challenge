#!/usr/bin/env python3
"""Lien 植物キャラクター v4「タネの子」— SVG ベクタージェネレータ。

v0〜v3(ドット絵)を全面的に置き換える刷新案。キャラ設計:
  - 主役は鉢に住む「タネの子」。まるい大福のような体に顔があり、**頭から植物が育つ**
    (体と顔は全段階で同一 = 愛着の連続性。変わるのは頭の植物だけ)
  - 最初の双葉2枚 = ふたり。最終形は茎がハートを描いて寄り添う「二輪咲き」
  - 線は暖かいこげ茶の単色アウトライン(ステッカー調)。塗りは2トーン+やわらかいハイライト

部品はレイヤー(植物 / 体 / 顔 / 鉢 / エフェクト)として関数化しているので、
段階・表情・鉢(v1.1 の着せ替え)を増やしても組み合わせ爆発しない。
Xcode のアセットカタログ(SVG のベクター保持)で読めるよう、filter は使わず
グラデーションと不透明度のみで描く。

使い方:
  python3 gen_v4.py            # svg/ と png/(ヘッドレス Chrome で透過 PNG 化)と contact_sheet.png
  python3 gen_v4.py --svg-only # SVG だけ
"""

import math
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SVG_DIR = os.path.join(HERE, "svg")
PNG_DIR = os.path.join(HERE, "png")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

W, H = 240, 320
CX = 120.0

# ---------------------------------------------------------------------------
# パレット
# ---------------------------------------------------------------------------
OUT = "#4A3428"          # 共通アウトライン(暖かいこげ茶)
SW = 4.2                 # 基本線幅

BODY_TOP = "#FFFBF2"
BODY_MID = "#FFF1DC"
BODY_LOW = "#F6D9B6"
EYE = "#3A2A22"
BLUSH = "#FF9C9C"

LEAF_LIGHT = "#B5E58C"
LEAF = "#82C95C"
LEAF_DARK = "#5BA543"
VEIN = "#D6F5B8"
STEM = "#74BD52"

POT_LIGHT = "#F4AE86"
POT = "#E6895C"
POT_DARK = "#CC6E45"
POT_RIM_TOP = "#F7BE9A"
SOIL = "#7E5539"
SOIL_DARK = "#644129"

SPARK = "#FFCF4D"
SPARK_LIGHT = "#FFF0B3"
DROP = "#9CD3F5"

FLOWER = {
    "pink":   {"petal": "#FFB3C7", "light": "#FFD9E3", "shade": "#F08AA6", "center": "#FFD45E", "center_dark": "#F2AE3C"},
    "yellow": {"petal": "#FFE07A", "light": "#FFF1BE", "shade": "#F3C14A", "center": "#FF9E6E", "center_dark": "#E97E4F"},
    "blue":   {"petal": "#A9D8FF", "light": "#D8EEFF", "shade": "#7FB8EE", "center": "#FFE07A", "center_dark": "#F2BE45"},
    "white":  {"petal": "#FFFFFF", "light": "#FFFFFF", "shade": "#E6E1F0", "center": "#FFD45E", "center_dark": "#F2AE3C"},
}


def f(v):
    """座標を短い文字列に(決定論・差分が読みやすいように小数1桁)。"""
    s = f"{v:.1f}"
    return s[:-2] if s.endswith(".0") else s


# ---------------------------------------------------------------------------
# 共通 defs
# ---------------------------------------------------------------------------
def defs():
    return f"""<defs>
  <linearGradient id="gBody" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{BODY_TOP}"/>
    <stop offset="0.55" stop-color="{BODY_MID}"/>
    <stop offset="1" stop-color="{BODY_LOW}"/>
  </linearGradient>
  <linearGradient id="gPot" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="{POT_LIGHT}"/>
    <stop offset="0.45" stop-color="{POT}"/>
    <stop offset="1" stop-color="{POT_DARK}"/>
  </linearGradient>
  <linearGradient id="gRim" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="{POT_RIM_TOP}"/>
    <stop offset="0.5" stop-color="{POT_LIGHT}"/>
    <stop offset="1" stop-color="{POT}"/>
  </linearGradient>
  <radialGradient id="gSoil" cx="0.5" cy="0.3" r="0.8">
    <stop offset="0" stop-color="{SOIL}"/>
    <stop offset="1" stop-color="{SOIL_DARK}"/>
  </radialGradient>
</defs>"""


# ---------------------------------------------------------------------------
# 鉢
# ---------------------------------------------------------------------------
RIM_Y0, RIM_Y1 = 222.0, 246.0
RIM_X0, RIM_X1 = 44.0, 196.0
POT_BOTTOM = 298.0


def pot():
    rim = (f'<rect x="{f(RIM_X0)}" y="{f(RIM_Y0)}" width="{f(RIM_X1 - RIM_X0)}" '
           f'height="{f(RIM_Y1 - RIM_Y0)}" rx="10" fill="url(#gRim)" stroke="{OUT}" stroke-width="{SW}"/>')
    body = (f'<path d="M55 {f(RIM_Y1)} L185 {f(RIM_Y1)} L175 {f(POT_BOTTOM - 9)} '
            f'Q173 {f(POT_BOTTOM)} 163 {f(POT_BOTTOM)} L77 {f(POT_BOTTOM)} Q67 {f(POT_BOTTOM)} 65 {f(POT_BOTTOM - 9)} Z" '
            f'fill="url(#gPot)" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>')
    # リムの下に落ちる影(鉢本体の上端)と、リム上面のハイライト
    shade = f'<path d="M57.5 {f(RIM_Y1 + 2.5)} L182.5 {f(RIM_Y1 + 2.5)} L181.3 {f(RIM_Y1 + 8)} L58.7 {f(RIM_Y1 + 8)} Z" fill="{POT_DARK}" opacity="0.45"/>'
    hl = f'<path d="M56 {f(RIM_Y0 + 7)} L124 {f(RIM_Y0 + 7)}" stroke="#FFFFFF" stroke-width="3.2" stroke-linecap="round" opacity="0.55"/>'
    hl2 = f'<path d="M72 {f(RIM_Y1 + 15)} L70 {f(POT_BOTTOM - 14)}" stroke="#FFFFFF" stroke-width="3.2" stroke-linecap="round" opacity="0.35"/>'
    return rim + body + shade + hl + hl2


def soil_in_pot():
    """鉢の口からのぞく土(体の背後)。"""
    return (f'<ellipse cx="{f(CX)}" cy="{f(RIM_Y0 + 1)}" rx="70" ry="10" fill="url(#gSoil)" '
            f'stroke="{OUT}" stroke-width="{SW}"/>')


def ground_shadow():
    return f'<ellipse cx="{f(CX)}" cy="{f(POT_BOTTOM + 5)}" rx="66" ry="6" fill="{OUT}" opacity="0.10"/>'


# ---------------------------------------------------------------------------
# 体(タネの子)
# ---------------------------------------------------------------------------
BODY_TOP_Y = 132.0
HEAD_ANCHOR = (CX, BODY_TOP_Y + 6)   # 頭の植物の生え際(体の中に少し埋まる)


def body_path(dy=0.0, squash=1.0):
    """大福型。下端は鉢のリムで隠れる。squash<1 で少しつぶれる(しょんぼり)。"""
    top = BODY_TOP_Y + dy + (1 - squash) * 30
    b = 232.0
    hgt = b - top
    def y(t):
        return top + hgt * t
    return (f"M58 {f(b)} "
            f"C30 {f(y(0.9))} 30 {f(y(0.36))} 74 {f(y(0.13))} "
            f"C94 {f(top)} 146 {f(top)} 166 {f(y(0.13))} "
            f"C210 {f(y(0.36))} 210 {f(y(0.9))} 182 {f(b)} Z")


def body(dy=0.0, squash=1.0):
    p = body_path(dy, squash)
    top = BODY_TOP_Y + dy + (1 - squash) * 30
    out = f'<path d="{p}" fill="url(#gBody)" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
    # 左上のつや(大福の照り)
    out += (f'<ellipse cx="72" cy="{f(top + 26)}" rx="13" ry="7" transform="rotate(-30 72 {f(top + 26)})" '
            f'fill="#FFFFFF" opacity="0.9"/>')
    out += f'<circle cx="89" cy="{f(top + 14)}" r="3.2" fill="#FFFFFF" opacity="0.9"/>'
    return out


def hand(x, y, angle=0.0):
    return (f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="10" ry="8" transform="rotate({f(angle)} {f(x)} {f(y)})" '
            f'fill="{BODY_MID}" stroke="{OUT}" stroke-width="{SW}"/>'
            f'<ellipse cx="{f(x - 3)}" cy="{f(y - 3)}" rx="2.6" ry="1.6" fill="#FFFFFF" opacity="0.6"/>')


def hands_on_rim():
    """鉢のふちに手をかける(前面)。"""
    return hand(CX - 50, RIM_Y0 + 1, -12) + hand(CX + 50, RIM_Y0 + 1, 12)


def arms_up():
    """バンザイ(喜び)— 体の背後から生えるように先に描く。"""
    out = ""
    for sx in (-1, 1):
        x0, y0 = CX + sx * 62, 198
        x1, y1 = CX + sx * 84, 164
        d = f"M{f(x0)} {f(y0)} Q{f(CX + sx * 84)} {f(186)} {f(x1)} {f(y1)}"
        out += (f'<path d="{d}" fill="none" stroke="{OUT}" stroke-width="{f(19 + SW * 2 - 1)}" stroke-linecap="round"/>'
                f'<path d="{d}" fill="none" stroke="{BODY_MID}" stroke-width="19" stroke-linecap="round"/>')
    return out


# ---------------------------------------------------------------------------
# 顔
# ---------------------------------------------------------------------------
EYE_Y = 181.0
EYE_DX = 25.0
BLUSH_Y = 195.0


def blush(dy=0.0, strength=0.55):
    y = BLUSH_Y + dy
    return (f'<ellipse cx="{f(CX - 46)}" cy="{f(y)}" rx="12" ry="7" fill="{BLUSH}" opacity="{strength}"/>'
            f'<ellipse cx="{f(CX + 46)}" cy="{f(y)}" rx="12" ry="7" fill="{BLUSH}" opacity="{strength}"/>')


def eyes_open(dy=0.0, look=0.0):
    out = ""
    for sx in (-1, 1):
        x = CX + sx * EYE_DX + look
        y = EYE_Y + dy
        out += f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="7.2" ry="9.4" fill="{EYE}"/>'
        out += f'<circle cx="{f(x + 2.4)}" cy="{f(y - 3.6)}" r="2.9" fill="#FFFFFF"/>'
        out += f'<circle cx="{f(x - 2.4)}" cy="{f(y + 3.6)}" r="1.1" fill="#FFFFFF" opacity="0.8"/>'
    return out


def eyes_happy(dy=0.0):
    """にっこり閉じ目 ^ ^"""
    out = ""
    for sx in (-1, 1):
        x = CX + sx * EYE_DX
        y = EYE_Y + dy + 2
        out += (f'<path d="M{f(x - 7.5)} {f(y + 2)} Q{f(x)} {f(y - 8.5)} {f(x + 7.5)} {f(y + 2)}" '
                f'fill="none" stroke="{EYE}" stroke-width="4.2" stroke-linecap="round"/>')
    return out


def eyes_sleep(dy=0.0):
    """ねむり目 ‿ ‿"""
    out = ""
    for sx in (-1, 1):
        x = CX + sx * EYE_DX
        y = EYE_Y + dy
        out += (f'<path d="M{f(x - 7)} {f(y - 1)} Q{f(x)} {f(y + 6)} {f(x + 7)} {f(y - 1)}" '
                f'fill="none" stroke="{EYE}" stroke-width="3.8" stroke-linecap="round"/>')
    return out


def eyes_sad(dy=0.0):
    """しょんぼり: 開いた目+ハの字まゆ(泣かない・苦しまない)"""
    out = ""
    for sx in (-1, 1):
        x = CX + sx * EYE_DX
        y = EYE_Y + dy + 2
        out += f'<ellipse cx="{f(x)}" cy="{f(y)}" rx="6" ry="7.2" fill="{EYE}"/>'
        out += f'<circle cx="{f(x + 2)}" cy="{f(y - 2.8)}" r="2.3" fill="#FFFFFF"/>'
        # まゆ: 外側が下がるハの字
        bx0, by0 = x - sx * 2, y - 15
        bx1, by1 = x + sx * 9, y - 11
        out += (f'<path d="M{f(bx0)} {f(by0)} L{f(bx1)} {f(by1)}" stroke="{EYE}" stroke-width="3.2" '
                f'stroke-linecap="round"/>')
    return out


def mouth_smile(dy=0.0):
    y = 196.0 + dy
    return (f'<path d="M{f(CX - 7)} {f(y)} Q{f(CX)} {f(y + 7)} {f(CX + 7)} {f(y)}" fill="none" '
            f'stroke="{EYE}" stroke-width="3.6" stroke-linecap="round"/>')


def mouth_open(dy=0.0):
    y = 194.0 + dy
    return (f'<path d="M{f(CX - 9)} {f(y)} Q{f(CX)} {f(y + 1.5)} {f(CX + 9)} {f(y)} '
            f'Q{f(CX + 8)} {f(y + 13)} {f(CX)} {f(y + 13)} Q{f(CX - 8)} {f(y + 13)} {f(CX - 9)} {f(y)} Z" '
            f'fill="#B5473F" stroke="{EYE}" stroke-width="3" stroke-linejoin="round"/>'
            f'<path d="M{f(CX - 5)} {f(y + 9.5)} Q{f(CX)} {f(y + 5.5)} {f(CX + 5)} {f(y + 9.5)} '
            f'Q{f(CX)} {f(y + 12)} {f(CX - 5)} {f(y + 9.5)} Z" fill="#FF8C8C"/>')


def mouth_sleep(dy=0.0):
    y = 197.0 + dy
    return f'<ellipse cx="{f(CX)}" cy="{f(y)}" rx="3.2" ry="2.6" fill="{EYE}"/>'


def mouth_sad(dy=0.0):
    y = 201.0 + dy
    return (f'<path d="M{f(CX - 6)} {f(y)} Q{f(CX)} {f(y - 5)} {f(CX + 6)} {f(y)}" fill="none" '
            f'stroke="{EYE}" stroke-width="3.4" stroke-linecap="round"/>')


def face(mood, dy=0.0):
    if mood == "happy":
        return blush(dy, 0.75) + eyes_happy(dy) + mouth_open(dy)
    if mood == "sad":
        return blush(dy, 0.35) + eyes_sad(dy) + mouth_sad(dy)
    if mood == "sleep":
        return blush(dy, 0.45) + eyes_sleep(dy) + mouth_sleep(dy)
    return blush(dy) + eyes_open(dy) + mouth_smile(dy)


# ---------------------------------------------------------------------------
# 植物パーツ
# ---------------------------------------------------------------------------
def leaf(x, y, length, angle, side, width_ratio=0.5, droop=0.0):
    """付け根 (x, y) から伸びる葉。angle=水平からの仰角(度)。side=+1 右 / -1 左。
    droop>0 で先端が下に反る。2トーン(上半分ライト)+中央の葉脈。"""
    L = length
    Wd = L * width_ratio
    d = droop * L
    outer = (f"M0 0 C{f(L * 0.22)} {f(-Wd * 0.95)} {f(L * 0.78)} {f(-Wd * 0.85 + d * 0.5)} {f(L)} {f(d)} "
             f"C{f(L * 0.74)} {f(Wd * 0.75 + d * 0.6)} {f(L * 0.24)} {f(Wd * 0.8)} 0 0 Z")
    upper = (f"M0 0 C{f(L * 0.22)} {f(-Wd * 0.95)} {f(L * 0.78)} {f(-Wd * 0.85 + d * 0.5)} {f(L)} {f(d)} "
             f"C{f(L * 0.7)} {f(d * 0.55)} {f(L * 0.3)} {f(-Wd * 0.05)} 0 0 Z")
    vein = f"M{f(L * 0.14)} {f(-Wd * 0.02)} Q{f(L * 0.5)} {f(-Wd * 0.08 + d * 0.3)} {f(L * 0.8)} {f(d * 0.7)}"
    sx = 1 if side > 0 else -1
    tr = f"translate({f(x)} {f(y)}) scale({sx} 1) rotate({f(-angle)})"
    return (f'<g transform="{tr}">'
            f'<path d="{outer}" fill="{LEAF}" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'<path d="{upper}" fill="{LEAF_LIGHT}"/>'
            f'<path d="{vein}" fill="none" stroke="{VEIN}" stroke-width="2.4" stroke-linecap="round" opacity="0.9"/>'
            f'<path d="{outer}" fill="none" stroke="{OUT}" stroke-width="{SW}" stroke-linejoin="round"/>'
            f'</g>')


def stem(d, width=5.5):
    """アウトライン付きの茎(輪郭色の太線 → 緑の細線の二重描き)。"""
    return (f'<path d="{d}" fill="none" stroke="{OUT}" stroke-width="{f(width + SW * 2 - 1)}" stroke-linecap="round" stroke-linejoin="round"/>'
            f'<path d="{d}" fill="none" stroke="{STEM}" stroke-width="{f(width)}" stroke-linecap="round" stroke-linejoin="round"/>')


def bud(x, y, angle, size=1.0, color="pink"):
    """つぼみ(上向きのしずく形)。angle で内側に傾ける。"""
    c = FLOWER[color]
    s = size
    tr = f"translate({f(x)} {f(y)}) rotate({f(angle)}) scale({f(s)})"
    return (f'<g transform="{tr}">'
            f'<path d="M0 -21 C9 -13 12 -3 9 3 C6 8 -6 8 -9 3 C-12 -3 -9 -13 0 -21 Z" fill="{c["petal"]}" stroke="{OUT}" stroke-width="{f(SW / s)}" stroke-linejoin="round"/>'
            f'<path d="M0 -17 C4 -11 5 -5 3 -1" fill="none" stroke="{c["light"]}" stroke-width="{f(3 / s)}" stroke-linecap="round"/>'
            # がく
            f'<path d="M-10 2 Q-6 -5 0 1 Q6 -5 10 2 Q6 10 0 9 Q-6 10 -10 2 Z" fill="{LEAF}" stroke="{OUT}" stroke-width="{f(SW / s)}" stroke-linejoin="round"/>'
            f'</g>')


def flower(x, y, r, angle=0.0, color="pink", petals=5):
    c = FLOWER[color]
    out = f'<g transform="translate({f(x)} {f(y)}) rotate({f(angle)})">'
    pr = r * 0.52   # 花びらの半径
    dist = r * 0.5
    for k in range(petals):
        a = -90 + k * 360 / petals
        px = dist * math.cos(math.radians(a))
        py = dist * math.sin(math.radians(a))
        out += (f'<ellipse cx="{f(px)}" cy="{f(py)}" rx="{f(pr * 0.92)}" ry="{f(pr * 1.08)}" '
                f'transform="rotate({f(a + 90)} {f(px)} {f(py)})" fill="{c["petal"]}" stroke="{OUT}" stroke-width="{SW}"/>')
    # 花びらの内側(付け根寄り)を明るく — 立体感と「ふんわり」感
    for k in range(petals):
        a = -90 + k * 360 / petals
        hx = (dist - pr * 0.18) * math.cos(math.radians(a))
        hy = (dist - pr * 0.18) * math.sin(math.radians(a))
        out += (f'<ellipse cx="{f(hx)}" cy="{f(hy)}" rx="{f(pr * 0.5)}" ry="{f(pr * 0.62)}" '
                f'transform="rotate({f(a + 90)} {f(hx)} {f(hy)})" fill="{c["light"]}" opacity="0.9"/>')
    out += f'<circle cx="0" cy="0" r="{f(r * 0.36)}" fill="{c["center"]}" stroke="{OUT}" stroke-width="{SW}"/>'
    out += f'<circle cx="{f(-r * 0.1)}" cy="{f(-r * 0.1)}" r="{f(r * 0.12)}" fill="#FFFFFF" opacity="0.7"/>'
    out += '</g>'
    return out


def bez(p0, p1, p2, p3, t):
    """3次ベジェ上の点(茎に葉を正しく付けるため)。"""
    u = 1 - t
    x = u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0]
    y = u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]
    return x, y


# --- 段階ごとの頭の植物 -----------------------------------------------------
def plant(stage, mood, color="pink"):
    """stage: 1 芽 / 2 双葉 / 3 若葉 / 4 つぼみ / 5 開花(二輪咲き)。
    mood=sad で葉が垂れる(枯れない・縮まない)。happy で少し上向き。"""
    ax, ay = HEAD_ANCHOR
    lift = 10 if mood == "happy" else (-24 if mood == "sad" else 0)
    droop = 0.22 if mood == "sad" else 0.0
    out = ""
    if stage == 1:
        top = ay - 20
        out += stem(f"M{f(ax)} {f(ay + 4)} L{f(ax)} {f(top)}", 5)
        out += leaf(ax, top + 1, 21, 38 + lift, -1, 0.52, droop)
        out += leaf(ax, top + 1, 21, 38 + lift, +1, 0.52, droop)
    elif stage == 2:
        top = ay - 26
        out += stem(f"M{f(ax)} {f(ay + 4)} L{f(ax)} {f(top)}", 5.5)
        out += leaf(ax, top + 1, 44, 18 + lift, -1, 0.5, droop)
        out += leaf(ax, top + 1, 44, 18 + lift, +1, 0.5, droop)
    elif stage == 3:
        fut = ay - 22
        top = ay - 62
        out += stem(f"M{f(ax)} {f(ay + 4)} C{f(ax)} {f(fut - 10)} {f(ax + 7)} {f(top + 22)} {f(ax)} {f(top)}", 5.5)
        out += leaf(ax, fut, 40, 12 + lift * 0.8, -1, 0.5, droop)
        out += leaf(ax, fut, 40, 12 + lift * 0.8, +1, 0.5, droop)
        out += leaf(ax + 2, top + 18, 30, 40 + lift, +1, 0.48, droop)
        out += leaf(ax + 1, top + 4, 26, 44 + lift, -1, 0.48, droop)
        # 先端の小さな芽
        out += leaf(ax, top + 1, 12, 78, +1, 0.55, 0)
    elif stage in (4, 5):
        fut = ay - 20
        split = ay - 30
        # ふたりの茎: 外へふくらんで内へ戻る = 2本の茎のすき間がハート形になる
        sad = mood == "sad"
        top_y = ay - (96 if stage == 5 else 92) + (8 if sad else 0)
        gap = 27 if stage == 5 else 20
        curves = []
        for sx in (-1, 1):
            p0 = (ax, split)
            p1 = (ax + sx * 14, split - 4)
            p2 = (ax + sx * 58, split - 30)
            p3 = (ax + sx * gap, top_y)
            curves.append((sx, p0, p1, p2, p3))
        out += stem(f"M{f(ax)} {f(ay + 4)} L{f(ax)} {f(split)}", 6)
        for sx, p0, p1, p2, p3 in curves:
            out += stem(f"M{f(p0[0])} {f(p0[1])} C{f(p1[0])} {f(p1[1])} {f(p2[0])} {f(p2[1])} {f(p3[0])} {f(p3[1])}", 5.2)
        out += leaf(ax, fut, 40, 12 + lift * 0.8, -1, 0.5, droop)
        out += leaf(ax, fut, 40, 12 + lift * 0.8, +1, 0.5, droop)
        # 茎の途中(外側のふくらみ)に付く小さな葉
        for sx, p0, p1, p2, p3 in curves:
            bx, by = bez(p0, p1, p2, p3, 0.52)
            out += leaf(bx, by, 22, 22 + lift * 0.6, sx, 0.5, droop)
        tilt = 18 + (14 if sad else 0)
        if stage == 4:
            for sx, p0, p1, p2, p3 in curves:
                out += bud(p3[0], p3[1] + 2, -sx * tilt, 1.22, color)
        else:
            fr = 31
            for sx, p0, p1, p2, p3 in curves:
                out += flower(p3[0] + sx * 2, p3[1] - 6, fr, sx * (14 - (10 if sad else 0)), color)
    return out


# ---------------------------------------------------------------------------
# エフェクト
# ---------------------------------------------------------------------------
def sparkle(x, y, s, color=SPARK):
    k = s * 0.22
    d = (f"M{f(x)} {f(y - s)} Q{f(x + k)} {f(y - k)} {f(x + s)} {f(y)} Q{f(x + k)} {f(y + k)} {f(x)} {f(y + s)} "
         f"Q{f(x - k)} {f(y + k)} {f(x - s)} {f(y)} Q{f(x - k)} {f(y - k)} {f(x)} {f(y - s)} Z")
    return f'<path d="{d}" fill="{color}" stroke="{OUT}" stroke-width="2.6" stroke-linejoin="round"/>'


def happy_fx(stage):
    top = 40 if stage >= 4 else (70 if stage == 3 else 92)
    return (sparkle(30, top + 10, 11) + sparkle(212, top + 30, 13) + sparkle(222, 214, 7, SPARK_LIGHT)
            + sparkle(20, 206, 8, SPARK_LIGHT)
            + f'<circle cx="52" cy="{f(top + 46)}" r="3" fill="{SPARK}"/>'
            + f'<circle cx="190" cy="{f(top)}" r="3" fill="{SPARK}"/>')


def sad_fx():
    # 汗ひとつぶ(右上)— 痛み・涙ではなく「しょんぼり」の記号
    x, y = 180, 152
    return (f'<path d="M{x} {y - 13} C{x + 6} {y - 4} {x + 8} {y} {x + 8} {y + 4} '
            f'C{x + 8} {y + 9} {x + 4} {y + 12} {x} {y + 12} C{x - 4} {y + 12} {x - 8} {y + 9} {x - 8} {y + 4} '
            f'C{x - 8} {y} {x - 6} {y - 4} {x} {y - 13} Z" fill="{DROP}" stroke="{OUT}" stroke-width="2.8"/>'
            f'<circle cx="{x - 3}" cy="{y + 4}" r="2" fill="#FFFFFF" opacity="0.9"/>')


def zzz():
    def z(x, y, size, op):
        d = f"M{f(x)} {f(y)} L{f(x + size)} {f(y)} L{f(x)} {f(y + size * 1.1)} L{f(x + size)} {f(y + size * 1.1)}"
        return (f'<path d="{d}" fill="none" stroke="{OUT}" stroke-width="3.6" stroke-linecap="round" '
                f'stroke-linejoin="round" opacity="{op}"/>')
    return z(168, 150, 13, 0.75) + z(188, 126, 9, 0.55)


# ---------------------------------------------------------------------------
# フレーム合成
# ---------------------------------------------------------------------------
def soil_frame():
    """ソロ / stage0: タネの子は土の中でおやすみ中(頭のてっぺんだけ見える)。
    ペア成立→ふたりの初チェックインで目を覚ます=招待とチェックインの動機。"""
    inner = ground_shadow()
    inner += soil_in_pot()
    # 土から少しだけ出た頭(体パスを下げて描き、鉢で隠す)
    inner += (f'<clipPath id="cSoil"><rect x="0" y="0" width="{W}" height="{f(RIM_Y0 + 6)}"/></clipPath>'
              f'<g clip-path="url(#cSoil)"><g transform="translate(0 21) translate(120 232) scale(0.84) translate(-120 -232)">{body()}{face("sleep")}</g></g>')
    inner += pot()
    inner += hands_on_rim()
    inner += zzz()
    return inner


def stage_frame(stage, mood, color="pink"):
    inner = ground_shadow()
    inner += plant(stage, mood, color)
    inner += soil_in_pot()
    if mood == "happy":
        inner += arms_up()
    squash = 0.96 if mood == "sad" else 1.0
    dy = 2.0 if mood == "sad" else 0.0
    inner += body(dy=0, squash=squash)
    inner += face(mood, dy=dy)
    inner += pot()
    if mood != "happy":
        inner += hands_on_rim()
    if mood == "happy":
        inner += happy_fx(stage)
    elif mood == "sad":
        inner += sad_fx()
    return inner


def svg(inner):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">'
            f'{defs()}{inner}</svg>\n')


# 契約(PlantSprite.swift / mapping.md)の13 imageset と同名で出力する
FRAMES = [
    ("soil", lambda: soil_frame()),
    ("stage1_normal", lambda: stage_frame(1, "normal")),
    ("stage1_happy", lambda: stage_frame(1, "happy")),
    ("stage2_normal", lambda: stage_frame(2, "normal")),
    ("stage2_happy", lambda: stage_frame(2, "happy")),
    ("stage2_sad", lambda: stage_frame(2, "sad")),
    ("stage3_normal", lambda: stage_frame(3, "normal")),
    ("stage3_happy", lambda: stage_frame(3, "happy")),
    ("stage4_normal", lambda: stage_frame(4, "normal")),
    ("stage4_happy", lambda: stage_frame(4, "happy")),
    ("stage5_normal", lambda: stage_frame(5, "normal")),
    ("stage5_happy", lambda: stage_frame(5, "happy")),
    ("stage5_sad", lambda: stage_frame(5, "sad")),
]

# 参考: 最終形の花色バリエーション(成長ルール案の「色違い」用。パレット差し替えのみ)
EXTRAS = [
    ("extra_stage5_yellow", lambda: stage_frame(5, "normal", "yellow")),
    ("extra_stage5_blue", lambda: stage_frame(5, "normal", "blue")),
    ("extra_stage5_white", lambda: stage_frame(5, "normal", "white")),
]


def render_png(svg_path, png_path, scale=2):
    subprocess.run([
        CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
        "--default-background-color=00000000", f"--window-size={W},{H}",
        f"--force-device-scale-factor={scale}", f"--screenshot={png_path}", "file://" + svg_path,
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def contact_sheet(names, path, cols=7, cell_w=240, cell_h=320, label=True):
    rows = math.ceil(len(names) / cols)
    pad = 8
    lab = 26 if label else 0
    sw, sh = cols * (cell_w + pad) + pad, rows * (cell_h + lab + pad) + pad
    cells = ""
    for i, n in enumerate(names):
        cx = pad + (i % cols) * (cell_w + pad)
        cy = pad + (i // cols) * (cell_h + lab + pad)
        cells += (f'<div style="position:absolute;left:{cx}px;top:{cy}px;width:{cell_w}px;height:{cell_h + lab}px;'
                  f'background:#FFF7EA;border-radius:18px">'
                  f'<img src="svg/{n}.svg" style="width:{cell_w}px;height:{cell_h}px;display:block">'
                  + (f'<div style="font:600 13px -apple-system,Helvetica;color:#8A6F5E;text-align:center">{n}</div>' if label else "")
                  + '</div>')
    html = (f'<!doctype html><html><body style="margin:0;background:#F3E9DA;width:{sw}px;height:{sh}px;position:relative">'
            f'{cells}</body></html>')
    hp = os.path.join(HERE, "_sheet.html")
    with open(hp, "w") as fh:
        fh.write(html)
    subprocess.run([
        CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
        f"--window-size={sw},{sh}", "--force-device-scale-factor=1", f"--screenshot={path}", "file://" + hp,
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.remove(hp)


def main():
    svg_only = "--svg-only" in sys.argv
    for d in (SVG_DIR, PNG_DIR):
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
    names = []
    for name, fn in FRAMES + EXTRAS:
        p = os.path.join(SVG_DIR, f"{name}.svg")
        with open(p, "w") as fh:
            fh.write(svg(fn()))
        names.append(name)
    if svg_only:
        return
    for name in names:
        render_png(os.path.join(SVG_DIR, f"{name}.svg"), os.path.join(PNG_DIR, f"{name}.png"))
    contact_sheet([n for n, _ in FRAMES], os.path.join(HERE, "contact_sheet.png"))
    contact_sheet(["soil", "stage1_normal", "stage2_normal", "stage3_normal", "stage4_normal", "stage5_normal", "stage5_happy"],
                  os.path.join(HERE, "growth_strip.png"), cols=7, label=False)
    contact_sheet([n for n, _ in EXTRAS] + ["stage5_normal"], os.path.join(HERE, "variants.png"), cols=4)


if __name__ == "__main__":
    main()
