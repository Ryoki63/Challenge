#!/usr/bin/env python3
"""Lien 植物育成スプライト v3 / style_f「モダンレトロ」ジェネレータ。

48x64 px・透過。v0/v2 の「文字列グリッド手打ち」を全廃し、
**幾何計算(円・楕円・角丸矩形のunion + 水平ミラー)**で描く。
曲線のガタつき・左右非対称・顔の歪み(=キモさの根源)を構造的に排除する。

スタイル: モダンレトロ(Stardew Valley 的な高品質ドット絵)
  - 輪郭: 真っ黒ではなく色相寄りのダーク(葉=ディープグリーン #1F5E38 /
    鉢=ダークブラウン #6E3F22 / 花=深ローズ #B5476B)。自動輪郭抽出で外周1px。
  - 塗り: 3トーンセルシェード(左上ライト / ベース / 右下シャドウ)
    + 頭頂に1pxリムライト。
  - 配色: ライムグリーン + コーラルピンクの花 + クリーム花芯 + 明るいテラコッタ。

顔(2回差し戻しの教訓 — 最重要):
  - 目: ベタ塗りこげ茶の丸目(5x7px)、中心間19px、右上に白ハイライト1個(2x2)
  - 口: 目の下に小さな笑みの弧(幅6px)
  - ほっぺ: 薄ピンクの楕円 4x3px、控えめ
  - 眉・鼻なし。顔は植物本体(ブロブ)に置く

6キーフレーム: soil / sprout / mid / late / final_normal / final_happy
鉢は全フレーム同位置(足元固定)。すべて決定論(乱数・時刻不使用)。

出力:
  png/<name>.png     原寸 48x64(6枚)
  contact_sheet.png  4倍ニアレストネイバー・クリーム背景・成長順

使い方:
  python3 gen.py
"""

import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PNG_DIR = os.path.join(HERE, "png")
SHEET_PATH = os.path.join(HERE, "contact_sheet.png")

W, H = 48, 64
SCALE = 4
AXIS = W / 2.0  # 24.0 — ピクセル中心 x+0.5 がこの軸に対して対称

SHEET_BG = (0xFB, 0xF3, 0xE2, 0xFF)  # あたたかいクリーム

# ---------------------------------------------------------------------------
# パレット(部位ごとに light / base / shadow / rim / outline の3トーン+α)
# ---------------------------------------------------------------------------
PAL = {
    "body": {
        "light":   (0xC6, 0xF4, 0x9A),
        "base":    (0x8E, 0xE0, 0x66),
        "shadow":  (0x5C, 0xB5, 0x46),
        "rim":     (0xE9, 0xFF, 0xCF),
        "outline": (0x1F, 0x5E, 0x38),
    },
    "leaf": {
        "light":   (0xB6, 0xEC, 0x88),
        "base":    (0x6F, 0xC8, 0x51),
        "shadow":  (0x4F, 0xA1, 0x3C),
        "rim":     (0xE9, 0xFF, 0xCF),
        "outline": (0x1F, 0x5E, 0x38),
    },
    "stem": {
        "base":    (0x5C, 0xB5, 0x46),
        "shadow":  (0x4C, 0x9D, 0x3A),
        "outline": (0x1F, 0x5E, 0x38),
    },
    "pot": {
        "light":   (0xF2, 0xBA, 0x8C),
        "base":    (0xE0, 0x96, 0x63),
        "shadow":  (0xC2, 0x76, 0x46),
        "rim":     (0xFA, 0xD7, 0xAF),
        "outline": (0x6E, 0x3F, 0x22),
    },
    "soil": {
        "light":   (0xA9, 0x75, 0x4B),
        "base":    (0x8A, 0x5A, 0x35),
        "shadow":  (0x6B, 0x44, 0x26),
        "outline": (0x4F, 0x2F, 0x18),
    },
    "petal": {
        "light":   (0xFF, 0xB9, 0xC9),
        "base":    (0xFF, 0x8F, 0xA3),
        "shadow":  (0xE8, 0x6E, 0x8C),
        "rim":     (0xFF, 0xD6, 0xDF),
        "outline": (0xB5, 0x47, 0x6B),
    },
    "fcenter": {
        "light":   (0xFF, 0xF0, 0xBE),
        "base":    (0xFF, 0xE0, 0x8A),
        "shadow":  (0xEC, 0xC2, 0x60),
        "outline": (0xC8, 0x8F, 0x3E),
    },
}

