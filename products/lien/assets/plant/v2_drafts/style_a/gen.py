#!/usr/bin/env python3
"""Lien 植物スプライト v2 / style_a「ぷにぷにパステル」ジェネレータ(issue #49)。

24x32 px のキャラクター化ドット絵 6 キーフレームを、コード内パレット +
2次元ピクセル配列から決定論的に生成する。外部依存なし(zlib + struct で
PNG を直接書く)。Python 3.9+ / Pillow 不要。

v0 との違い:
  - 顔を「鉢」ではなく「植物本体」に持たせてキャラクター化(芽の段階から大きい目+ほっぺ)
  - 24x32 に拡大して大きい顔とまるいシルエットを描く
  - ぷにっと丸い、ゼリー/マシュマロ質感のパステルパレット
  - ボディは鉢に「すわって」いて浮かない。成長で胴も少し大きくなる

出力:
  png/<name>.png            原寸 24x32(6枚)
  contact_sheet.png         8倍ニアレスト・横並びモンタージュ(成長順)
"""

import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PNG_DIR = os.path.join(HERE, "png")

W, H = 24, 32
SCALE = 8

# ---------------------------------------------------------------------------
# パレット「ぷにぷにパステル」: 淡くやわらかい・白ハイライトでツヤ
# 輪郭は黒ではなく "やわらかいモーブグレー" にして優しい印象に
# ---------------------------------------------------------------------------
PALETTE = {
    ".": None,                  # 透明
    "o": (0x7A, 0x66, 0x6A),    # やわらか輪郭(モーブグレー。黒より優しい)
    # ボディ(淡いミントのおまんじゅう=ぷにっとした胴)
    "M": (0xC6, 0xEF, 0xDB),    # ボディ基本(淡いミント)
    "m": (0xA6, 0xE0, 0xC8),    # ボディ影(ミント影)
    "N": (0xE6, 0xF9, 0xEE),    # ボディ最明部(ツヤ)
    # 葉・芽(若草〜ミント)
    "G": (0x8E, 0xD6, 0x8F),    # 葉(基本・若草パステル)
    "g": (0x6F, 0xC0, 0x84),    # 葉(影)
    "L": (0xC2, 0xF0, 0xB8),    # 葉(ハイライト・ミント寄り)
    # 花(ベビーピンク〜クリーム)
    "P": (0xFB, 0xC4, 0xD8),    # 花びら(ベビーピンク)
    "p": (0xF2, 0xA3, 0xC1),    # 花びら影
    "Y": (0xFF, 0xE6, 0x9C),    # 花芯・キラキラ(クリームイエロー)
    "C": (0xFF, 0xF4, 0xD6),    # クリーム(花芯ハイライト)
    # 鉢(やわらかキャラメルベージュの土台)
    "T": (0xF3, 0xCF, 0xA8),    # 鉢(キャラメルベージュ)
    "t": (0xE0, 0xB1, 0x86),    # 鉢の影
    "S": (0xB6, 0x8C, 0x6B),    # 土(やわらか茶)
    "s": (0xCB, 0xA6, 0x82),    # 土ハイライト
    # 顔・装飾
    "K": (0x4A, 0x3E, 0x42),    # 目(真っ黒でなくダークモーブ)
    "W": (0xFF, 0xFF, 0xFF),    # 白ハイライト・キラキラ芯
    "R": (0xFF, 0xA9, 0xC0),    # ほっぺ(チーク・ピンク丸)
    "B": (0xAF, 0xDD, 0xF5),    # しずく(ブルー)※「ふぅ」1粒まで
}


def blank_grid():
    return [["." for _ in range(W)] for _ in range(H)]


def paste_rows(grid, start_row, rows, start_col=0):
    for i, row in enumerate(rows):
        r = start_row + i
        if not (0 <= r < H):
            raise ValueError("row %d out of canvas: %r" % (r, row))
        for j, ch in enumerate(row):
            c = start_col + j
            if not (0 <= c < W):
                raise ValueError("col %d out of canvas (row %d): %r" % (c, r, row))
            if ch not in PALETTE:
                raise ValueError("unknown palette char %r in %r" % (ch, row))
            if ch != ".":
                grid[r][c] = ch


def paste_pixels(grid, pixels):
    for r, c, ch in pixels:
        if not (0 <= r < H and 0 <= c < W):
            raise ValueError("pixel out of canvas: %r" % ((r, c, ch),))
        if ch not in PALETTE:
            raise ValueError("unknown palette char %r" % ch)
        grid[r][c] = ch


