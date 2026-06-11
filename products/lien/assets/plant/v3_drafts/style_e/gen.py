#!/usr/bin/env python3
"""Lien plant sprites v3 — style_e「クラシックたまごっち HD」

48x64px・プロシージャル描画(手打ちグリッド廃止)。
- 幾何計算(楕円・回転楕円・角丸矩形・ブロブunion)で曲線を描く
- 左右対称はミラーマスクで保証(cx=23.5 を軸)
- パーツごとに 1px の輪郭リング(8近傍)を自動付与 → 最後に外周をもう 1px 締める
- セルシェード: 右下に影トーン、左上にライトの三日月、頭頂ハイライト
- 完全決定論(乱数・時刻なし)。python3 標準ライブラリのみ。

実行: python3 gen.py
出力: png/ に原寸6枚 + contact_sheet.png(4倍・クリーム背景)
"""

import math
import os
import struct
import zlib

# ---------------------------------------------------------------- 基本定数
W, H = 48, 64
CX = (W - 1) / 2.0          # 23.5 — 対称軸
SCALE = 4

HERE = os.path.dirname(os.path.abspath(__file__))
PNG_DIR = os.path.join(HERE, "png")
SHEET_PATH = os.path.join(HERE, "contact_sheet.png")

# ---------------------------------------------------------------- パレット
OUTLINE   = (0x2D, 0x2A, 0x26)   # ソフトブラック輪郭
GREEN     = (0x7F, 0xD6, 0x5C)   # 本体ベース
GREEN_SH  = (0x4F, 0xA6, 0x4F)   # 本体 影
GREEN_LT  = (0xB8, 0xF2, 0x91)   # 本体 ライト
POT       = (0xD9, 0x8E, 0x5A)   # 鉢 テラコッタ
POT_SH    = (0xB0, 0x6A, 0x3F)   # 鉢 影
PINK      = (0xFF, 0x9E, 0xB5)   # 花びら
PINK_DK   = (0xE5, 0x6E, 0x8F)   # 花びら 濃
CHEEK     = (0xFF, 0xC2, 0xD1)   # ほっぺ(薄ピンク)
YELLOW    = (0xFF, 0xD9, 0x66)   # 花芯・キラキラ
EYE       = (0x3B, 0x2F, 0x2A)   # 目(こげ茶ベタ)
WHITE     = (0xFF, 0xFF, 0xFF)
SOIL      = (0x8A, 0x5A, 0x3B)
SOIL_DK   = (0x6B, 0x42, 0x26)
SHEET_BG  = (0xFF, 0xF6, 0xE3)   # クリーム背景(シートのみ)

# ---------------------------------------------------------------- 幾何ヘルパー
def in_ellipse(px, py, cx, cy, rx, ry, rot=0.0):
    dx, dy = px - cx, py - cy
    if rot:
        c, s = math.cos(rot), math.sin(rot)
        dx, dy = dx * c + dy * s, -dx * s + dy * c
    return (dx / rx) ** 2 + (dy / ry) ** 2 <= 1.0


def _bbox(cx, cy, rx, ry):
    m = max(rx, ry) + 1.0
    return (int(math.floor(cx - m)), int(math.floor(cy - m)),
            int(math.ceil(cx + m)), int(math.ceil(cy + m)))


def part_ellipse(part, cx, cy, rx, ry, color, rot=0.0):
    x0, y0, x1, y1 = _bbox(cx, cy, rx, ry)
    for y in range(max(0, y0), min(H, y1 + 1)):
        for x in range(max(0, x0), min(W, x1 + 1)):
            if in_ellipse(x, y, cx, cy, rx, ry, rot):
                part[(x, y)] = color


def part_round_rect(part, x0, y0, x1, y1, r, color):
    for y in range(max(0, int(math.floor(y0))), min(H, int(math.ceil(y1)) + 1)):
        for x in range(max(0, int(math.floor(x0))), min(W, int(math.ceil(x1)) + 1)):
            if x0 <= x <= x1 and y0 <= y <= y1:
                dx = max(x0 + r - x, 0, x - (x1 - r))
                dy = max(y0 + r - y, 0, y - (y1 - r))
                if dx * dx + dy * dy <= r * r + 0.3:
                    part[(x, y)] = color


