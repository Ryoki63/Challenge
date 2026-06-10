#!/usr/bin/env python3
"""Lien アプリアイコン ジェネレータ(T26 / issue #26)。

植物スプライト(assets/plant/tools/gen_sprites.py)とトーンを揃えた
ネオドット絵のアプリアイコンを、純Python(zlib + struct)で決定論的に生成する。
Pillow 不要 / Python 3.9+。

設計:
  - 16x16 のピクセル格子を 64 倍整数拡大して 1024x1024 を得る(1024 = 16 * 64)
  - App Store のマーケティングアイコンは「透過なし」が要件のため、
    PNG は color type 2(RGB・アルファなし)で書く。角丸は Apple 側が適用する
  - パレットは gen_sprites.py の PALETTE と同一の色 + 背景色(あたたかいオフホワイト)

出力:
  ../icon_1024.png                       本命(draft B: 鉢の相棒 + 双葉 + ハート)
  ../icon_drafts/draft_a_bloom_1024.png  A案: 開花クローズアップ
  ../icon_drafts/draft_b_buddy_1024.png  B案: 鉢の相棒(本命)
  ../icon_drafts/draft_c_heart_1024.png  C案: 双葉ハート(シンボル)
  ../icon_drafts/contact_sheet.png       G4レビュー用モンタージュ(各256px)

使い方:
  python3 gen_icon.py
"""

import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ICON_DIR = os.path.normpath(os.path.join(HERE, ".."))
DRAFT_DIR = os.path.join(ICON_DIR, "icon_drafts")

GRID = 16          # 16x16 ピクセル格子
SCALE = 64         # 16 * 64 = 1024
SIZE = GRID * SCALE
SHEET_SCALE = 16   # ドラフトシートは各 16*16=256px

# gen_sprites.py の PALETTE と同一色(透明は使わない。"." = 背景色)
PALETTE = {
    "K": (0x3A, 0x2C, 0x28),   # 輪郭(ダークブラウン)
    "T": (0xE8, 0x9A, 0x60),   # 鉢(テラコッタ)
    "t": (0xC2, 0x6E, 0x42),   # 鉢の影
    "S": (0x6B, 0x4A, 0x36),   # 土(暗)
    "s": (0x95, 0x6B, 0x4A),   # 土(明)
    "G": (0x59, 0xC1, 0x65),   # 葉(基本)
    "g": (0x35, 0x8A, 0x4D),   # 葉(影)
    "L": (0xA8, 0xE6, 0x7E),   # 葉(ハイライト)
    "P": (0xF6, 0x9A, 0xC0),   # 花びら・ハート(ピンク)
    "Y": (0xFF, 0xD9, 0x66),   # 花芯・キラキラ(イエロー)
    "W": (0xFF, 0xFF, 0xFF),   # ハイライト(ホワイト)
    "B": (0x7E, 0xC8, 0xF5),   # ブルー(本アイコンでは未使用)
}
BG = (0xF4, 0xEF, 0xE6)        # 背景: あたたかいオフホワイト(contact_sheet と同一)


def sparkle(r, c):
    """キラキラ(5px の十字星)。中心W・腕Y。gen_sprites.py と同形。"""
    return [(r - 1, c, "Y"), (r + 1, c, "Y"), (r, c - 1, "Y"), (r, c + 1, "Y"), (r, c, "W")]


# ---------------------------------------------------------------------------
# A案「開花」: stage5 の大輪をクローズアップ。小サイズで最も大胆に読める
# ---------------------------------------------------------------------------
DRAFT_A = [
    ".....KKKKKK.....",
    "....KPPPPPPK....",
    "...KPPKYYKPPK...",
    "...KPPYYYYPPK...",
    "...KPPKYYKPPK...",
    "....KPPPPPPK....",
    ".....KKKKKK.....",
    "......KGgK......",
    "..KKK.KGgK......",
    ".KGLGKKGgK.KKK..",
    "..KGGKKGgKKGLGK.",
    "...KgKKGgKKGGK..",
    "......KGgKKgK...",
    "......KGgK......",
    "......KGgK......",
    "......KggK......",
]
DRAFT_A_EXTRA = sparkle(2, 1) + sparkle(4, 14)

