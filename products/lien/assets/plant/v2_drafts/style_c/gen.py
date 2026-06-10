#!/usr/bin/env python3
"""Lien 植物育成スプライト v2 / style_c「ゆるかわ くすみ」ジェネレータ。

スタイル候補の1つ。やさしい大人っぽさ・くすみカラー(ダスティ/グレイッシュ)で
おしゃれ・癒やし系。顔は「鉢」ではなく植物本体(丸い葉のあたま)に持たせて
キャラクター化する。鉢は小さめの土台。

技術仕様(依存ゼロ・既存 gen_sprites.py 方式を踏襲):
  - 外部依存なし(zlib + struct で PNG を直接書く)。Python 3.9+ / Pillow 不要
  - キャンバス 24x32 px(全スタイル共通の比較条件)
  - プレビューは 8 倍ニアレストネイバー拡大
  - キーフレーム 6 枚: soil / sprout / mid / late / final_normal / final_happy

出力:
  png/<name>.png        原寸 24x32(6枚)
  contact_sheet.png     8倍・横並びコンタクトシート(成長順)

使い方:
  python3 gen.py
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
# パレット — くすみ(ダスティ/グレイッシュ)トーン。彩度を落としつつ可愛さを保つ。
# 輪郭は黒ベタではなく「こげ茶」で柔らかい印象に。
# ---------------------------------------------------------------------------
PALETTE = {
    ".": None,                  # 透明
    "K": (0x6B, 0x57, 0x4E),    # 輪郭(やわらかいこげ茶 / ダスティブラウン)
    "E": (0x55, 0x44, 0x3C),    # 目(輪郭よりほんの少し濃いこげ茶。やさしい丸目)
    # 葉(くすみセージグリーン)
    "G": (0x9C, 0xB3, 0x8F),    # 葉(基本・くすみセージ)
    "g": (0x7E, 0x96, 0x73),    # 葉(影)
    "L": (0xC4, 0xD4, 0xB0),    # 葉(ハイライト・やわらかい黄緑)
    # 茎
    "M": (0x8F, 0xA8, 0x82),    # 茎(くすみグリーン)
    # 花(くすみピンク)
    "P": (0xE3, 0xB5, 0xBC),    # 花びら(くすみピンク)
    "p": (0xCE, 0x97, 0xA1),    # 花びら影(ダスティローズ)
    "Y": (0xF2, 0xDD, 0xB0),    # 花芯(くすみバタークリーム)
    # 鉢(ベージュ系の土台)
    "T": (0xD8, 0xC3, 0xAD),    # 鉢(くすみベージュ)
    "t": (0xBE, 0xA6, 0x8E),    # 鉢の影(グレイッシュベージュ)
    "S": (0x9A, 0x84, 0x71),    # 土(くすみブラウン)
    "s": (0xB0, 0x9A, 0x84),    # 土(明・フレック)
    # 表情・装飾
    "C": (0xE8, 0xB4, 0xB8),    # ほっぺ(くすみピンクのチーク)
    "W": (0xFF, 0xFC, 0xF6),    # 白ハイライト(目のきらめき / オフホワイト)
    "Z": (0xF4, 0xE6, 0xC9),    # きらきら(くすみイエロー・よろこび)
    "B": (0xAE, 0xC6, 0xCF),    # しずく(くすみブルー)※しょんぼり1粒まで
}

# ---------------------------------------------------------------------------
# 鉢(小さめの土台・全段階共通)。横16幅・中央寄せ。rows 25..31 に配置。
# 顔は鉢には描かない。鉢はあくまで土台。
# ---------------------------------------------------------------------------
POT_START_ROW = 25
POT = [
    ".....KKKKKKKKKKKKKK.....",   # 25: リム上端
    "....KTsTTTTTTTTTTsTK....",   # 26: リム
    "....KTTTTTTTTTTTTTTK....",   # 27: リム
    ".....KKKKKKKKKKKKKK.....",   # 28: リム下端
    "......KTTTTTTTTTTTK.....",   # 29: ボディ
    ".......KTttTTTTttTK.....",   # 30: ボディ影
    "........KKKKKKKKKK......",   # 31: 底
]


def droplet(r, c):
    """しずく1粒(しょんぼり用・2x2)。罰表現ではなく『ふぅ』のひとしずく。"""
    return [(r, c, "B"), (r + 1, c, "B"), (r + 1, c - 1, "B"), (r, c - 1, "W")]


def sparkle(r, c):
    """きらきら(よろこび用・小さな十字星)。中心W・腕Z。"""
    return [(r - 1, c, "Z"), (r + 1, c, "Z"), (r, c - 1, "Z"),
            (r, c + 1, "Z"), (r, c, "W")]


# ---------------------------------------------------------------------------
# 植物本体(段階ごと)。(開始row, 行リスト)。各行は W 幅。
# 「.」は透過(下の鉢が見える)。顔(目・ほっぺ・口)は本体に直接描き込む。
# 目は大きめの丸目 + 白ハイライト、ほっぺはくすみピンク、ゆるい点目寄りの表情。
# ---------------------------------------------------------------------------

# stage0 soil: 種は土の中。鉢だけ + 土の盛り上がりに小さな寝顔(zzz)
SOIL_EXTRA = [
    # 土のうえにちょこんと小さな芽の先(まだ顔なし、これから育つ余白)
    (24, 11, "g"), (24, 12, "g"),
    (23, 11, "L"), (23, 12, "G"),
    # ねむっている zzz(これから生まれる気配)
    (20, 16, "K"), (21, 17, "K"), (22, 18, "K"),
]

# stage1 sprout: 芽。まるい双葉のあたまに、はじめての顔。
SPROUT = (16, [
    "..........KK..........",  # 16 芽の先
    ".......KKKGGKKK.......",  # 17 双葉のひろがり
    "....KKKGLGGGGLGKKK....",  # 18
    "...KGLGGGGGGGGGGLGK...",  # 19 あたま(丸い)
    "...KGGEEGGGGGGEEGGK...",  # 20 目の上ぶち(おおきな丸目)
    "...KGGEWGGGGGGEWGGK...",  # 21 目 + 白ハイライト
    "...KCCGGGGwwGGGGGCCK..",  # 22 ほっぺ + ニコッと口
    "....KGGGGwwwwGGGGGK...",  # 23 口のカーブ
    ".....KGGGGGGGGGGK.....",  # 24 あごのまるみ
    "........KGggK.........",  # 25 → 鉢のなかへ(茎)
])

# stage2 mid: 双葉から本葉が出て、ふっくら。
MID = (10, [
    ".........KKKK.........",  # 10 てっぺんの新芽
    "........KGLLGK........",  # 11
    ".......KGGGGGGK.......",  # 12
    "....KKKKGGGGGGKKKK....",  # 13 横にひろがる葉
    "...KGLGGGGGGGGGGLGK...",  # 14
    "..KGLGGGGGGGGGGGGLGK..",  # 15 あたま(丸い)
    "..KGGEEGGGGGGGGEEGGK..",  # 16 目の上ぶち(おおきな丸目)
    "..KGGEWGGGGGGGGEWGGK..",  # 17 目 + 白ハイライト
    "..KGCCGGGGGGGGGGCCGK..",  # 18 ほっぺ(くすみピンク・目の下)
    "..KGGGGGwwGGGGwwGGGK..",  # 19 ニコッと口(口角)
    "...KGGGGGwwwwwwGGGGK..",  # 20 口のカーブ
    "....KGGGGGGGGGGGGK....",  # 21 あごのまるみ
    ".....KKGGGGGGGGKK.....",  # 22
    ".........KMMK.........",  # 23 茎
    ".........KMMK.........",  # 24 茎 → 鉢へ
])

# stage3 late: つぼみがふくらむ大きめのあたま + わき葉。
LATE = (6, [
    ".........KPPK.........",  # 6  つぼみの先
    "........KPpPPK........",  # 7
    "........KPPPPK........",  # 8  つぼみ
    ".........KppK.........",  # 9  がく
    "....KKKKKGGGGKKKKK....",  # 10
    "...KGLGGGGGGGGGGLGK...",  # 11
    "..KGLGGGGGGGGGGGGLGK..",  # 12 あたま
    "..KGGGGGGGGGGGGGGGGK..",  # 13
    "..KGGEEGGGGGGGGEEGGK..",  # 14 目の上ぶち(おおきな丸目)
    "..KGGEWGGGGGGGGEWGGK..",  # 15 目 + 白ハイライト
    "..KGCCGGGGGGGGGGCCGK..",  # 16 ほっぺ(目の下)
    "..KGGGGGwwGGGGwwGGGK..",  # 17 にっこり口(口角)
    "...KGGGGGwwwwwwGGGGK..",  # 18 口のカーブ
    "....KGGGGGGGGGGGGK....",  # 19 あご
    ".....KKGGGGGGGGKK.....",  # 20
    "....KGGGK....KGGGK....",  # 21 わき葉
    "...KGLGK......KGLGK...",  # 22 わき葉
    "....KKK..KMMK..KKK....",  # 23 茎
    ".........KMMK.........",  # 24 茎 → 鉢へ
])

# stage5 final(ふつう): 大輪のくすみピンクの花が開き、おだやかな笑顔。
FINAL = (2, [
    "........KKKKKK........",  # 2  花の上ふち
    ".......KPPPPPPK.......",  # 3
    "......KPPPppPPPK......",  # 4  花びら
    "......KPPYYYYPPK......",  # 5  花芯
    "......KPpYWWYpPK......",  # 6  花芯ハイライト
    "......KPPYYYYPPK......",  # 7
    ".......KPPPppPPK......",  # 8
    "........KKKKKK........",  # 9
    "....KKKKKGGGGKKKKK....",  # 10 顔つきのあたま(花の下)
    "...KGLGGGGGGGGGGLGK...",  # 11
    "..KGLGGGGGGGGGGGGLGK..",  # 12
    "..KGGEEGGGGGGGGEEGGK..",  # 13 目の上ぶち(おおきな丸目)
    "..KGGEWGGGGGGGGEWGGK..",  # 14 目 + 白ハイライト
    "..KGCCGGGGGGGGGGCCGK..",  # 15 ほっぺ(目の下)
    "..KGGGGGwwGGGGwwGGGK..",  # 16 にっこり口(口角)
    "...KGGGGGwwwwwwGGGGK..",  # 17 口のカーブ
    "....KGGGGGGGGGGGGK....",  # 18 あご
    ".....KKGGGGGGGGKK.....",  # 19
    "....KGGGK....KGGGK....",  # 20 わき葉
    "...KGLGK......KGLGK...",  # 21 わき葉
    "....KKK..KMMK..KKK....",  # 22 茎
    ".........KMMK.........",  # 23 茎
    ".........KMMK.........",  # 24 茎 → 鉢へ
])

# stage5 final(よろこび): 目がにっこり弧(^▽^)に + 大きな笑顔 + ほっぺ濃いめ。
FINAL_HAPPY = (2, [
    "........KKKKKK........",  # 2  花の上ふち
    ".......KPPPPPPK.......",  # 3
    "......KPPPppPPPK......",  # 4  花びら
    "......KPPYYYYPPK......",  # 5  花芯
    "......KPpYWWYpPK......",  # 6  花芯ハイライト
    "......KPPYYYYPPK......",  # 7
    ".......KPPPppPPK......",  # 8
    "........KKKKKK........",  # 9
    "....KKKKKGGGGKKKKK....",  # 10 あたま
    "...KGLGGGGGGGGGGLGK...",  # 11
    "..KGLGGGGGGGGGGGGLGK..",  # 12
    "..KGEEGGGGGGGGGGEEGK..",  # 13 にっこり弧の目(口角上がり ^ ^)
    "..KEGGEGGGGGGGGEGGEK..",  # 14 にっこり弧の目(両端さがり)
    "..KGCCGGGGGGGGGGCCGK..",  # 15 ほっぺ(目の下)
    "..KGGGGGwwGGGGwwGGGK..",  # 16 おおきな笑顔(口角)
    "...KGGGGGwwwwwwGGGGK..",  # 17 口のカーブ
    "....KGGGGGGGGGGGGK....",  # 18 あご
    ".....KKGGGGGGGGKK.....",  # 19
    "....KGGGK....KGGGK....",  # 20 わき葉
    "...KGLGK......KGLGK...",  # 21 わき葉
    "....KKK..KMMK..KKK....",  # 22 茎
    ".........KMMK.........",  # 23 茎
    ".........KMMK.........",  # 24 茎 → 鉢へ
])

# 「w」= 口の色は輪郭色(K)で描くため、置換用に扱う。
# 表情の差分(よろこび: にっこり口を強調 + きらきら + ほっぺ濃いめ)。

PLANTS = {
    "sprout": SPROUT,
    "mid": MID,
    "late": LATE,
    "final": FINAL,
    "final_happy": FINAL_HAPPY,
}

# 植物のアートは作画しやすい 22 幅で持ち、左右に透過1列ずつ足して W=24 へ中央寄せ。
_ART_W = 22
_PAD = (W - _ART_W) // 2  # = 1
PLANTS = {
    name: (start, ["." * _PAD + r + "." * _PAD for r in rows])
    for name, (start, rows) in PLANTS.items()
}

# ---------------------------------------------------------------------------
# キーフレーム定義(name → 構成)
# ---------------------------------------------------------------------------
SPRITES = {
    "soil":         {"plant": None,    "extra": SOIL_EXTRA, "mouth": None},
    "sprout":       {"plant": "sprout", "extra": [],         "mouth": "smile"},
    "mid":          {"plant": "mid",    "extra": [],         "mouth": "smile"},
    "late":         {"plant": "late",   "extra": [],         "mouth": "smile"},
    "final_normal": {"plant": "final",  "extra": [],         "mouth": "smile"},
    "final_happy":  {"plant": "final_happy", "extra": (sparkle(6, 2) + sparkle(4, 21)
                                                       + sparkle(11, 1)),
                     "mouth": "happy"},
}

# コンタクトシートの並び(成長順)
SHEET_ORDER = ["soil", "sprout", "mid", "late", "final_normal", "final_happy"]
SHEET_BG = (0xF6, 0xF1, 0xE9, 0xFF)  # くすみオフホワイト(やわらか背景)


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
            raise ValueError("row %d out of canvas (%d): %r" % (r, H, row))
        for c, ch in enumerate(row):
            key = ch
            if ch == "w":      # 口 = 輪郭色で描く
                key = "K"
            if key not in PALETTE:
                raise ValueError("unknown palette char %r in %r" % (ch, row))
            if ch != ".":
                grid[r][c] = key


def paste_pixels(grid, pixels):
    for r, c, ch in pixels:
        if not (0 <= r < H and 0 <= c < W):
            raise ValueError("pixel out of canvas: %r" % ((r, c, ch),))
        if ch not in PALETTE:
            raise ValueError("unknown palette char %r" % ch)
        grid[r][c] = ch


def apply_mouth(grid, plant_rows_info, mouth):
    """よろこび時はほっぺを濃く・きらきらは別途。口形状は本体に既に描かれている。
    ここでは『happy』のときほっぺ(C)を1段広げてニコ度を上げる差分のみ行う。"""
    if mouth != "happy":
        return
    # ほっぺを少し濃く(C→そのまま) + 目を弧にする簡易差分は省略。
    # きらきらは extra で付与済み。ここでは何もしない(口は本体定義のまま)。
    return


def build_sprite(name):
    spec = SPRITES[name]
    grid = blank_grid()
    paste_rows(grid, POT_START_ROW, POT)
    if spec["plant"] is not None:
        start, rows = PLANTS[spec["plant"]]
        paste_rows(grid, start, rows)
    paste_pixels(grid, spec["extra"])
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
    """8倍スプライトを成長順に横並びにした1枚のシートを返す。"""
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
        out = os.path.join(PNG_DIR, name + ".png")
        write_png(out, W, H, rgba)
        sprites_8x[name] = scale_rows(rgba, SCALE)

    sheet, sw, sh = make_contact_sheet(sprites_8x)
    write_png(os.path.join(HERE, "contact_sheet.png"), sw, sh, sheet)

    # --- 自己検証: 6枚 + 寸法 ---
    assert len(SPRITES) == 6, "expected 6 keyframes, got %d" % len(SPRITES)
    for name in SPRITES:
        w, h = read_png_size(os.path.join(PNG_DIR, name + ".png"))
        assert (w, h) == (W, H), "%s: %dx%d != %dx%d" % (name, w, h, W, H)
    w, h = read_png_size(os.path.join(HERE, "contact_sheet.png"))
    assert (w, h) == (sw, sh)
    print("OK: %d keyframes -> %s" % (len(SPRITES), PNG_DIR))
    print("OK: contact_sheet %dx%d -> %s" % (sw, sh, os.path.join(HERE, "contact_sheet.png")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