def mirror_part(part):
    """左右ミラー(x → W-1-x)。対称保証用。"""
    return {(W - 1 - x, y): c for (x, y), c in part.items()}


def smile_arc(part, cx, cy, rw, rh, thick, color):
    """下向きに開いた口角上がりの弧(にっこり口)= 楕円の下側三日月。"""
    x0, y0, x1, y1 = _bbox(cx, cy, rw, rh)
    for y in range(max(0, y0), min(H, y1 + 1)):
        for x in range(max(0, x0), min(W, x1 + 1)):
            if (y >= cy - 0.01
                    and in_ellipse(x, y, cx, cy, rw, rh)
                    and not in_ellipse(x, y, cx, cy - thick, rw, rh)):
                part[(x, y)] = color


def happy_arc(part, cx, cy, rw, rh, thick, color):
    """上向きの弧(にこにこ目 ∩)= 楕円の上側三日月。"""
    x0, y0, x1, y1 = _bbox(cx, cy, rw, rh)
    for y in range(max(0, y0), min(H, y1 + 1)):
        for x in range(max(0, x0), min(W, x1 + 1)):
            if (y <= cy + 0.01
                    and in_ellipse(x, y, cx, cy, rw, rh)
                    and not in_ellipse(x, y, cx, cy + thick, rw, rh)):
                part[(x, y)] = color


# ---------------------------------------------------------------- 描画(バッファ操作)
def new_buf():
    return [[None] * W for _ in range(H)]


def stamp(buf, part):
    """パーツを輪郭リング付きで貼る。後から貼るパーツほど手前。"""
    ring = set()
    for (x, y) in part:
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                n = (x + dx, y + dy)
                if n not in part:
                    ring.add(n)
    for (x, y) in ring:
        if 0 <= x < W and 0 <= y < H:
            buf[y][x] = OUTLINE
    for (x, y), c in part.items():
        buf[y][x] = c


def paint(buf, part, mask=None):
    """輪郭なしでそのまま塗る(顔・チーク・キラキラ用)。mask指定で領域内に限定。"""
    for (x, y), c in part.items():
        if mask is None or (x, y) in mask:
            buf[y][x] = c


def outer_outline(buf):
    """不透明領域の外周1pxに輪郭色を付与(外側をもう1px太らせて締める)。"""
    add = []
    for y in range(H):
        for x in range(W):
            if buf[y][x] is not None:
                continue
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < W and 0 <= ny < H and buf[ny][nx] is not None:
                        add.append((x, y))
                        break
                else:
                    continue
                break
    for (x, y) in add:
        buf[y][x] = OUTLINE


# ---------------------------------------------------------------- パーツビルダー
def build_blob(cx, cy, rx, ry):
    """本体ブロブ。メイン楕円 ∪ 下ぶくれ楕円(たまご形)+ セルシェード。"""
    bcy, brx, bry = cy + ry * 0.30, rx * 1.05, ry * 0.62
    part = {}
    x0, y0, x1, y1 = _bbox(cx, cy, max(rx, brx), ry + bry)
    for y in range(max(0, y0), min(H, y1 + 1)):
        for x in range(max(0, x0), min(W, x1 + 1)):
            if not (in_ellipse(x, y, cx, cy, rx, ry)
                    or in_ellipse(x, y, cx, bcy, brx, bry)):
                continue
            dx, dy = x - cx, y - cy
            col = GREEN
            # 右下の影トーン(光源=左上)
            if (dx + dy > rx * 0.10
                    and not in_ellipse(x, y, cx - rx * 0.10 - 0.6, cy - ry * 0.10 - 0.6,
                                       rx * 0.92, ry * 0.92)):
                col = GREEN_SH
            # 左上のライト三日月
            elif (dx + dy * 1.2 < -rx * 0.15
                  and not in_ellipse(x, y, cx + rx * 0.10 + 0.6, cy + ry * 0.10 + 0.6,
                                     rx * 0.88, ry * 0.88)):
                col = GREEN_LT
            part[(x, y)] = col
    # 頭頂の小ハイライト
    hl = {}
    part_ellipse(hl, cx - rx * 0.18, cy - ry * 0.74, rx * 0.30, max(1.3, ry * 0.15), GREEN_LT)
    for k, c in hl.items():
        if k in part:
            part[k] = c
    return part


