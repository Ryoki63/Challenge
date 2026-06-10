#!/usr/bin/env python3
"""Lien 植物スプライト v2 / style_d「マスコット生き物」ジェネレータ。

第2案スタイル候補のひとつ。v0 は鉢に顔を描いて差し戻されたため、
本案では「植物そのものをゆるい生き物キャラ(マスコット)」として擬人化する。
本体に大きな目・白ハイライト・ほっぺを持たせ、ちょこんとした葉の手足を足す。

依存ゼロ(zlib + struct で PNG 直書き)。Python 3.9+ / Pillow 不要。
キャンバスは全スタイル共通の 24x32px。プレビューは8倍ニアレスト拡大。

出力:
  png/<name>.png        原寸 24x32(キーフレーム6枚)
  contact_sheet.png     8倍・成長順の横並びコンタクトシート

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
# パレット — 明るく柔らかいマスコット配色。輪郭は黒ではなく濃いめの緑/茶で
# 「やわらかさ」を出す。目は大きく、白ハイライトとほっぺで愛嬌を出す。
# ---------------------------------------------------------------------------
PALETTE = {
    ".": None,                  # 透明
    "K": (0x4A, 0x3B, 0x2E),    # 輪郭(やわらかいダークブラウン)
    "o": (0x3A, 0x5A, 0x32),    # 葉の輪郭(濃い緑・体のフチ)
    # 体(植物=生き物の本体)
    "G": (0x86, 0xD7, 0x6E),    # 体・葉(基本グリーン)
    "g": (0x5F, 0xB5, 0x55),    # 体の影
    "L": (0xC4, 0xF0, 0x9E),    # 体ハイライト(明るい黄緑)
    # 顔パーツ
    "E": (0x33, 0x2A, 0x24),    # 目(黒に近いこげ茶でやさしく)
    "W": (0xFF, 0xFF, 0xFF),    # 白ハイライト(目のキラ・つや)
    "P": (0xFF, 0xAE, 0xC9),    # ほっぺ(やわらかピンク)
    "M": (0xC9, 0x5B, 0x6B),    # 口(あずきピンク)
    # 卵/種(soil段階の「生き物が出てくる前」)
    "S": (0xF3, 0xE3, 0xC6),    # たまご殻(クリーム)
    "s": (0xE0, 0xC8, 0x9E),    # たまご殻の影
    "d": (0xC8, 0x9A, 0x5A),    # たまごの斑点
    # 花(完成形マスコットの頭の飾り)
    "F": (0xFF, 0xC2, 0xE0),    # 花びら(明るいピンク)
    "f": (0xF2, 0x9A, 0xC4),    # 花びらの影
    "Y": (0xFF, 0xE0, 0x73),    # 花芯(イエロー)
    # 土台(小さな鉢/地面)
    "T": (0xD9, 0x9A, 0x66),    # 鉢(あたたかいテラコッタ)
    "t": (0xB9, 0x77, 0x47),    # 鉢の影
    "U": (0x8A, 0x5A, 0x3A),    # 土
    # しずく(しょんぼり1粒のみ・罰表現ではない)
    "B": (0x8E, 0xCF, 0xF0),    # しずく(みずいろ)
}

OPAQUE_SHEET_BG = (0xFB, 0xF4, 0xE8, 0xFF)  # あたたかいオフホワイト


# ---------------------------------------------------------------------------
# 各キーフレームは 24文字 x 32行 の文字グリッドで直接描く。
# "." は透明。座標を読みやすくするため全段で土台(鉢)を共通の足場にする。
# 体に必ず顔(大きな目+ハイライト+ほっぺ)を置く = キャラクター化。
# ---------------------------------------------------------------------------

# 共通の小さな土台(鉢)。row 26..31。生き物が「鉢から顔を出す」構図。
def pot_rows():
    return {
        26: "......oooooooooooo......",
        27: ".....oTTTTTTTTTTTTo.....",
        28: ".....oTTLTTTTTTTtTo.....",
        29: "......oTTTTTTTTTTo......",
        30: ".......otTTTTTTto.......",
        31: ".........oooooo.........",
    }


def overlay(grid, rowmap):
    for r, line in rowmap.items():
        if isinstance(line, dict):
            # col -> char 形式(部分的な上書き、例: 葉の耳)
            for c, ch in line.items():
                if ch not in PALETTE:
                    raise ValueError("unknown char %r at (%d,%d)" % (ch, r, c))
                if ch != "." and 0 <= c < W:
                    grid[r][c] = ch
            continue
        # 文字列形式。右側の余白(".")は省略可 → 24未満は "." で埋める。
        if len(line) > W:
            raise ValueError("row %d width %d > %d: %r" % (r, len(line), W, line))
        if len(line) < W:
            line = line + "." * (W - len(line))
        for c, ch in enumerate(line):
            if ch not in PALETTE:
                raise ValueError("unknown char %r at row %d: %r" % (ch, r, line))
            if ch != ".":
                grid[r][c] = ch


def blank():
    return [["." for _ in range(W)] for _ in range(H)]


# === soil: たまご(まだ生き物が出てくる前)。鉢にちょこんと収まる ===
def make_soil():
    g = blank()
    overlay(g, pot_rows())
    # まるいたまご(クリーム色・斑点入り)。生き物が出てくる前のわくわく感
    egg = {
        16: "..........oooo.........",
        17: ".........oSSSSSo........",
        18: "........oSSWWSSSSo......",
        19: ".......oSSSWWSSSSSo.....",
        20: ".......oSSSSSSSSdSo.....",
        21: ".......oSSSdSSSSSSo.....",
        22: ".......oSSSSSSSSSSo.....",
        23: ".......osSSSdSSSSso.....",
        24: "........osSSSSSSso......",
        25: ".........ossSSsso......",
    }
    overlay(g, egg)
    overlay(g, pot_rows())  # 鉢を前面に(たまごの下端が鉢に収まる)
    overlay(g, {k: v for k, v in egg.items() if k < 26})
    return g


# === 共通の顔(本体に置く)。大きな目+白ハイライト+ほっぺ ===
# 目は 2x2 の黒丸 + 右上に白ハイライト1px。左右の目は中心からほどよい間隔。
def face_normal(cx, eye_row):
    """ふつう顔。cx=体の中心列, eye_row=目の上端行。
    左右対称: 各目は2px幅、ハイライト白は外側上に1pxずつ(つやめく大きな目)。"""
    r = eye_row
    return {
        r:     {cx-3: "W", cx-2: "E", cx+2: "E", cx+3: "W"},   # 目の上段(外上にハイライト)
        r+1:   {cx-3: "E", cx-2: "E", cx+2: "E", cx+3: "E"},   # 目の下段
        r+2:   {cx-4: "P", cx-3: "P", cx+3: "P", cx+4: "P"},   # ほっぺ
        r+3:   {cx-1: "M", cx: "M"},                           # ちいさな口
    }


def face_happy(cx, eye_row):
    """よろこび顔。にっこり伏せ目(^ ^)+ ほっぺ濃いめ + ぱくっと開いた笑顔。"""
    r = eye_row
    return {
        r:     {cx-4: "E", cx-2: "E", cx+2: "E", cx+4: "E"},          # ^ ^ の上端
        r+1:   {cx-3: "E", cx+3: "E", cx-2: "W", cx+2: "W"},          # ^ ^ の頂点+つや
        r+2:   {cx-5: "P", cx-4: "P", cx-3: "P", cx+3: "P", cx+4: "P", cx+5: "P"},  # ほっぺ
        r+3:   {cx-2: "K", cx-1: "M", cx: "M", cx+1: "K"},            # 大きく開いた笑い口
        r+4:   {cx-1: "M", cx: "M"},
    }


def apply_face(grid, facemap):
    for r, cols in facemap.items():
        for c, ch in cols.items():
            if 0 <= r < H and 0 <= c < W:
                grid[r][c] = ch


# === sprout: ちびキャラ誕生。まるく縦長の体に、くるんと曲がった芽の双葉 ===
def make_sprout(happy=False):
    g = blank()
    body = {
        # 頭のてっぺんから出る、くるんとした芽(双葉)
        11: ".............oo........",
        12: "...........ooGLo.......",   # 右にくるん
        13: "..........oGGGo........",
        14: "...........oGo.........",
        15: "...........oGo.........",
        # まるく縦長の体(顔が乗る器)
        16: ".........ooGGGGoo......",
        17: "........oGGGGGGGGo.....",
        18: ".......oGGLLLGGGGGo....",
        19: ".......oGGGGGGGGGGo....",
        20: ".......oGGGGGGGGGGo....",
        21: ".......oGGGGGGGGGGo....",
        22: ".......oGGGGGGGGGGo....",
        23: "........oGGGGGGGGo.....",
        24: ".........oGGGGGGo......",
        25: "..........oGGGGo.......",
    }
    overlay(g, body)
    overlay(g, pot_rows())
    overlay(g, {k: v for k, v in body.items() if k < 26})
    # ちょこんとした葉の手(両脇・体の外に少しはみ出す)
    arms = {
        20: ".....oGo..........oGo..",
        21: "......o............o...",
    }
    for r, line in arms.items():
        for c, ch in enumerate(line):
            if ch != "." and g[r][c] == ".":
                g[r][c] = ch
    cx = 12
    apply_face(g, (face_happy if happy else face_normal)(cx, 18))
    return g


# === mid: 双葉のちびキャラ。体が少し縦長に、葉の耳が2枚 ===
def make_mid(happy=False):
    g = blank()
    overlay(g, pot_rows())
    body = {
        13: "..........oo.oo........",
        14: ".........oGGoGGo.......",   # 葉の耳(左右)
        15: ".........oGLoLGo.......",
        16: "..........oGoGo........",
        17: "...........oGo.........",
        18: "........ooGGGGGoo......",
        19: ".......oGGGGGGGGGo.....",
        20: "......oGGLLLLLGGGGo....",
        21: "......oGGGGGGGGGGGo....",
        22: "......oGGGGGGGGGGGo....",
        23: ".......oGGGGGGGGGo.....",
        24: ".......oGGGGGGGGGo.....",
        25: "........ooGGGGGoo......",
        26: "..........ooooo........",
    }
    overlay(g, body)
    overlay(g, pot_rows())  # 鉢を前面に(体の下端が鉢に隠れる)
    # 体を鉢の上に再描画(鉢で消えた上半分を戻す)
    overlay(g, {k: v for k, v in body.items() if k < 26})
    # 葉の手
    arms = {
        21: ".....oG...........Go...",
        22: ".....og...........go...",
    }
    for r, line in arms.items():
        for c, ch in enumerate(line):
            if ch != "." and g[r][c] == ".":
                g[r][c] = ch
    cx = 12
    apply_face(g, (face_happy if happy else face_normal)(cx, 19))
    return g


# === late: 若葉。頭に葉が3枚茂る、体ふっくら ===
def make_late(happy=False):
    g = blank()
    body = {
        # まんなかの新芽 + 左右にすっと伸びた葉(三つ葉の冠・すっきり)
        9:  "...........oo..........",
        10: "..........oGLo.........",
        11: "..........oGGo.........",
        12: ".......o...oGo...o.....",
        13: "......oGo..oGo..oGo....",
        14: ".....oGGLo.oGo.oLGGo...",
        15: ".....oGGGGo.o.oGGGGo...",
        16: "......oGGGoooGGGo......",
        17: ".......oGGGoGGGo.......",
        18: "........ooGGGoo........",
        # ふっくらした体
        19: ".......ooGGGGGGoo......",
        20: "......oGGGGGGGGGGo.....",
        21: ".....oGGLLLLLLLLGGo....",
        22: ".....oGGGGGGGGGGGGo....",
        23: "....oGGGGGGGGGGGGGGo...",
        24: "....oGGGGGGGGGGGGGGo...",
        25: ".....oGGGGGGGGGGGGo....",
        26: "......oGGGGGGGGGGo.....",
    }
    overlay(g, body)
    overlay(g, pot_rows())
    overlay(g, {k: v for k, v in body.items() if k < 27})
    # 葉の手
    arms = {
        23: "...oGo............oGo..",
        24: "....o..............o...",
    }
    for r, line in arms.items():
        for c, ch in enumerate(line):
            if ch != "." and g[r][c] == ".":
                g[r][c] = ch
    cx = 12
    apply_face(g, (face_happy if happy else face_normal)(cx, 21))
    return g


# === final: 完成形マスコット。頭に大きな花、ぷっくり体、手足 ===
def make_final(happy=False):
    g = blank()
    flower = {
        1:  ".........FFFFFF........",
        2:  ".......FFFFFFFFFF......",
        3:  "......FFFFYYYYFFFF.....",
        4:  "......FFFYWWYYFFFF.....",
        5:  "......FFFYYYYYFFFF.....",
        6:  "......FFFFYYYYFFFF.....",
        7:  ".......FFFFFFFFFF......",
        8:  ".......ffFFFFFFff......",
        9:  ".........ffFFff........",
        10: "...........GG..........",   # 茎(短い)
    }
    overlay(g, flower)
    # 花のフチ
    overlay(g, {
        2:  "......oFFFFFFFFFFo.....",
        7:  "......offFFFFFFffo.....",
    })
    body = {
        11: "........ooGGGGoo.......",
        12: ".......oGGGGGGGGo......",
        13: "......oGGGGGGGGGGo.....",
        14: ".....oGGGGGGGGGGGGo....",
        15: ".....oGGLLLLLLLLGGo....",
        16: "....oGGGGGGGGGGGGGGo...",
        17: "....oGGGGGGGGGGGGGGo...",
        18: "....oGGGGGGGGGGGGGGo...",
        19: "....oGGGGGGGGGGGGGGo...",
        20: ".....oGGGGGGGGGGGGo....",
        21: ".....oGGGGGGGGGGGGo....",
        22: "......oGGGGGGGGGGo.....",
        23: ".......oGGGGGGGGo......",
    }
    overlay(g, body)
    overlay(g, pot_rows())
    overlay(g, {k: v for k, v in body.items() if k < 26})
    # 葉っぱの耳(頭の両脇)
    overlay(g, {
        13: {2: "o", 3: "G", 20: "o", 19: "G"},
        14: {1: "o", 2: "G", 3: "L", 21: "o", 20: "G", 19: "L"},
        15: {2: "o", 3: "G", 20: "o", 19: "G"},
    })
    # 葉の手
    arms = {
        18: "...oG...............Go.",
        19: "...og...............go.",
        20: "....og.............go..",
    }
    for r, line in arms.items():
        for c, ch in enumerate(line):
            if ch != "." and g[r][c] == ".":
                g[r][c] = ch
    cx = 12
    apply_face(g, (face_happy if happy else face_normal)(cx, 16))
    if happy:
        # きらきら(よろこび)
        overlay(g, {
            4:  {2: "Y", 21: "Y"},
            5:  {1: "Y", 3: "Y", 20: "Y", 22: "Y"},
            6:  {2: "Y", 21: "Y"},
        })
    return g


FRAMES = [
    ("soil",         make_soil),
    ("sprout",       lambda: make_sprout(False)),
    ("mid",          lambda: make_mid(False)),
    ("late",         lambda: make_late(False)),
    ("final_normal", lambda: make_final(False)),
    ("final_happy",  lambda: make_final(True)),
]


# ---------------------------------------------------------------------------
# PNG 出力(reference: tools/gen_sprites.py を踏襲)
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
    sheet = [bytearray(bytes(OPAQUE_SHEET_BG) * sheet_w) for _ in range(sheet_h)]
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
    for name, fn in FRAMES:
        grid = fn()
        rgba = grid_to_rgba(grid)
        write_png(os.path.join(PNG_DIR, name + ".png"), W, H, rgba)
        sprites_8x[name] = scale_rows(rgba, SCALE)
        order.append(name)

    sheet, sw, sh = make_contact_sheet(sprites_8x, order)
    write_png(SHEET_PATH, sw, sh, sheet)

    # 自己検証
    assert len(FRAMES) == 6, "expected 6 keyframes"
    for name, _ in FRAMES:
        w, h = read_png_size(os.path.join(PNG_DIR, name + ".png"))
        assert (w, h) == (W, H), "%s: %dx%d != %dx%d" % (name, w, h, W, H)
    w, h = read_png_size(SHEET_PATH)
    assert (w, h) == (sw, sh)
    print("OK: %d keyframes -> %s" % (len(FRAMES), PNG_DIR))
    print("OK: contact_sheet %dx%d -> %s" % (sw, sh, SHEET_PATH))
    return 0


if __name__ == "__main__":
    sys.exit(main())
