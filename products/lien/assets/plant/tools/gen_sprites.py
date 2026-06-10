#!/usr/bin/env python3
"""Lien 植物スプライト v0 ジェネレータ(T09 / issue #9)。

16x24 px のネオドット絵 13 枚を、コード内のパレット + 2次元ピクセル配列から
決定論的に生成する。外部依存なし(zlib + struct で PNG を直接書く)。
Python 3.9+ / Pillow 不要。

出力:
  ../png/<name>.png            原寸 16x24(13枚)
  ../preview/<name>@8x.png     8倍ニアレストネイバー拡大(13枚)
  ../preview/contact_sheet.png G2レビュー用モンタージュ(8倍・全13枚)

使い方:
  python3 gen_sprites.py
"""

import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PNG_DIR = os.path.normpath(os.path.join(HERE, "..", "png"))
PREVIEW_DIR = os.path.normpath(os.path.join(HERE, "..", "preview"))

W, H = 16, 24
SCALE = 8

# ---------------------------------------------------------------------------
# パレット(12色 + 透明)。平成たまごっち風: 限定色・輪郭くっきり・あたたかい色味
# ---------------------------------------------------------------------------
PALETTE = {
    ".": None,                 # 透明
    "K": (0x3A, 0x2C, 0x28),   # 輪郭(ダークブラウン)
    "T": (0xE8, 0x9A, 0x60),   # 鉢(テラコッタ)
    "t": (0xC2, 0x6E, 0x42),   # 鉢の影
    "S": (0x6B, 0x4A, 0x36),   # 土(暗)
    "s": (0x95, 0x6B, 0x4A),   # 土(明・フレック)
    "G": (0x59, 0xC1, 0x65),   # 葉(基本)
    "g": (0x35, 0x8A, 0x4D),   # 葉(影)
    "L": (0xA8, 0xE6, 0x7E),   # 葉(ハイライト)
    "P": (0xF6, 0x9A, 0xC0),   # 花びら(ピンク)
    "Y": (0xFF, 0xD9, 0x66),   # 花芯・キラキラ(イエロー)
    "W": (0xFF, 0xFF, 0xFF),   # キラキラ芯・ハイライト(ホワイト)
    "B": (0x7E, 0xC8, 0xF5),   # しずく(ブルー)※罰ではなく「ふぅ…」の汗ひとつぶ
}

# ---------------------------------------------------------------------------
# 鉢(全スプライト共通)。rows 15..23。顔は鉢に描く(全段階で表情が読める)
# ---------------------------------------------------------------------------
POT_START_ROW = 15
POT = [
    ".KKKKKKKKKKKKKK.",  # 15: 開口部
    "KSsSSSSSSSSSSsSK",  # 16: 開口部の土
    "KTTTTTTTTTTTTTtK",  # 17: リム
    "KTTTTTTTTTTTTTtK",  # 18: リム
    ".KKKKKKKKKKKKKK.",  # 19: リム下端
    ".KTTTTTTTTTTTtK.",  # 20: ボディ(目の行)
    ".KTTTTTTTTTTTtK.",  # 21: ボディ(口の行)
    "..KTTTTTTTTTtK..",  # 22: テーパー
    "...KKKKKKKKKK...",  # 23: 底
]

# 顔(鉢の上に重ねる差分): (row, col, palette_char)
FACES = {
    # ふつう: まる目 + ちいさな口
    "normal": [
        (20, 5, "K"), (20, 10, "K"),
        (21, 7, "K"), (21, 8, "K"),
    ],
    # よろこび: にこにこ目(へ の字を上下反転)+ ほっぺ
    "happy": [
        (20, 4, "K"), (20, 5, "K"), (21, 6, "K"),  # 左の笑い目 (⌒)
        (21, 9, "K"), (20, 10, "K"), (20, 11, "K"),  # 右の笑い目
        (21, 4, "P"), (21, 11, "P"),                 # ほっぺ
        (22, 7, "K"), (22, 8, "K"),                  # にこっと口
    ],
    # しょんぼり: 目が少し下がる + への字口(枯れ・骸骨等の罰表現は使わない)
    "sad": [
        (20, 5, "K"), (20, 10, "K"),
        (21, 7, "K"), (21, 8, "K"),                  # 口の山
        (22, 6, "K"), (22, 9, "K"),                  # 口の両端が下がる
    ],
}


def sparkle(r, c):
    """キラキラ(5px の十字星)。中心W・腕Y。"""
    return [(r - 1, c, "Y"), (r + 1, c, "Y"), (r, c - 1, "Y"), (r, c + 1, "Y"), (r, c, "W")]


def droplet(r, c):
    """ひとつぶの汗(2x2)。"""
    return [(r, c, "B"), (r + 1, c, "B"), (r + 1, c - 1, "B"), (r, c - 1, "W")]