def build_pot():
    """鉢(全フレーム固定)。リム y47..51 + 台形 y52..60、高さ14px。"""
    part = {}
    part_round_rect(part, 11, 47, 36, 51, 1.6, POT)
    for y in range(52, 61):
        t = (y - 52) / 8.0
        hw = 10.5 - 2.0 * t
        for x in range(W):
            if abs(x - CX) <= hw:
                if y == 52:
                    part[(x, y)] = POT_SH          # リム下の落ち影
                elif (x - CX) > hw - 3.2:
                    part[(x, y)] = POT_SH          # 右側の縦影
                else:
                    part[(x, y)] = POT
    return part


def build_leaf(cx_off, cy, rx, ry, rot):
    """丸葉(左を作って右はミラー)。下半分をうっすら影色に。"""
    left = {}
    part_ellipse(left, CX - cx_off, cy, rx, ry, GREEN, rot)
    for (x, y) in list(left):
        if y > cy + ry * 0.25:
            left[(x, y)] = GREEN_SH
    return left, mirror_part(left)


def face_parts(eye_dx, eye_y, eye_r, mouth_y, mouth_rw, cheek_dx, cheek_y,
               cheek_rx, cheek_ry, happy=False):
    """目・口・ほっぺ。左目を作って右目はミラー、ハイライトは両目とも右上(非ミラー)。"""
    face = {}
    # 目 — ベタ塗りのこげ茶丸目
    left_eye = {}
    if happy:
        happy_arc(left_eye, CX - eye_dx, eye_y, eye_r + 0.4, eye_r + 0.1, 1.7, EYE)
    else:
        part_ellipse(left_eye, CX - eye_dx, eye_y, eye_r, eye_r + 0.15, EYE)
    face.update(left_eye)
    face.update(mirror_part(left_eye))
    # ハイライト — 各目の右上に 2x2 を1個だけ(開き目のときのみ)
    if not happy:
        for ex in (CX - eye_dx, CX + eye_dx):
            hx = int(round(ex + eye_r * 0.30))
            hy = int(round(eye_y - eye_r * 0.45)) - 1
            for (px, py) in ((hx, hy), (hx + 1, hy), (hx, hy + 1), (hx + 1, hy + 1)):
                face[(px, py)] = WHITE
    # ほっぺ — 目の斜め下外側、薄ピンクの楕円(本体maskでクリップして貼る)
    lc = {}
    part_ellipse(lc, CX - cheek_dx, cheek_y, cheek_rx, cheek_ry, CHEEK)
    face.update(lc)
    face.update(mirror_part(lc))
    # 口 — 小さな笑みの弧
    smile_arc(face, CX, mouth_y, mouth_rw, mouth_rw * 0.9, 1.6, EYE)
    return face


def build_flower(fy):
    """花冠 — ピンク5枚花びら + 黄色花芯(left半分を作ってミラー)。"""
    R, pr = 5.4, 3.5
    offs = [(0.0, -R),
            (-R * 0.951, -R * 0.309), (R * 0.951, -R * 0.309),
            (-R * 0.588, R * 0.809), (R * 0.588, R * 0.809)]
    petals = {}
    for ox, oy in offs:
        if ox > 0:
            continue                      # 左+中央のみ → 右はミラー
        part_ellipse(petals, CX + ox, fy + oy, pr, pr, PINK)
    petals.update(mirror_part(petals))
    for (x, y) in list(petals):
        if y > fy + 2.4:
            petals[(x, y)] = PINK_DK      # 下側の花びらを濃く
    center = {}
    part_ellipse(center, CX, fy, 2.9, 2.9, YELLOW)
    return petals, center