# ---------------------------------------------------------------------------
# 顔パーツ(植物本体に置く)。lc/rc = 左右の目の左端 col、ec = ほっぺの基準
# 大きい目: 黒丸 2(W) x 3(H) + 白ハイライト2点で「うるうる」させる
# ---------------------------------------------------------------------------
def eyes_open(grid, row, lc, rc):
    """大きいうるうる目(幅2・高さ3の黒丸)+白ハイライト上下2点。"""
    for c0 in (lc, rc):
        # 黒丸
        for dr in range(3):
            for dc in range(2):
                grid[row + dr][c0 + dc] = "K"
        # 大きい白ハイライト(左上)+小さいハイライト(右下)= うるうる
        grid[row][c0] = "W"
        grid[row + 2][c0 + 1] = "W"


def eyes_happy(grid, row, lc, rc):
    """にっこり閉じ目(⌒)。幅3。"""
    for c0 in (lc, rc):
        grid[row + 1][c0] = "K"
        grid[row][c0 + 1] = "K"
        grid[row + 1][c0 + 2] = "K"


def cheeks(grid, row, lc, rc):
    """ほっぺ(ピンクの丸 2x2)。"""
    for c0 in (lc, rc):
        grid[row][c0] = "R"
        grid[row][c0 + 1] = "R"
        grid[row + 1][c0] = "R"
        grid[row + 1][c0 + 1] = "R"


def mouth_small(grid, row, c):
    """ちいさな口(ω 風・中央3px)。"""
    grid[row][c - 1] = "o"
    grid[row][c] = "o"
    grid[row][c + 1] = "o"
    grid[row + 1][c] = "o"


def mouth_open(grid, row, c):
    """にこっと開いた口(おちょぼ)。"""
    grid[row][c - 1] = "o"
    grid[row][c] = "o"
    grid[row][c + 1] = "o"
    grid[row + 1][c - 1] = "o"
    grid[row + 1][c] = "R"
    grid[row + 1][c + 1] = "o"


def sparkle(r, c):
    """キラキラ(十字の小さな星)。中心W・腕Y。"""
    return [(r - 1, c, "Y"), (r + 1, c, "Y"), (r, c - 1, "Y"),
            (r, c + 1, "Y"), (r, c, "W")]


def droplet(r, c):
    return [(r, c, "B"), (r + 1, c, "B"), (r + 1, c - 1, "B"), (r, c - 1, "W")]


def stem(grid, r0, r1, c=11):
    """crown と body をつなぐ短い茎(2px幅)。r0(上)〜r1(下・含む)。"""
    for r in range(r0, r1 + 1):
        grid[r][c] = "g"
        grid[r][c + 1] = "G"


# ---------------------------------------------------------------------------
# 鉢(小さめの土台)。ボディがこの上に「すわる」。rows は配置時に指定
# 幅14・中央寄せ(start_col=5)。ボディ底とリムを重ねて浮かないようにする
# ---------------------------------------------------------------------------
POT = [
    "ooooooooooooo",   # 鉢の口(リム上)
    "oTtTTTTTTTtTo",   # リム
    ".oTTTTTTTTTo.",   # ボディ
    ".oTTTtttTTTo.",   # ボディ影
    "..oTttttttTo.",
    "..ooooooooo..",   # 底
]
# 全キーフレームで鉢の底を同じ高さ(下端=row30)にそろえる → 成長アニメで足元が動かない
POT_TOP = 25


def add_pot(grid, top=POT_TOP):
    paste_rows(grid, top, POT, start_col=5)


# ---------------------------------------------------------------------------
# ぷにボディ(おまんじゅう型)。size に応じて幅高さが変わる。
# 戻り値: 顔を置くための基準 (face_row, eye_lc, eye_rc, cheek_lc, cheek_rc, mouth_c, hilite)
# すべて 24px キャンバスの絶対座標。ボディは水平中央(中心 col=11.5)
# ---------------------------------------------------------------------------
def body_blob(grid, top, size):
    """size: 's'(小)/'m'(中)/'l'(大)。top=ボディ上端row。"""
    if size == "s":
        rows = [
            "....oooooo....",
            "..ooNNNNNNoo..",
            ".oMNNMMMMNNMo.",
            ".oMMMMMMMMMMo.",
            ".oMMMMMMMMMMo.",
            "..oMMmmmmMMo..",
            "...oommmmoo...",
            "....oooooo....",
        ]
        col = 5
    elif size == "m":
        rows = [
            "...oooooooo...",
            ".ooNNNNNNNNoo.",
            "oMNNMMMMMMNNMo",
            "oMMMMMMMMMMMMo",
            "oMMMMMMMMMMMMo",
            "oMMMMMMMMMMMMo",
            ".oMMmmmmmmMMo.",
            "..oommmmmmoo..",
            "...oooooooo...",
        ]
        col = 5
    else:  # 'l'
        rows = [
            "..oooooooooo..",
            ".oNNNNNNNNNNo.",
            "oMNNMMMMMMNNMo",
            "oMMMMMMMMMMMMo",
            "oMMMMMMMMMMMMo",
            "oMMMMMMMMMMMMo",
            "oMMMMMMMMMMMMo",
            ".oMMmmmmmmMMo.",
            "..oommmmmmoo..",
            "...oooooooo...",
        ]
        col = 5
    paste_rows(grid, top, rows, start_col=col)
    return top