# ---------------------------------------------------------------------------
# B案「鉢の相棒」(本命): アプリ内マスコットそのもの。
# 双葉(ふたば = ふたり)+ にこにこ顔の鉢 + 小さなハート = 「ふたりで育てる」
# ---------------------------------------------------------------------------
DRAFT_B = [
    "................",
    "..KKK......KKK..",
    ".KGLGK....KGLGK.",
    ".KGGGK....KGGGK.",
    "..KGGK....KGGK..",
    "...KGgK..KgGK...",
    ".....KGGggK.....",
    "......KGgK......",
    ".KKKKKKKKKKKKKK.",
    "KSsSSSSSSSSSSsSK",
    "KTTTTTTTTTTTTTtK",
    ".KTTTTTTTTTTTtK.",
    ".KTTTTTTTTTTTtK.",
    ".KTTTTTTTTTTTtK.",
    "..KTTTTTTTTTtK..",
    "...KKKKKKKKKK...",
]
DRAFT_B_EXTRA = [
    # ハート(双葉の上・ふたりの絆)
    (0, 7, "P"), (0, 9, "P"),
    (1, 6, "P"), (1, 7, "W"), (1, 8, "P"), (1, 9, "P"), (1, 10, "P"),
    (2, 7, "P"), (2, 8, "P"), (2, 9, "P"),
    (3, 8, "P"),
    # 顔(happy): gen_sprites.py FACES["happy"] と同形(行をアイコン格子に写像)
    (11, 4, "K"), (11, 5, "K"), (12, 6, "K"),     # 左の笑い目 (⌒)
    (12, 9, "K"), (11, 10, "K"), (11, 11, "K"),   # 右の笑い目
    (12, 4, "P"), (12, 11, "P"),                  # ほっぺ
    (13, 7, "K"), (13, 8, "K"),                   # にこっと口
]

# ---------------------------------------------------------------------------
# C案「双葉ハート」: 2枚の葉がひとつのハートをつくるシンボル。最も概念的
# ---------------------------------------------------------------------------
DRAFT_C = [
    "................",
    "...KKK....KKK...",
    "..KGGGK..KLLLK..",
    "..KGGGGKKLLLLK..",
    "..KGGGGGLLLLLK..",
    "..KGGGGGLLLLLK..",
    "...KGGGGLLLLK...",
    "....KGGGLLLK....",
    ".....KGGLLK.....",
    "......KGLK......",
    ".......KK.......",
    "......KGgK......",
    "......KGgK......",
    "......KGgK......",
    "....KKKKKKKK....",
    "...KSsSSSSSSsK..",
]
DRAFT_C_EXTRA = [(2, 4, "W")] + sparkle(12, 2) + sparkle(11, 13)

DRAFTS = [
    ("draft_a_bloom", DRAFT_A, DRAFT_A_EXTRA),
    ("draft_b_buddy", DRAFT_B, DRAFT_B_EXTRA),
    ("draft_c_heart", DRAFT_C, DRAFT_C_EXTRA),
]
CHOSEN = "draft_b_buddy"  # 本命 → icon_1024.png(G4で差し替え可)


# ---------------------------------------------------------------------------
# 描画
# ---------------------------------------------------------------------------
def build_grid(rows, extra):
    if len(rows) != GRID:
        raise ValueError("grid height %d != %d" % (len(rows), GRID))
    grid = []
    for row in rows:
        if len(row) != GRID:
            raise ValueError("row width %d != %d: %r" % (len(row), GRID, row))
        for ch in row:
            if ch != "." and ch not in PALETTE:
                raise ValueError("unknown palette char %r in %r" % (ch, row))
        grid.append(list(row))
    for r, c, ch in extra:
        if not (0 <= r < GRID and 0 <= c < GRID):
            raise ValueError("pixel out of canvas: %r" % ((r, c, ch),))
        if ch not in PALETTE:
            raise ValueError("unknown palette char %r" % ch)
        grid[r][c] = ch
    return grid


