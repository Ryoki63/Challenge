#!/usr/bin/env python3
"""Lien 植物育成スプライト v2 / style_b「レトロたまごっち」ジェネレータ。

24x32 px のドット絵 6 枚を、コード内のパレット + 2次元ピクセル配列から
決定論的に生成する。外部依存なし(zlib + struct で PNG を直接書く)。
Python 3.9+ / Pillow 不要。

v0 の反省: 顔を「鉢」に描いて植物本体が無表情だった → 本案は
**顔を植物本体に持たせて**キャラクター化する。芽の段階から表情が見える。

スタイル: レトロたまごっち。限定色(6色)+くっきり太い黒輪郭+
チャンキーな造形。レトロでも「可愛い」を最優先(大きい目+白ハイライト+ほっぺ)。

出力:
  png/<name>.png        原寸 24x32(6枚)
  contact_sheet.png     8倍ニアレストネイバー拡大の横並びモンタージュ(成長順)

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

W, H = 24, 32
SCALE = 8

# ---------------------------------------------------------------------------
# パレット(限定6色 + 輪郭黒 + 白 + 透明)。
# レトロでも明るく親しみやすい配色。クリーム背景に映える緑とピンク。
# ---------------------------------------------------------------------------
PALETTE = {
    ".": None,                  # 透明
    "K": (0x2B, 0x2B, 0x2B),    # 輪郭(ソフトブラック)— たまごっち風の太い黒線
    "G": (0x6F, 0xC8, 0x5C),    # 葉(明るいリーフグリーン)
    "g": (0x46, 0x97, 0x3D),    # 葉の影(深緑)
    "L": (0xA8, 0xE6, 0x7E),    # 葉のハイライト(やわらかい黄緑)
    "P": (0xFF, 0xA9, 0xC4),    # ほっぺ/花びら(ベビーピンク)
    "Y": (0xFF, 0xD8, 0x5C),    # 花芯/キラキラ(たまごクリームイエロー)
    "T": (0xE7, 0x8E, 0x5A),    # 鉢(あたたかいテラコッタ)
    "W": (0xFF, 0xFF, 0xFF),    # 目のハイライト/白
}

# キャンバス全体背景(透明だがコンタクトシートではクリーム地に置く)
SHEET_BG = (0xFB, 0xF3, 0xE2, 0xFF)  # あたたかいクリーム

# ---------------------------------------------------------------------------
# 小さな鉢の土台(全スプライト共通)。rows 27..31。
# 鉢は「小さめの土台」。顔は鉢ではなく植物本体(まるい体)に置く。
# 体が鉢のリムに少し沈み込むように重なって「植えてある」一体感を出す。
# ---------------------------------------------------------------------------
POT_START_ROW = 27
POT = [  # 24文字幅
    "....KKKKKKKKKKKKKKKK....",  # 27: 鉢のリム上端
    "....KTTTTTTTTTTTTTTK....",  # 28: リム
    ".....KTTTTTTTTTTTTK.....",  # 29: ボディ(テーパー)
    ".....KKTTTTTTTTTTKK.....",  # 30
    "......KKKKKKKKKKKK......",  # 31: 底
]


def hl_eyes(rc_left, rc_right):
    """大きい目(3x3黒の塊 + 右上に白ハイライト1px)。
    rc_* は目の左上(row,col)。たまごっち風のまんまる黒目。"""
    px = []
    for (r, c) in (rc_left, rc_right):
        # 3x3 の黒目
        for dr in range(3):
            for dc in range(3):
                px.append((r + dr, c + dc, "K"))
        # 右上に白ハイライト
        px.append((r, c + 2, "W"))
    return px


def cheeks(r, c_left, c_right):
    """ほっぺ(チーク)。左右に1pxピンク。"""
    return [(r, c_left, "P"), (r, c_right, "P")]


def smile(cells):
    """にっこり口。cells: [(r,c),...] を黒で。"""
    return [(r, c, "K") for (r, c) in cells]


def sparkle(r, c):
    """キラキラ(十字星)。中心W・腕Y。"""
    return [(r - 1, c, "Y"), (r + 1, c, "Y"), (r, c - 1, "Y"), (r, c + 1, "Y"), (r, c, "W")]


# ---------------------------------------------------------------------------
# 各キーフレームの「植物本体」(顔つき)。
# (start_row, rows[24文字幅]) を返す。"." は透過。
# 顔(目・口・ほっぺ)は paste_pixels で本体の上に重ねる。
# ---------------------------------------------------------------------------

def _fix_width(rows):
    fixed = []
    for r in rows:
        if len(r) < W:
            r = r + "." * (W - len(r))
        elif len(r) > W:
            r = r[:W]
        fixed.append(r)
    return fixed


# --- 植物本体を読みやすく定義(後で _fix_width で 24 幅に揃える) ---

# 共通: まるい体(たまご型の緑のキャラ)。x=6..17 の幅12。
# 体は rows 18..28 に置き、下端が鉢リム(row27)に少し沈む = 一体感。
# 体の上に「葉(髪)」を生やす。顔はこの体の上に重ねる。
#
#   row18  ..KKKKKKKK..   頭のてっぺん(丸い)
#   row19  .KGGGGGGGGK.
#   row20  KGGGGGGGGGGK   ← 目の行(おでこ)
#   row21  KGGGGGGGGGGK   ← 目の行
#   row22  KGGGGGGGGGGK   ← ほっぺの行
#   row23  KGGGGGGGGGGK   ← 口の行
#   row24  KGGGGGGGGGGK
#   row25  .KGGGGGGGGK.
#   row26  ..KGGGGGGK..   あごのまるみ
#   row27  ...KGGGGK...   鉢リムに沈む
#
ROUND_BODY = [
    "......KKKKKKKKKKKK......",  # 18
    ".....KGGGGGGGGGGGGK.....",  # 19
    "....KGGGGGGGGGGGGGGK....",  # 20
    "....KGGGGGGGGGGGGGGK....",  # 21
    "....KGGGGGGGGGGGGGGK....",  # 22
    "....KGGGGGGGGGGGGGGK....",  # 23
    "....KGGGGGGGGGGGGGGK....",  # 24
    ".....KGGGGGGGGGGGGK.....",  # 25
    "......KGGGGGGGGGGK......",  # 26
    ".......KGGGGGGGGK.......",  # 27 (鉢リムに重なる)
]
BODY_START = 18


def body_with_top(top_rows, top_start):
    """頭の上に生える葉/つぼみ/花(top_rows, top_start)と丸い体を合成し、
    (start_row, rows) を返す。両者は別レイヤとして順に貼るのではなく
    1つの rows にまとめる(top と body が重ならない前提)。"""
    # top は body より上。隙間は "." 行で埋める。
    rows = list(top_rows)
    gap = BODY_START - (top_start + len(top_rows))
    for _ in range(gap):
        rows.append("." * W)
    rows.extend(ROUND_BODY)
    return (top_start, _fix_width(rows))


PLANTS = {
    # soil: まだ芽が出ていない土。鉢の中にこんもり緑の土まんじゅう。
    #       眠っている小さな顔(閉じ目)で「種が眠っている」可愛さを出す。
    "soil": (22, _fix_width([
        ".......KKKKKKKK........",  # 22: 土まんじゅうのてっぺん(丸い)
        "......KGGGGGGGGGK......",  # 23
        ".....KGGGGGGGGGGGK.....",  # 24: 顔の行(閉じ目)
        ".....KGGGGGGGGGGGK.....",  # 25
        ".....KGGGGGGGGGGGK.....",  # 26
        "......KGGGGGGGGGK......",  # 27 (鉢に沈む)
    ])),

    # sprout: 体のてっぺんに小さな双葉。左右にまるい葉、中央に芽。
    "sprout": body_with_top([
        "...KK.........KK......",  # 14: 双葉のてっぺん
        "..KGLGK..KK..KGLGK....",  # 15: まるい葉 + 中央の芽
        "..KGGGK.KGLK.KGGGK....",  # 16
        "...KGGKKKGGKKKGGK.....",  # 17 (体の頭に green でつながる)
    ], 14),

    # mid: 葉が増えて左右に広がる。頭から葉が3方向へ。黒帯をなくして頭に溶け込む。
    "mid": body_with_top([
        "..........KK...........",  # 10
        ".........KGLK..........",  # 11: まんなかの新芽
        "...KKK...KGLK...KKK....",  # 12
        "..KGLGK..KGGK..KGLGK...",  # 13: 左右のおおきな葉
        ".KGGGGGK.KGGK.KGGGGGK..",  # 14
        ".KGGGGGGKKGGKKGGGGGGK..",  # 15
        "..KGGGGGGGGGGGGGGGGK...",  # 16
        "...KGGGGGGGGGGGGGGGK...",  # 17 (体の頭に green でつながる)
    ], 10),

    # late: 頭上に丸いつぼみ。葉も茂る。
    "late": body_with_top([
        "..........KK...........",  # 6
        ".........KPPK..........",  # 7: つぼみ
        "........KPWPPK.........",  # 8: ハイライト
        "........KPPPPK.........",  # 9
        ".........KPPK..........",  # 10: がく口
        ".........KGLK..........",  # 11: 茎
        "...KKK...KGLK...KKK....",  # 12
        "..KGLGK..KGGK..KGLGK...",  # 13: 左右の葉
        ".KGGGGGK.KGGK.KGGGGGK..",  # 14
        ".KGGGGGGKKGGKKGGGGGGK..",  # 15
        "..KGGGGGGGGGGGGGGGGK...",  # 16
        "...KGGGGGGGGGGGGGGGK...",  # 17 (体の頭に green でつながる)
    ], 6),

    # final: 頭上に大輪のお花。葉も茂る。
    "final": body_with_top([
        ".......KKK..KKK........",  # 2
        "......KPPPKKPPPK.......",  # 3
        ".....KPPPPPPPPPPK......",  # 4
        ".....KPPKYYYYKPPK......",  # 5: 花芯まわり
        ".....KPPYWYYYPPK......",  # 6: 花芯イエロー + 白つや
        ".....KPPKYYYYKPPK......",  # 7
        ".....KPPPPPPPPPPK......",  # 8
        "......KPPPKKPPPK.......",  # 9
        ".......KKKGLKKK........",  # 10: 茎へ
        ".........KGLK..........",  # 11
        "...KKK...KGLK...KKK....",  # 12
        "..KGLGK..KGGK..KGLGK...",  # 13: 左右の葉
        ".KGGGGGK.KGGK.KGGGGGK..",  # 14
        ".KGGGGGGKKGGKKGGGGGGK..",  # 15
        "..KGGGGGGGGGGGGGGGGK...",  # 16
        "...KGGGGGGGGGGGGGGGK...",  # 17 (体の頭に green でつながる)
    ], 2),
}

# ---------------------------------------------------------------------------
# 顔の重ね(植物本体の「顔の面」に合わせて配置)。
# 各キーフレームごとに目・口・ほっぺの座標を指定。
# ---------------------------------------------------------------------------
# 顔は丸い体(rows 19..26, cols 5..16)の上に乗る。全段階で同じ顔位置:
#   目  : 3x3, 左 cols 7-9 / 右 cols 13-15, rows 20-22(よく離して大きく)
#   ほっぺ: row 23, cols 6 と 17(2pxずつ)
#   口  : row 24, cols 10-13 のにっこりカーブ
NORMAL_FACE = (
    hl_eyes((20, 7), (20, 13))
    + smile([(23, 9), (24, 10), (25, 11), (25, 12), (24, 13), (23, 14)])  # 大きめ ∪
    + [(22, 5, "P"), (22, 6, "P"), (22, 16, "P"), (22, 17, "P")]  # ほっぺ(目の下, 2pxずつ)
)

FACES = {
    # soil: ねむっている種。閉じ目(˘ ˘)+ ちいさなほっぺ。安心して眠っている顔。
    "soil": (
        [(25, 8, "K"), (24, 9, "K"), (24, 10, "K"), (25, 11, "K"),    # 左の閉じ目 ˘
         (25, 12, "K"), (24, 13, "K"), (24, 14, "K"), (25, 15, "K")]   # 右の閉じ目 ˘
        + [(26, 7, "P"), (26, 16, "P")]                   # ほっぺ
        + [(26, 11, "K"), (26, 12, "K")]                   # ちいさな安らぎの口
    ),
    "sprout":       NORMAL_FACE,
    "mid":          NORMAL_FACE,
    "late":         NORMAL_FACE,
    "final_normal": NORMAL_FACE,
    # final_happy: 笑い目(^ ^)+ 大きい口 + ほっぺ濃いめ + キラキラ
    "final_happy": (
        # 左の笑い目 (^) cols 7-9
        [(21, 8, "K"), (20, 7, "K"), (20, 9, "K")]
        # 右の笑い目 (^) cols 13-15
        + [(21, 14, "K"), (20, 13, "K"), (20, 15, "K")]
        # 大きいにっこり口 (∪)
        + [(23, 9, "K"), (24, 10, "K"), (25, 11, "K"),
           (25, 12, "K"), (24, 13, "K"), (23, 14, "K")]
        # ほっぺ大きめ(2x2相当)
        + [(22, 5, "P"), (22, 6, "P"), (23, 5, "P"), (23, 6, "P"),
           (22, 17, "P"), (22, 18, "P"), (23, 17, "P"), (23, 18, "P")]
        # キラキラ(花のまわり)
        + sparkle(5, 3) + sparkle(3, 20)
    ),
}


# ---------------------------------------------------------------------------
# 各キーフレームの構成(name → 本体 + 顔)
# ---------------------------------------------------------------------------
SPRITES = {
    "soil":         {"plant": "soil",   "face": "soil",         "pot": True},
    "sprout":       {"plant": "sprout", "face": "sprout",       "pot": True},
    "mid":          {"plant": "mid",    "face": "mid",          "pot": True},
    "late":         {"plant": "late",   "face": "late",         "pot": True},
    "final_normal": {"plant": "final",  "face": "final_normal", "pot": True},
    "final_happy":  {"plant": "final",  "face": "final_happy",  "pot": True},
}

# コンタクトシートの並び順(成長順 → 最後によろこび差分)
SHEET_ORDER = ["soil", "sprout", "mid", "late", "final_normal", "final_happy"]


# ---------------------------------------------------------------------------
# 合成・描画
# ---------------------------------------------------------------------------
def blank_grid():
    return [["." for _ in range(W)] for _ in range(H)]


def paste_rows(grid, start_row, rows):
    for i, row in enumerate(rows):
        if len(row) != W:
            raise ValueError("row width %d != %d: %r" % (len(row), W, row))
        r = start_row + i
        if not (0 <= r < H):
            raise ValueError("row %d out of canvas (start=%d i=%d): %r" % (r, start_row, i, row))
        for c, ch in enumerate(row):
            if ch not in PALETTE:
                raise ValueError("unknown palette char %r in %r" % (ch, row))
            if ch != ".":
                grid[r][c] = ch


def paste_pixels(grid, pixels):
    for item in pixels:
        r, c, ch = item
        if not (0 <= r < H and 0 <= c < W):
            raise ValueError("pixel out of canvas: %r" % (item,))
        if ch not in PALETTE:
            raise ValueError("unknown palette char %r" % ch)
        grid[r][c] = ch


def build_sprite(name):
    spec = SPRITES[name]
    grid = blank_grid()
    if spec.get("pot"):
        paste_rows(grid, POT_START_ROW, POT)
    if spec["plant"] is not None:
        start, rows = PLANTS[spec["plant"]]
        paste_rows(grid, start, rows)
    paste_pixels(grid, FACES[spec["face"]])
    return grid


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


def make_contact_sheet(sprites_rgba):
    pad = 2 * SCALE
    cell_w, cell_h = W * SCALE, H * SCALE
    cols = len(SHEET_ORDER)
    sheet_w = pad + cols * (cell_w + pad)
    sheet_h = pad + (cell_h + pad)
    sheet = [bytearray(bytes(SHEET_BG) * sheet_w) for _ in range(sheet_h)]
    for gx, name in enumerate(SHEET_ORDER):
        x0 = pad + gx * (cell_w + pad)
        y0 = pad
        big = sprites_rgba[name]
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
    for name in SPRITES:
        grid = build_sprite(name)
        rgba = grid_to_rgba(grid)
        write_png(os.path.join(PNG_DIR, name + ".png"), W, H, rgba)
        sprites_8x[name] = scale_rows(rgba, SCALE)

    sheet, sw, sh = make_contact_sheet(sprites_8x)
    write_png(SHEET_PATH, sw, sh, sheet)

    # --- 自己検証 ---
    names = list(SPRITES)
    assert len(names) == 6, "expected 6 keyframes, got %d" % len(names)
    for name in names:
        w, h = read_png_size(os.path.join(PNG_DIR, name + ".png"))
        assert (w, h) == (W, H), "%s: %dx%d != %dx%d" % (name, w, h, W, H)
    w, h = read_png_size(SHEET_PATH)
    assert (w, h) == (sw, sh)
    print("OK: %d keyframes -> %s" % (len(names), PNG_DIR))
    print("OK: contact_sheet %dx%d -> %s" % (sw, sh, SHEET_PATH))
    return 0


if __name__ == "__main__":
    sys.exit(main())