# ---------------------------------------------------------------------------
# 植物(段階ごと)。(開始row, 16文字幅の行リスト)。"." は透過 = 下の鉢が見える
# 成長は REQUIREMENTS §3.9: 種(0)→芽(3)→双葉(7)→若葉(14)→つぼみ(30)→開花(60)
# stage0(種)は土に埋まっていて見えない = soil と同じ見た目(mapping.md 参照)
# ---------------------------------------------------------------------------
PLANTS = {
    # stage1 芽: ちいさな新芽
    "sprout": (11, [
        "....KK....KK....",
        "...KGLK..KLGK...",
        "....KGgKKgGK....",
        "......KGgK......",
        "......KGgK......",  # row15: 開口部を抜ける
        "......KggK......",  # row16: 土に根ざす
    ]),
    # stage2 双葉: ふっくらした子葉ペア
    "futaba": (9, [
        "..KKK......KKK..",
        ".KGLGK....KGLGK.",
        ".KGGGK....KGGGK.",
        "..KGGK....KGGK..",
        "...KGgK..KgGK...",
        ".....KGGggK.....",
        "......KGgK......",  # row15
        "......KggK......",  # row16
    ]),
    # stage2 双葉(しょんぼり): 葉が肩を落とすように垂れる。後退・枯れの表現はしない
    "futaba_sad": (10, [
        ".KKK........KKK.",
        "KGGGK......KGGGK",
        ".KGGGK....KGGGK.",
        "..KGGKKGgKKGGK..",
        "......KGgK......",
        "......KGgK......",  # row15
        "......KggK......",  # row16
    ]),
    # stage3 若葉: 双葉の上に新しい葉が出る
    "wakaba": (5, [
        "....KK....KK....",
        "...KGLK..KLGK...",
        "....KGgKKgGK....",
        "......KGgK......",
        "..KKK.KGgK.KKK..",
        ".KGLGKKGgKKGLGK.",
        ".KGGGKKGgKKGGGK.",
        "..KGGKKGgKKGGK..",
        "...KGgKGgKgGK...",
        "......KGgK......",
        "......KGgK......",  # row15
        "......KggK......",  # row16
    ]),
    # stage4 つぼみ: ふっくらしたピンクのつぼみ + がく
    "tsubomi": (3, [
        ".......KK.......",
        "......KPPK......",
        ".....KPWPPK.....",
        ".....KPPPPK.....",
        "......KPPK......",
        ".....KgGGgK.....",
        "......KGgK......",
        "..KKK.KGgK.KKK..",
        ".KGLGKKGgKKGLGK.",
        "..KGGKKGgKKGGK..",
        "...KgKKGgKKgK...",
        "......KGgK......",
        "......KGgK......",  # row15
        "......KggK......",  # row16
    ]),
    # stage5 開花: 大輪の花 + 互い違いの葉
    "kaika": (0, [
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
        "......KGgK......",  # row15
        "......KggK......",  # row16
    ]),
    # stage5 開花(しょんぼり): 花が少しうつむき、葉が垂れる。花は閉じない・枯れない
    "kaika_sad": (1, [
        "......KKKKKK....",
        ".....KPPPPPPK...",
        "....KPPKYYKPPK..",
        "....KPPYYYYPPK..",
        "....KPPKYYKPPK..",
        ".....KPPPPPPK...",
        "......KKKKKK....",
        "......KgGK......",
        ".KKK..KGgK..KKK.",
        "KGGGK.KGgK.KGGGK",
        ".KGGGKKGgKKGGGK.",
        "..KGGKKGgKKGGK..",
        "......KGgK......",
        "......KGgK......",
        "......KGgK......",  # row15
        "......KggK......",  # row16
    ]),
}

# ---------------------------------------------------------------------------
# 13 スプライトの定義(name → 構成)
# ---------------------------------------------------------------------------
SPRITES = {
    # ソロ状態 = stage0(種は土の中)。鉢はにこやかに待っている
    "soil":          {"plant": None,         "face": "normal", "extra": []},
    "stage1_normal": {"plant": "sprout",     "face": "normal", "extra": []},
    "stage1_happy":  {"plant": "sprout",     "face": "happy",
                      "extra": sparkle(8, 3) + sparkle(6, 12)},
    "stage2_normal": {"plant": "futaba",     "face": "normal", "extra": []},
    "stage2_happy":  {"plant": "futaba",     "face": "happy",
                      "extra": sparkle(6, 2) + sparkle(4, 13)},
    "stage3_normal": {"plant": "wakaba",     "face": "normal", "extra": []},
    "stage3_happy":  {"plant": "wakaba",     "face": "happy",
                      "extra": sparkle(3, 2) + sparkle(2, 13)},
    "stage4_normal": {"plant": "tsubomi",    "face": "normal", "extra": []},
    "stage4_happy":  {"plant": "tsubomi",    "face": "happy",
                      "extra": sparkle(3, 2) + sparkle(6, 13)},
    "stage5_normal": {"plant": "kaika",      "face": "normal", "extra": []},
    "stage5_happy":  {"plant": "kaika",      "face": "happy",
                      "extra": sparkle(4, 1) + sparkle(2, 14)},
    "stage2_sad":    {"plant": "futaba_sad", "face": "sad",
                      "extra": droplet(7, 13)},
    "stage5_sad":    {"plant": "kaika_sad",  "face": "sad",
                      "extra": droplet(2, 3)},
}