def grid_to_rgb_rows(grid, scale):
    """格子 → ニアレストネイバー整数拡大した RGB スキャンライン列。"""
    out = []
    for row in grid:
        line = bytearray()
        for ch in row:
            rgb = BG if ch == "." else PALETTE[ch]
            line += bytes(rgb) * scale
        for _ in range(scale):
            out.append(line)
    return out


def write_png_rgb(path, width, height, rgb_rows):
    """color type 2(RGB・アルファなし)の PNG を書く。App Store アイコン要件。"""
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(r) for r in rgb_rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(blob)


def read_png_header(path):
    with open(path, "rb") as f:
        head = f.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise ValueError("not a PNG: %s" % path)
    w, h = struct.unpack(">II", head[16:24])
    bit_depth, color_type = head[24], head[25]
    return w, h, bit_depth, color_type


def make_contact_sheet(grids):
    """3案を横に並べたレビュー用シート(各 16*SHEET_SCALE px)。"""
    pad = SHEET_SCALE
    cell = GRID * SHEET_SCALE
    sheet_w = pad + len(grids) * (cell + pad)
    sheet_h = cell + 2 * pad
    bg = (0xDD, 0xD4, 0xC5)  # 各案の境界が見えるよう一段濃いベージュ
    rows = [bytearray(bytes(bg) * sheet_w) for _ in range(sheet_h)]
    for i, grid in enumerate(grids):
        x0 = pad + i * (cell + pad)
        tile = grid_to_rgb_rows(grid, SHEET_SCALE)
        for dy, line in enumerate(tile):
            rows[pad + dy][x0 * 3:(x0 + cell) * 3] = line
    return rows, sheet_w, sheet_h


def main():
    os.makedirs(DRAFT_DIR, exist_ok=True)

    grids = {}
    for name, rows, extra in DRAFTS:
        grid = build_grid(rows, extra)
        grids[name] = grid
        write_png_rgb(os.path.join(DRAFT_DIR, name + "_1024.png"),
                      SIZE, SIZE, grid_to_rgb_rows(grid, SCALE))

    # 本命を icon_1024.png に
    write_png_rgb(os.path.join(ICON_DIR, "icon_1024.png"),
                  SIZE, SIZE, grid_to_rgb_rows(grids[CHOSEN], SCALE))

    sheet, sw, sh = make_contact_sheet([grids[n] for n, _, _ in DRAFTS])
    write_png_rgb(os.path.join(DRAFT_DIR, "contact_sheet.png"), sw, sh, sheet)

    # --- 自己検証: 寸法 1024x1024 / 8bit / color type 2(RGB・透過なし) ---
    targets = [os.path.join(ICON_DIR, "icon_1024.png")]
    targets += [os.path.join(DRAFT_DIR, n + "_1024.png") for n, _, _ in DRAFTS]
    for path in targets:
        w, h, depth, ctype = read_png_header(path)
        assert (w, h) == (SIZE, SIZE), "%s: %dx%d != %dx%d" % (path, w, h, SIZE, SIZE)
        assert depth == 8 and ctype == 2, "%s: depth=%d ctype=%d (RGB必須)" % (path, depth, ctype)
    w, h, depth, ctype = read_png_header(os.path.join(DRAFT_DIR, "contact_sheet.png"))
    assert (w, h) == (sw, sh) and ctype == 2
    # 本命 = 選択ドラフトのバイト一致
    with open(os.path.join(ICON_DIR, "icon_1024.png"), "rb") as f:
        chosen_bytes = f.read()
    with open(os.path.join(DRAFT_DIR, CHOSEN + "_1024.png"), "rb") as f:
        assert chosen_bytes == f.read(), "icon_1024.png != %s" % CHOSEN

    print("OK: icon_1024.png (%dx%d, RGB, chosen=%s)" % (SIZE, SIZE, CHOSEN))
    print("OK: %d drafts + contact_sheet (%dx%d) -> %s" % (len(DRAFTS), sw, sh, DRAFT_DIR))
    return 0


if __name__ == "__main__":
    sys.exit(main())