EYE = (0x3D, 0x2A, 0x1C)       # ベタ塗りこげ茶
WHITE = (0xFF, 0xFF, 0xFF)
CHEEK = (0xFF, 0xBE, 0xCC)     # 薄ピンク(控えめ)
SPARK = (0xFF, 0xD9, 0x6E)     # キラキラ(ゴールド)

# ---------------------------------------------------------------------------
# 幾何プリミティブ(マスク = set[(x,y)])。ピクセル中心 (x+0.5, y+0.5) で判定。
# ---------------------------------------------------------------------------

def fill_ellipse(cx, cy, rx, ry):
    """楕円マスク。cx を *.5 にすると奇数幅・整数にすると偶数幅で左右対称。"""
    m = set()
    x0, x1 = int(cx - rx - 1), int(cx + rx + 1)
    y0, y1 = int(cy - ry - 1), int(cy + ry + 1)
    for y in range(max(0, y0), min(H, y1 + 1)):
        for x in range(max(0, x0), min(W, x1 + 1)):
            dx = (x + 0.5 - cx) / rx
            dy = (y + 0.5 - cy) / ry
            if dx * dx + dy * dy <= 1.0:
                m.add((x, y))
    return m


def fill_circle(cx, cy, r):
    return fill_ellipse(cx, cy, r, r)


def fill_rounded_rect(x0, y0, x1, y1, rad):
    """角丸矩形マスク(x0..x1, y0..y1 を含む、角を rad px 丸める)。"""
    m = set()
    for y in range(max(0, y0), min(H, y1 + 1)):
        for x in range(max(0, x0), min(W, x1 + 1)):
            px, py = x + 0.5, y + 0.5
            qx = max(x0 + rad + 0.5 - px, px - (x1 - rad + 0.5), 0.0)
            qy = max(y0 + rad + 0.5 - py, py - (y1 - rad + 0.5), 0.0)
            if qx * qx + qy * qy <= rad * rad + 0.25:
                m.add((x, y))
    return m


def trapezoid(y0, y1, hw_top, hw_bot, shrink_last=1.0):
    """中心軸 AXIS の左右対称台形。hw=半幅。最下行は shrink_last 縮めて角を丸く。"""
    m = set()
    for y in range(max(0, y0), min(H, y1 + 1)):
        t = (y - y0) / float(max(1, y1 - y0))
        hw = hw_top + (hw_bot - hw_top) * t
        if y == y1:
            hw -= shrink_last
        for x in range(W):
            if abs(x + 0.5 - AXIS) <= hw:
                m.add((x, y))
    return m


def blob(*masks):
    """複数マスクの union ブロブ。"""
    u = set()
    for m in masks:
        u |= m
    return u


def mirror(mask):
    """水平ミラー(軸 = キャンバス中央)。左半分を描いて対称を保証する。"""
    return {(W - 1 - x, y) for (x, y) in mask}


def sym(mask):
    """マスク + その鏡像。"""
    return mask | mirror(mask)


# ---------------------------------------------------------------------------
# 仕上げパス: 自動輪郭(外周1px・8近傍)+ 3トーンセルシェード + リムライト
# ---------------------------------------------------------------------------