def add_sparkle(part, x, y, arm):
    for d in range(-arm, arm + 1):
        part[(x + d, y)] = YELLOW
        part[(x, y + d)] = YELLOW
    part[(x, y)] = WHITE


# ---------------------------------------------------------------- フレーム
def frame_soil():
    """土 + 眠る種(閉じ目でスヤスヤ)。"""
    buf = new_buf()
    soil = {}
    part_ellipse(soil, CX, 47.4, 10.5, 3.6, SOIL)
    for (x, y) in list(soil):
        if y >= 47:
            soil[(x, y)] = SOIL_DK
    stamp(buf, soil)
    seed = build_blob(CX, 41.5, 7.0, 5.5)
    stamp(buf, seed)
    face = {}
    le = {}
    happy_arc(le, CX - 3.6, 41.0, 2.0, 1.9, 1.5, EYE)
    face.update(le)
    face.update(mirror_part(le))
    smile_arc(face, CX, 43.8, 1.7, 1.6, 1.3, EYE)
    lc = {}
    part_ellipse(lc, CX - 5.4, 42.8, 1.6, 1.2, CHEEK)
    face.update(lc)
    face.update(mirror_part(lc))
    paint(buf, face, mask=set(seed))
    stamp(buf, build_pot())
    outer_outline(buf)
    return buf


def _stage(blob_args, eye, mouth_y, mouth_rw, cheek, leaves=None,
           crown=None, happy=False, sparkles=None):
    cx, cy, rx, ry = blob_args
    buf = new_buf()
    if leaves:
        for lf in leaves:
            stamp(buf, lf)
    body = build_blob(cx, cy, rx, ry)
    stamp(buf, body)
    stamp(buf, build_pot())
    paint(buf, face_parts(*eye, mouth_y, mouth_rw, *cheek, happy=happy),
          mask=set(body))
    if crown:
        for p in crown:
            stamp(buf, p)
    outer_outline(buf)
    if sparkles:
        sp = {}
        for (sx, sy, arm) in sparkles:
            add_sparkle(sp, sx, sy, arm)
        paint(buf, sp)
    return buf


def frame_sprout():
    stem = {}
    part_round_rect(stem, 23, 27.0, 24, 34.0, 1.0, GREEN)
    l, r = build_leaf(4.3, 27.0, 3.9, 2.1, 0.55)
    return _stage((CX, 42.5, 9.0, 9.5),
                  eye=(5.5, 41.0, 2.2), mouth_y=45.3, mouth_rw=2.3,
                  cheek=(8.2, 43.3, 1.9, 1.4),
                  leaves=[l, r, stem])


def frame_mid():
    # 横に張り出して垂れる丸葉(耳に見えないよう水平寄り)+ 頭頂に小さな双葉
    l, r = build_leaf(13.0, 32.5, 6.5, 2.8, -0.22)
    tip = {}
    part_ellipse(tip, CX - 3.7, 25.0, 2.9, 1.6, GREEN, 0.80)
    tip.update(mirror_part(tip))
    return _stage((CX, 39.5, 12.0, 12.5),
                  eye=(8.0, 38.0, 2.6), mouth_y=42.8, mouth_rw=2.7,
                  cheek=(10.5, 40.5, 2.3, 1.7),
                  leaves=[l, r], crown=[tip])


def frame_late():
    l, r = build_leaf(14.5, 30.0, 6.5, 2.9, -0.22)
    stem = {}
    part_round_rect(stem, 23, 17.0, 24, 25.0, 1.0, GREEN)
    bud = {}
    part_ellipse(bud, CX, 15.5, 3.1, 3.1, PINK)
    for (x, y) in list(bud):
        if y > 16.1:
            bud[(x, y)] = PINK_DK
    return _stage((CX, 38.0, 13.5, 14.0),
                  eye=(9.0, 36.5, 2.9), mouth_y=41.5, mouth_rw=2.9,
                  cheek=(12.0, 39.0, 2.5, 1.8),
                  leaves=[l, r], crown=[stem, bud])