# ---------------------------------------------------------------------------
# キーフレーム
# ---------------------------------------------------------------------------
def kf_soil(grid, happy=False):
    """種=土だけ。鉢の土がにこやかに待つ(顔は土に小さく、でも可愛く)。"""
    # 共通の鉢(同じ足元)+ 口を土に差し替える
    pot = [
        "ooooooooooooo",
        "oSsSSSSSSSsSo",   # 土の表面(リムの代わり)
        ".oTTTTTTTTTo.",
        ".oTTTtttTTTo.",
        "..oTttttttTo.",
        "..ooooooooo..",
    ]
    paste_rows(grid, POT_TOP, pot, start_col=5)
    # 土の上にちょこんと芽吹き前の種(2px)
    grid[POT_TOP + 1][16] = "o"
    grid[POT_TOP + 1][17] = "o"
    # 鉢のボディに大きめのにこ顔(待ち遠しい)
    eyes_open(grid, POT_TOP + 2, 8, 14)
    cheeks(grid, POT_TOP + 3, 6, 16)
    mouth_small(grid, POT_TOP + 4, 11)
    grid[POT_TOP + 2][11] = "W"  # おでこツヤ


def kf_sprout(grid, happy=False):
    """序盤・芽。小さなぷにボディの頭にまるい双葉。"""
    add_pot(grid)
    # まるい双葉(内に寄せてハート状に。角張らせない)
    leaves = [
        "...oo..oo...",
        "..oLGooGLo..",
        "..oGGooGGo..",
        "...ogggo....",
    ]
    paste_rows(grid, 11, leaves, start_col=6)
    stem(grid, 15, 18)            # crown→body をつなぐ茎
    top = body_blob(grid, 18, "s")  # 底=row25 で鉢にすわる
    # 顔(小ボディの中央)。中心 col=11
    if happy:
        eyes_happy(grid, top + 2, 8, 13)
        mouth_open(grid, top + 4, 11)
    else:
        eyes_open(grid, top + 2, 8, 13)
        mouth_small(grid, top + 5, 11)
    cheeks(grid, top + 3, 6, 16)
    grid[top + 1][11] = "W"


def kf_mid(grid, happy=False):
    """中盤・若葉。葉が3枚に増え、ボディは中サイズ。"""
    add_pot(grid)
    # 葉の冠(3枚のまるい若葉)。幅14 → start_col=5
    leaves = [
        "..oo..oo..oo..",
        ".oLo.oLo.oLo..",
        ".oGgooGgooGGo.",
        "..oggggggggo..",
        "....oggggo....",
    ]
    paste_rows(grid, 9, leaves, start_col=5)
    stem(grid, 13, 17)
    top = body_blob(grid, 17, "m")  # 底=row25
    if happy:
        eyes_happy(grid, top + 3, 8, 13)
        mouth_open(grid, top + 5, 11)
    else:
        eyes_open(grid, top + 3, 8, 13)
        mouth_small(grid, top + 6, 11)
    cheeks(grid, top + 4, 6, 16)
    grid[top + 2][11] = "W"


def kf_late(grid, happy=False):
    """終盤・つぼみ。頭にふっくらピンクのつぼみ。"""
    add_pot(grid)
    # ふっくらつぼみ + がく。幅10 → start_col=7
    bud = [
        "..oooo..",
        ".oPPPPo.",
        "oPCPPPo.",
        "oPPPPpo.",
        ".oPppo..",
        "..ogo...",
        ".ogGGgo.",
    ]
    # 幅8/中心をボディ中心(col=11)に合わせる → start_col=7
    paste_rows(grid, 8, bud, start_col=7)
    stem(grid, 15, 17)
    top = body_blob(grid, 17, "m")
    if happy:
        eyes_happy(grid, top + 3, 8, 13)
        mouth_open(grid, top + 5, 11)
    else:
        eyes_open(grid, top + 3, 8, 13)
        mouth_small(grid, top + 6, 11)
    cheeks(grid, top + 4, 6, 16)
    grid[top + 2][11] = "W"