def paint_part(canvas, mask, pal, shade=True, rim_top=True):
    """パーツを canvas(dict[(x,y)]=rgb)へ描画。
    手順: ①マスクの外周1pxに輪郭色(8近傍 dilation - mask)
          ②マスク内をセルシェード(左上→light / 右下→shadow / 頭頂→rim)
    パーツを奥→手前の順に paint するので、輪郭が自然な区切り線になる。"""
    if not mask:
        return
    if pal.get("outline"):
        oc = pal["outline"]
        for (x, y) in mask:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    q = (x + dx, y + dy)
                    if q not in mask and 0 <= q[0] < W and 0 <= q[1] < H:
                        canvas[q] = oc
    ymin = min(y for (_, y) in mask)
    for (x, y) in mask:
        c = pal["base"]
        if shade:
            lt = (x - 2, y - 2) not in mask
            sh = (x + 2, y + 2) not in mask
            if rim_top and pal.get("rim") and y <= ymin + 1 and (x, y - 1) not in mask:
                c = pal["rim"]
            elif lt and not sh and pal.get("light"):
                c = pal["light"]
            elif sh and not lt and pal.get("shadow"):
                c = pal["shadow"]
        canvas[(x, y)] = c


def paint_flat(canvas, mask, color):
    for p in mask:
        canvas[p] = color


# ---------------------------------------------------------------------------
# 共通パーツ: 鉢 + 土(全フレーム同位置・足元固定)
# ---------------------------------------------------------------------------
POT_RIM_TOP = 50  # 鉢の上端 y。鉢全体は y50..63(高さ14px)

def soil_mask():
    # ベースの土 + 中央の盛り土(山)。山は大きい本体の後ろに隠れる位置。
    return blob(fill_ellipse(AXIS, 49.0, 10.0, 3.5),
                fill_ellipse(AXIS, 47.5, 4.5, 2.6))


def pot_body_mask():
    return trapezoid(54, 63, 12.0, 9.5, shrink_last=1.0)


def pot_rim_mask():
    return fill_rounded_rect(int(AXIS) - 14, POT_RIM_TOP, int(AXIS) + 13, POT_RIM_TOP + 4, 2)


def draw_pot(canvas):
    paint_part(canvas, pot_body_mask(), PAL["pot"], shade=True, rim_top=False)
    paint_part(canvas, pot_rim_mask(), PAL["pot"], shade=True, rim_top=True)


def draw_soil_behind(canvas):
    m = soil_mask()
    paint_part(canvas, m, PAL["soil"], shade=True, rim_top=False)
    # 土の小石(ミラーで対称)
    paint_flat(canvas, sym({(18, 48)}), PAL["soil"]["shadow"])


# ---------------------------------------------------------------------------
# 顔(植物本体の上に重ねる。輪郭なし・シェードなしのフラット描画)
# ---------------------------------------------------------------------------

def draw_face(canvas, eye_cy, sep, eye_rx=2.6, eye_ry=3.0,
              mouth_dy=6, mouth_hw=3, cheek_dx=11.5, cheek_dy=5.0,
              cheek_rx=2.1, cheek_ry=1.6, hl_size=2, happy=False):
    """sep = 目の中心間距離(px)。左目を描いてミラー(対称保証)。"""
    cl = AXIS - sep / 2.0  # 左目中心 x

    if happy:
        # にこにこ弧目(^ ^)。左目をピクセル定義(対称形)→ ミラー。
        ex = int(cl)  # 中心列(cl は *.5 → 中心列 = int(cl))
        ey = int(eye_cy) - 1
        left = {(ex + d, ey) for d in (-2, -1, 0, 1, 2)} | \
               {(ex + d, ey + 1) for d in (-3, -2, 2, 3)}
        paint_flat(canvas, left | mirror(left), EYE)
    else:
        # ベタ塗りこげ茶の丸目 + 右上に白ハイライト1個(hl_size 角)
        left_eye = fill_ellipse(cl, eye_cy, eye_rx, eye_ry)
        right_eye = mirror(left_eye)
        paint_flat(canvas, left_eye | right_eye, EYE)
        hx, hy = int(cl), int(eye_cy - eye_ry) + 1
        hl = {(hx + dx, hy + dy) for dx in range(hl_size) for dy in range(hl_size)}
        # 両目とも「右上」。目マスク内にクリップしてはみ出しを防ぐ。
        paint_flat(canvas, hl & left_eye, WHITE)
        paint_flat(canvas, {(x + round(sep), y) for (x, y) in hl} & right_eye, WHITE)

    # ほっぺ(薄ピンク楕円・控えめ)
    cheek = fill_ellipse(AXIS - cheek_dx, eye_cy + cheek_dy, cheek_rx, cheek_ry)
    paint_flat(canvas, cheek | mirror(cheek), CHEEK)

    # 口: 小さな笑みの弧(幅 2*mouth_hw)。左半分 → ミラー。
    my = int(eye_cy + mouth_dy)
    mx = int(AXIS - mouth_hw)  # 左端列
    left_m = {(mx, my)} | {(mx + 1 + d, my + 1) for d in range(mouth_hw - 1)}
    paint_flat(canvas, left_m | mirror(left_m), EYE)