def _final(happy):
    l, r = build_leaf(16.0, 28.0, 6.6, 3.0, -0.22)
    petals, center = build_flower(13.5)
    sparkles = [(8, 12, 1), (40, 7, 2), (43, 17, 1)] if happy else None
    return _stage((CX, 36.5, 15.0, 15.5),
                  eye=(10.0, 35.0, 3.1), mouth_y=40.2, mouth_rw=3.0,
                  cheek=(13.0, 37.5, 2.6, 1.9),
                  leaves=[l, r], crown=[petals, center],
                  happy=happy, sparkles=sparkles)


FRAMES = [
    ("01_soil", frame_soil),
    ("02_sprout", frame_sprout),
    ("03_mid", frame_mid),
    ("04_late", frame_late),
    ("05_final_normal", lambda: _final(False)),
    ("06_final_happy", lambda: _final(True)),
]

# ---------------------------------------------------------------- PNG出力(v2 gen.py 流用)
def buf_to_rgba(buf):
    out = []
    for row in buf:
        line = bytearray()
        for c in row:
            if c is None:
                line += b"\x00\x00\x00\x00"
            else:
                line += bytes(c) + b"\xff"
        out.append(line)
    return out


def write_png(path, width, height, rgba_rows):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(r) for r in rgba_rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(blob)


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
    return struct.unpack(">II", head[16:24])


def make_contact_sheet(scaled):
    pad = 4 * SCALE
    cw, ch = W * SCALE, H * SCALE
    sheet_w = pad + len(FRAMES) * (cw + pad)
    sheet_h = pad * 2 + ch
    sheet = [bytearray((bytes(SHEET_BG) + b"\xff") * sheet_w) for _ in range(sheet_h)]
    for i, (name, _) in enumerate(FRAMES):
        x0, y0 = pad + i * (cw + pad), pad
        for dy, line in enumerate(scaled[name]):
            dest = sheet[y0 + dy]
            for dx in range(cw):
                if line[dx * 4 + 3] == 0xFF:
                    dest[(x0 + dx) * 4:(x0 + dx) * 4 + 4] = line[dx * 4:dx * 4 + 4]
    return sheet, sheet_w, sheet_h


# ---------------------------------------------------------------- メイン+自己検証
def main():
    os.makedirs(PNG_DIR, exist_ok=True)
    bufs, scaled = {}, {}
    for name, fn in FRAMES:
        buf = fn()
        bufs[name] = buf
        rgba = buf_to_rgba(buf)
        write_png(os.path.join(PNG_DIR, name + ".png"), W, H, rgba)
        scaled[name] = scale_rows(rgba, SCALE)

    sheet, sw, sh = make_contact_sheet(scaled)
    write_png(SHEET_PATH, sw, sh, sheet)

    # --- 自己検証 ---
    for name, _ in FRAMES:
        w, h = read_png_size(os.path.join(PNG_DIR, name + ".png"))
        assert (w, h) == (W, H), name
    # シルエット左右対称(キラキラありの final_happy を除く)
    for name, _ in FRAMES[:-1]:
        buf = bufs[name]
        for y in range(H):
            for x in range(W // 2):
                a = buf[y][x] is not None
                b = buf[y][W - 1 - x] is not None
                assert a == b, "asymmetry %s (%d,%d)" % (name, x, y)
    # 鉢の足元固定: 下部領域(y>=50)が全フレーム同一
    base = bufs[FRAMES[0][0]]
    for name, _ in FRAMES[1:]:
        for y in range(50, H):
            assert bufs[name][y] == base[y], "pot drift %s y=%d" % (name, y)
    print("OK: 6 sprites (%dx%d) + contact sheet (%dx%d)" % (W, H, sw, sh))


if __name__ == "__main__":
    main()