def kf_final(grid, happy=False):
    """最終形態・開花。頭に大きな花。happy=キラキラ+にっこり。"""
    add_pot(grid)
    # 大きな花(5枚花びら風・左右対称)。幅14 → start_col=5(中心 col=11.5)
    flower = [
        "..oooo..oooo..",
        ".oPPpo..oppPo.",
        ".oPPPoooPPPo..",
        "oPPPCYYCPPPo..",
        "oPPYCWWCYPPo..",
        "oPPPCYYCPPPo..",
        ".oPPPoooPPPo..",
        ".oppPo..oPppo.",
        "....oogGgoo...",
    ]
    paste_rows(grid, 5, flower, start_col=5)
    stem(grid, 14, 16)
    top = body_blob(grid, 16, "l")  # 底=row25
    if happy:
        eyes_happy(grid, top + 4, 8, 13)
        mouth_open(grid, top + 6, 11)
        paste_pixels(grid, sparkle(top + 1, 4) + sparkle(top + 3, 20)
                     + sparkle(top + 7, 3))
    else:
        eyes_open(grid, top + 4, 8, 13)
        mouth_small(grid, top + 7, 11)
    cheeks(grid, top + 5, 6, 16)
    grid[top + 3][11] = "W"


# ---------------------------------------------------------------------------
# キーフレーム定義(成長順)
# ---------------------------------------------------------------------------
KEYFRAMES = [
    ("soil",         lambda g: kf_soil(g)),
    ("sprout",       lambda g: kf_sprout(g)),
    ("mid",          lambda g: kf_mid(g)),
    ("late",         lambda g: kf_late(g)),
    ("final_normal", lambda g: kf_final(g, happy=False)),
    ("final_happy",  lambda g: kf_final(g, happy=True)),
]
SHEET_BG = (0xFB, 0xF6, 0xEF, 0xFF)  # あたたかいクリーム背景


# ---------------------------------------------------------------------------
# PNG 出力(v0 と同じ方式)
# ---------------------------------------------------------------------------
def grid_to_rgba(grid):
    out = []
    for row in grid:
        line = bytearray()
        for ch in row:
            rgb = PALETTE[ch]
            if rgb is None:
                line += b"\x00\x00\x00\x00"
            else:
                line += bytes(rgb) + b"\xff"
        out.append(line)
    return out


def write_png(path, width, height, rgba_rows):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(r) for r in rgba_rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))
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
    w, h = struct.unpack(">II", head[16:24])
    return w, h


def make_contact_sheet(sprites_8x, order):
    pad = 2 * SCALE
    cell_w, cell_h = W * SCALE, H * SCALE
    cols = len(order)
    sheet_w = pad + cols * (cell_w + pad)
    sheet_h = pad + (cell_h + pad)
    sheet = [bytearray(bytes(SHEET_BG) * sheet_w) for _ in range(sheet_h)]
    for gx, name in enumerate(order):
        x0 = pad + gx * (cell_w + pad)
        y0 = pad
        big = sprites_8x[name]
        for dy, line in enumerate(big):
            dest = sheet[y0 + dy]
            for dx in range(cell_w):
                a = line[dx * 4 + 3]
                if a == 0xFF:
                    dest[(x0 + dx) * 4:(x0 + dx) * 4 + 4] = line[dx * 4:dx * 4 + 4]
    return sheet, sheet_w, sheet_h


def main():
    os.makedirs(PNG_DIR, exist_ok=True)
    sprites_8x = {}
    order = []
    for name, fn in KEYFRAMES:
        grid = blank_grid()
        fn(grid)
        rgba = grid_to_rgba(grid)
        write_png(os.path.join(PNG_DIR, name + ".png"), W, H, rgba)
        sprites_8x[name] = scale_rows(rgba, SCALE)
        order.append(name)

    sheet, sw, sh = make_contact_sheet(sprites_8x, order)
    write_png(os.path.join(HERE, "contact_sheet.png"), sw, sh, sheet)

    # 自己検証
    assert len(order) == 6, "expected 6 keyframes, got %d" % len(order)
    for name in order:
        w, h = read_png_size(os.path.join(PNG_DIR, name + ".png"))
        assert (w, h) == (W, H), "%s: %dx%d != %dx%d" % (name, w, h, W, H)
    print("OK: %d keyframes -> %s" % (len(order), PNG_DIR))
    print("OK: contact_sheet %dx%d -> %s"
          % (sw, sh, os.path.join(HERE, "contact_sheet.png")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