def draw_sparkle(canvas, cx, cy, arm=2):
    """キラキラ(十字星)。腕=ゴールド、中心=白。"""
    pts = set()
    for d in range(1, arm + 1):
        pts |= {(cx + d, cy), (cx - d, cy), (cx, cy + d), (cx, cy - d)}
    paint_flat(canvas, pts, SPARK)
    paint_flat(canvas, {(cx, cy)}, WHITE)


# ---------------------------------------------------------------------------
# 葉・茎・花
# ---------------------------------------------------------------------------

def leaf_pair(cx_off, cy, r_in, r_out, tilt_dx=-1.8, tilt_dy=-1.2):
    """丸葉ペア: 2円のunionで斜め上外向きの丸葉 → ミラー。
    頭の上の茎に付く「植物の葉」(頭から直接生やすと耳に見えるため禁止)。"""
    c1 = fill_circle(AXIS - cx_off, cy, r_in)
    c2 = fill_circle(AXIS - cx_off + tilt_dx, cy + tilt_dy, r_out)
    left = blob(c1, c2)
    return left, mirror(left)


def stem_mask(y_top, y_bot):
    return {(x, y) for y in range(y_top, y_bot + 1)
            for x in range(W) if abs(x + 0.5 - AXIS) <= 1.0}


def flower_masks(cy):
    """花冠: 中央クリーム + 周囲6枚のコーラル花びら(ミラー対称配置)。"""
    petals = blob(
        fill_circle(AXIS, cy - 4.8, 3.3),            # 上
        fill_circle(AXIS, cy + 4.8, 3.3),            # 下
        sym(fill_circle(AXIS - 4.2, cy - 2.4, 3.3)), # 斜め上
        sym(fill_circle(AXIS - 4.2, cy + 2.4, 3.3)), # 斜め下
    )
    center = fill_circle(AXIS, cy, 2.9)
    return petals, center


# ---------------------------------------------------------------------------
# キーフレーム定義
# ---------------------------------------------------------------------------
SHEET_ORDER = ["soil", "sprout", "mid", "late", "final_normal", "final_happy"]


def body_mask(stage):
    if stage == "sprout":
        return blob(fill_ellipse(AXIS, 43.5, 6.5, 6.0))
    if stage == "mid":
        return blob(fill_ellipse(AXIS, 40.5, 9.0, 8.0),
                    fill_ellipse(AXIS, 44.5, 10.0, 7.0))
    if stage == "late":
        return blob(fill_ellipse(AXIS, 38.0, 11.0, 9.5),
                    fill_ellipse(AXIS, 43.0, 12.0, 8.5))
    # final
    return blob(fill_ellipse(AXIS, 36.5, 12.5, 11.0),
                fill_ellipse(AXIS, 42.0, 14.0, 9.5))