# モンタージュの並び順(G2 レビューで成長順に見えるように)
SHEET_ORDER = [
    ["soil", "stage1_normal", "stage2_normal", "stage3_normal", "stage4_normal", "stage5_normal"],
    [None,   "stage1_happy",  "stage2_happy",  "stage3_happy",  "stage4_happy",  "stage5_happy"],
    [None,   None,            "stage2_sad",    None,            None,            "stage5_sad"],
]
SHEET_BG = (0xF4, 0xEF, 0xE6, 0xFF)  # あたたかいオフホワイト


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
            raise ValueError("row %d out of canvas: %r" % (r, row))
        for c, ch in enumerate(row):
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


def build_sprite(name):
    spec = SPRITES[name]
    grid = blank_grid()
    paste_rows(grid, POT_START_ROW, POT)
    paste_pixels(grid, FACES[spec["face"]])
    if spec["plant"] is not None:
        start, rows = PLANTS[spec["plant"]]
        paste_rows(grid, start, rows)
    paste_pixels(grid, spec["extra"])
    return grid


def grid_to_rgba(grid):
    """grid(palette chars)→ list of bytearray scanlines (RGBA)。"""
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
    """8倍スプライトを格子状に並べた1枚のモンタージュを返す (rows, width, height)。"""
    pad = 2 * SCALE  # セル間余白(原寸2px相当)
    cell_w, cell_h = W * SCALE, H * SCALE
    cols = max(len(r) for r in SHEET_ORDER)
    rows_n = len(SHEET_ORDER)
    sheet_w = pad + cols * (cell_w + pad)
    sheet_h = pad + rows_n * (cell_h + pad)
    sheet = [bytearray(bytes(SHEET_BG) * sheet_w) for _ in range(sheet_h)]
    for gy, row_names in enumerate(SHEET_ORDER):
        for gx, name in enumerate(row_names):
            if name is None:
                continue
            x0 = pad + gx * (cell_w + pad)
            y0 = pad + gy * (cell_h + pad)
            big = sprites_rgba[name]
            for dy, line in enumerate(big):
                dest = sheet[y0 + dy]
                for dx in range(cell_w):
                    a = line[dx * 4 + 3]
                    if a == 0xFF:  # パレットは不透明/透明の2値
                        dest[(x0 + dx) * 4:(x0 + dx) * 4 + 4] = line[dx * 4:dx * 4 + 4]
    return sheet, sheet_w, sheet_h


def main():
    os.makedirs(PNG_DIR, exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)

    sprites_8x = {}
    for name in sorted(SPRITES):
        grid = build_sprite(name)
        rgba = grid_to_rgba(grid)
        out = os.path.join(PNG_DIR, name + ".png")
        write_png(out, W, H, rgba)
        big = scale_rows(rgba, SCALE)
        sprites_8x[name] = big
        write_png(os.path.join(PREVIEW_DIR, name + "@8x.png"), W * SCALE, H * SCALE, big)

    sheet, sw, sh = make_contact_sheet(sprites_8x)
    write_png(os.path.join(PREVIEW_DIR, "contact_sheet.png"), sw, sh, sheet)

    # --- 自己検証: 13枚 + 寸法 ---
    names = sorted(SPRITES)
    assert len(names) == 13, "expected 13 sprites, got %d" % len(names)
    for name in names:
        w, h = read_png_size(os.path.join(PNG_DIR, name + ".png"))
        assert (w, h) == (W, H), "%s: %dx%d != %dx%d" % (name, w, h, W, H)
        w, h = read_png_size(os.path.join(PREVIEW_DIR, name + "@8x.png"))
        assert (w, h) == (W * SCALE, H * SCALE), "%s@8x: bad size %dx%d" % (name, w, h)
    w, h = read_png_size(os.path.join(PREVIEW_DIR, "contact_sheet.png"))
    assert (w, h) == (sw, sh)
    print("OK: %d sprites -> %s" % (len(names), PNG_DIR))
    print("OK: previews   -> %s (contact_sheet %dx%d)" % (PREVIEW_DIR, sw, sh))
    return 0


if __name__ == "__main__":
    sys.exit(main())