def build_frame(name):
    canvas = {}
    draw_soil_behind(canvas)

    if name == "soil":
        draw_pot(canvas)
        return canvas

    if name == "sprout":
        # 頭上の短い茎 + 双葉(芽)。葉は頭ではなく茎に付ける(耳化防止)
        paint_part(canvas, stem_mask(33, 39), PAL["stem"], shade=True, rim_top=False)
        lleaf, rleaf = leaf_pair(3.8, 32.5, 2.4, 1.9, tilt_dx=-1.5, tilt_dy=-1.0)
        paint_part(canvas, lleaf, PAL["leaf"])
        paint_part(canvas, rleaf, PAL["leaf"])
        paint_part(canvas, body_mask("sprout"), PAL["body"])
        draw_pot(canvas)
        draw_face(canvas, eye_cy=42.5, sep=8, eye_rx=1.9, eye_ry=2.3,
                  mouth_dy=4, mouth_hw=2, cheek_dx=4.5, cheek_dy=3.0,
                  cheek_rx=1.6, cheek_ry=1.2, hl_size=1)
        return canvas

    if name == "mid":
        # 茎が伸び、本葉2枚に
        paint_part(canvas, stem_mask(27, 34), PAL["stem"], shade=True, rim_top=False)
        lleaf, rleaf = leaf_pair(4.5, 27.5, 2.7, 2.1, tilt_dx=-1.9, tilt_dy=-1.3)
        paint_part(canvas, lleaf, PAL["leaf"])
        paint_part(canvas, rleaf, PAL["leaf"])
        paint_part(canvas, body_mask("mid"), PAL["body"])
        draw_pot(canvas)
        draw_face(canvas, eye_cy=39.5, sep=12, eye_rx=2.2, eye_ry=2.7,
                  mouth_dy=6, mouth_hw=3, cheek_dx=8.5, cheek_dy=4.5,
                  cheek_rx=1.9, cheek_ry=1.4, hl_size=2)
        return canvas

    if name == "late":
        # つぼみ + 茎の本葉
        paint_part(canvas, stem_mask(21, 30), PAL["stem"], shade=True, rim_top=False)
        bud = fill_circle(AXIS, 19.5, 3.4)
        lleaf, rleaf = leaf_pair(4.8, 25.0, 2.9, 2.3, tilt_dx=-2.0, tilt_dy=-1.4)
        paint_part(canvas, lleaf, PAL["leaf"])
        paint_part(canvas, rleaf, PAL["leaf"])
        paint_part(canvas, body_mask("late"), PAL["body"])
        draw_pot(canvas)
        paint_part(canvas, bud, PAL["petal"])
        draw_face(canvas, eye_cy=36.5, sep=17, eye_rx=2.6, eye_ry=3.0,
                  mouth_dy=7, mouth_hw=3, cheek_dx=10.0, cheek_dy=5.0)
        return canvas

    # final_normal / final_happy: 開花
    paint_part(canvas, stem_mask(20, 27), PAL["stem"], shade=True, rim_top=False)
    lleaf, rleaf = leaf_pair(6.0, 22.0, 2.9, 2.3, tilt_dx=-2.2, tilt_dy=-1.5)
    paint_part(canvas, lleaf, PAL["leaf"])
    paint_part(canvas, rleaf, PAL["leaf"])
    paint_part(canvas, body_mask("final"), PAL["body"])
    draw_pot(canvas)
    petals, center = flower_masks(12.5)
    paint_part(canvas, petals, PAL["petal"])
    paint_part(canvas, center, PAL["fcenter"])
    happy = name == "final_happy"
    draw_face(canvas, eye_cy=35.5, sep=19, eye_rx=2.6, eye_ry=3.0,
              mouth_dy=7, mouth_hw=3, cheek_dx=11.5, cheek_dy=5.5, happy=happy)
    if happy:
        draw_sparkle(canvas, 9, 18, arm=2)
        draw_sparkle(canvas, 39, 10, arm=2)
        draw_sparkle(canvas, 42, 24, arm=1)
        draw_sparkle(canvas, 6, 8, arm=1)
    return canvas


# ---------------------------------------------------------------------------
# PNG 書き出し(v2 gen.py から流用・キャンバスは dict ベースに変更)
# ---------------------------------------------------------------------------

def canvas_to_rgba(canvas):
    rows = []
    for y in range(H):
        line = bytearray()
        for x in range(W):
            c = canvas.get((x, y))
            if c is None:
                line += b"\x00\x00\x00\x00"
            else:
                line += bytes(c) + b"\xff"
        rows.append(line)
    return rows


def write_png(path, width, height, rgba_rows):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(r) for r in rgba_rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    blob_ = (b"\x89PNG\r\n\x1a\n"
             + chunk(b"IHDR", ihdr)
             + chunk(b"IDAT", zlib.compress(raw, 9))
             + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(blob_)


def scale_rows(rgba_rows, factor):
    out = []
    for row in rgba_rows:
        scaled = bytearray()
        for i in range(0, len(row), 4):
            scaled += row[i:i + 4] * factor
        for _ in range(factor):
            out.append(scaled)
    return out


def read_png_size(path):
    with open(path, "rb") as f:
        head = f.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise ValueError("not a PNG: %s" % path)
    w, h = struct.unpack(">II", head[16:24])
    return w, h


def make_contact_sheet(sprites_big):
    pad = 4 * SCALE
    cell_w, cell_h = W * SCALE, H * SCALE
    cols = len(SHEET_ORDER)
    sheet_w = pad + cols * (cell_w + pad)
    sheet_h = pad + (cell_h + pad)
    sheet = [bytearray(bytes(SHEET_BG) * sheet_w) for _ in range(sheet_h)]
    for gx, name in enumerate(SHEET_ORDER):
        x0 = pad + gx * (cell_w + pad)
        y0 = pad
        big = sprites_big[name]
        for dy, line in enumerate(big):
            dest = sheet[y0 + dy]
            for dx in range(cell_w):
                if line[dx * 4 + 3] == 0xFF:
                    dest[(x0 + dx) * 4:(x0 + dx) * 4 + 4] = line[dx * 4:dx * 4 + 4]
    return sheet, sheet_w, sheet_h


# ---------------------------------------------------------------------------
# 自己検証
# ---------------------------------------------------------------------------

def alpha_mask(canvas):
    return set(canvas.keys())


def verify(frames):
    # 1) シルエット左右対称(キラキラを含む final_happy は除外)
    for name in SHEET_ORDER:
        if name == "final_happy":
            continue
        m = alpha_mask(frames[name])
        assert m == mirror(m), "%s: silhouette not symmetric" % name
    # 2) 足元固定: 鉢ボディ領域(y>=55)が全フレーム同一色
    ref = {p: frames["soil"][p] for p in frames["soil"] if p[1] >= 55}
    for name in SHEET_ORDER:
        cur = {p: frames[name][p] for p in frames[name] if p[1] >= 55}
        assert cur == ref, "%s: pot footprint differs" % name
    # 3) 最終形の目仕様: 高さ5-7px・中心間18-22px
    eye_px = {p for p, c in frames["final_normal"].items() if c == EYE and p[1] <= 40}
    left = {(x, y) for (x, y) in eye_px if x < AXIS}
    h_left = max(y for _, y in left) - min(y for _, y in left) + 1
    assert 5 <= h_left <= 7, "eye height %d out of spec" % h_left
    lcx = (min(x for x, _ in left) + max(x for x, _ in left) + 1) / 2.0
    sep = (AXIS - lcx) * 2
    assert 18 <= sep <= 22, "eye separation %.1f out of spec" % sep


def main():
    os.makedirs(PNG_DIR, exist_ok=True)
    frames = {name: build_frame(name) for name in SHEET_ORDER}
    verify(frames)

    sprites_big = {}
    for name in SHEET_ORDER:
        rgba = canvas_to_rgba(frames[name])
        write_png(os.path.join(PNG_DIR, name + ".png"), W, H, rgba)
        sprites_big[name] = scale_rows(rgba, SCALE)

    sheet, sw, sh = make_contact_sheet(sprites_big)
    write_png(SHEET_PATH, sw, sh, sheet)

    for name in SHEET_ORDER:
        w, h = read_png_size(os.path.join(PNG_DIR, name + ".png"))
        assert (w, h) == (W, H), name
    print("OK: 6 keyframes 48x64 -> %s" % PNG_DIR)
    print("OK: contact_sheet %dx%d -> %s" % (sw, sh, SHEET_PATH))
    return 0


if __name__ == "__main__":
    sys.exit(main())
