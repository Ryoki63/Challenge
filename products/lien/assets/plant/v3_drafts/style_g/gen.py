#!/usr/bin/env python3
"""Lien 植物育成スプライト v3 / style_g「ちびもちマスコット」ジェネレータ。

48x64 px・透過。手描きグリッドを廃止し、すべてプロシージャル描画:
  - fill_circle / fill_ellipse / 円unionブロブ(述語ベース)
  - 左半分のみ評価 → 水平ミラー(シルエット左右対称をコードで保証)
  - 外周1px輪郭の自動付与(パーツごとの8近傍膨張リング)
  - セルシェード(右下影・左上ライト)+ 頭頂ハイライト
決定論(乱数・時刻不使用)。python3 標準ライブラリのみ(zlib+struct)。

コンセプト: v2-B「レトロたまごっち」の太めソフトブラック輪郭言語を踏襲しつつ、
頭身を低く・もちっと幅広のブロブ。鉢のリムにぽてっと乗り、左右にちょこんと
丸い葉っぱの手。「もちもちした小動物のような植物」。

出力:
  png/<name>.png     原寸 48x64(soil/sprout/mid/late/final_normal/final_happy)
  contact_sheet.png  4倍ニアレストネイバー・クリーム背景・成長順モンタージュ

使い方:
  python3 gen.py
"""

import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PNG_DIR = os.path.join(HERE, "png")
SHEET_PATH = os.path.join(HERE, "contact_sheet.png")

W, H = 48, 64
AX = (W - 1) / 2.0  # 対称軸 x=23.5(ピクセル中心座標系)
SCALE = 4

# ---------------------------------------------------------------------------
# パレット
# ---------------------------------------------------------------------------
OUT      = (0x33, 0x2E, 0x29)  # 輪郭(ソフトブラック)
GREEN    = (0xA8, 0xD9, 0x58)  # 本体(あたたかいイエローグリーン)
GREEN_SH = (0x74, 0xA8, 0x3E)  # 本体影
GREEN_LT = (0xD2, 0xEE, 0x9B)  # 本体ライト
PINK     = (0xFF, 0xAD, 0x9E)  # 花(ピーチピンク)
PINK_DK  = (0xF2, 0x77, 0x6B)  # 花影
CREAM    = (0xFF, 0xE3, 0xA0)  # 花芯(クリーム)
POT      = (0xC9, 0x8C, 0x5F)  # 鉢(やわらかブラウン)
POT_SH   = (0xA6, 0x6C, 0x45)  # 鉢影
POT_LT   = (0xE3, 0xAE, 0x80)  # 鉢ライト
SOIL     = (0x8B, 0x5E, 0x3F)  # 土
SOIL_LT  = (0xA9, 0x79, 0x52)  # 土ライト
EYE      = (0x4A, 0x33, 0x2B)  # 目・口(ベタ塗りこげ茶)
WHITE    = (0xFF, 0xFF, 0xFF)  # 目ハイライト
CHEEK    = (0xFF, 0xC2, 0xB4)  # ほっぺ(薄ピンク)
GOLD     = (0xF5, 0xB8, 0x3D)  # キラキラ

SHEET_BG = (0xFB, 0xF3, 0xE2)  # コンタクトシート背景(クリーム)

GREEN_FAMILY = {GREEN, GREEN_SH, GREEN_LT}

# ---------------------------------------------------------------------------
# 形状述語(ピクセル中心座標 (x+0.5, y+0.5) で評価)
# ---------------------------------------------------------------------------

def circle(cx, cy, r):
    r2 = r * r
    return lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= r2


def ellipse(cx, cy, rx, ry):
    return lambda x, y: ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0


def union(*preds):
    return lambda x, y: any(p(x, y) for p in preds)


# ---------------------------------------------------------------------------
# マスク(48x64 bool)。左半分のみ評価して水平ミラー → 対称保証。
# ---------------------------------------------------------------------------

def new_mask():
    return [[False] * W for _ in range(H)]


def half_fill(mask, pred):
    """左半分(x=0..23)で述語を評価し、ミラー先 x'=47-x にも同時に立てる。"""
    for y in range(H):
        py = y + 0.5
        for x in range(W // 2):
            if pred(x + 0.5, py):
                mask[y][x] = True
                mask[y][W - 1 - x] = True


def hspan(mask, y, x0, x1):
    """行 y の左半分カラム x0..x1 を立て、ミラーも立てる(台形・帯用)。"""
    for x in range(x0, x1 + 1):
        mask[y][x] = True
        mask[y][W - 1 - x] = True


def mask_cells(mask):
    return [(x, y) for y in range(H) for x in range(W) if mask[y][x]]


def dilate(mask):
    """8近傍膨張。輪郭リング = dilate(mask) - mask。"""
    out = new_mask()
    for y in range(H):
        for x in range(W):
            if not mask[y][x]:
                continue
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < W and 0 <= ny < H:
                        out[ny][nx] = True
    return out


def cel_sets(mask):
    """セルシェード領域: 右下内縁 → 影 / 左上内縁 → ライト。"""
    cs = mask_cells(mask)
    if not cs:
        return set(), set()
    xs = [c[0] for c in cs]
    ys = [c[1] for c in cs]
    cx = (min(xs) + max(xs)) / 2.0
    cy = (min(ys) + max(ys)) / 2.0

    def inm(x, y):
        return 0 <= x < W and 0 <= y < H and mask[y][x]

    sh, lt = set(), set()
    for (x, y) in cs:
        er = not inm(x + 2, y)
        eb = not inm(x, y + 2)
        ebr = not inm(x + 1, y + 1)
        if (er and x > cx) or (eb and y > cy) or (ebr and x >= cx and y >= cy):
            sh.add((x, y))
            continue
        el = not inm(x - 2, y)
        et = not inm(x, y - 2)
        if (el and x < cx and y < cy) or (et and y < cy and x < cx):
            lt.add((x, y))
    return sh, lt


# ---------------------------------------------------------------------------
# キャンバス
# ---------------------------------------------------------------------------

class Canvas:
    def __init__(self):
        self.px = [[None] * W for _ in range(H)]  # None = 透明 / (r,g,b)

    def set(self, x, y, col):
        if 0 <= x < W and 0 <= y < H:
            self.px[y][x] = col

    def get(self, x, y):
        if 0 <= x < W and 0 <= y < H:
            return self.px[y][x]
        return None

    def hpx(self, y, x, col, clip=None):
        """左半分座標 x のピクセルとミラー先に col を置く(対称プロット)。"""
        for xx in (x, W - 1 - x):
            if clip is None or self.get(xx, y) in clip:
                self.set(xx, y, col)


def draw_part(cv, mask, fill, shade=True, sh_col=None, lt_col=None,
              ring=True, ring_col=OUT, top_hl=None):
    """パーツ描画: 輪郭リング(自動付与)→ 塗り → セルシェード → 頭頂ハイライト。"""
    if ring:
        dil = dilate(mask)
        for y in range(H):
            for x in range(W):
                if dil[y][x] and not mask[y][x]:
                    cv.set(x, y, ring_col)
    for (x, y) in mask_cells(mask):
        cv.set(x, y, fill)
    if shade and (sh_col or lt_col):
        sh, lt = cel_sets(mask)
        if sh_col:
            for (x, y) in sh:
                cv.set(x, y, sh_col)
        if lt_col:
            for (x, y) in lt:
                cv.set(x, y, lt_col)
    if top_hl is not None:
        hx, hy, hrx, hry, hcol = top_hl
        pred = ellipse(hx, hy, hrx, hry)
        for (x, y) in mask_cells(mask):
            if pred(x + 0.5, y + 0.5):
                cv.set(x, y, hcol)


# ---------------------------------------------------------------------------
# 共通パーツ: 鉢(全フレーム同位置)・土
# ---------------------------------------------------------------------------
POT_RIM_TOP = 49     # リム上端行
POT_BOTTOM = 62      # 鉢フィル最下行(リングで63まで届く=足元固定)


def draw_pot(cv):
    # リム(角丸の帯): rows 49..52
    rim = new_mask()
    hspan(rim, 49, 9, 23)
    for y in (50, 51, 52):
        hspan(rim, y, 8, 23)
    draw_part(cv, rim, POT, shade=False)
    # リム上面のライト帯
    for x in range(10, W - 10):
        cv.set(x, 50, POT_LT)
    # リム右側にも軽い影(立体感)
    for y in (50, 51, 52):
        for dx in (1, 2):
            cv.set(W - 1 - 8 - dx + 1, y, POT_SH)
    # 鉢ボディ(しっかりテーパーの台形): rows 54..62(row53が共有輪郭線)
    body = new_mask()
    spans = {}
    for y in range(54, POT_BOTTOM + 1):
        x0 = 10 + round((y - 54) * 5 / 8)
        hspan(body, y, x0, 23)
        spans[y] = x0
    draw_part(cv, body, POT, shade=False)
    # 手動シェード: 右縁2px影 / 最下行影 / 左縁1pxライト(陶器鉢の面取り)
    for y, x0 in spans.items():
        xr = W - 1 - x0
        cv.set(xr, y, POT_SH)
        cv.set(xr - 1, y, POT_SH)
        if y <= 59:
            cv.set(x0, y, POT_LT)
    for x in range(spans[POT_BOTTOM], W - spans[POT_BOTTOM]):
        cv.set(x, POT_BOTTOM, POT_SH)


def draw_soil_dome(cv):
    dome = new_mask()
    half_fill(dome, ellipse(AX + 0.5, 50.0, 12.0, 6.0))
    draw_part(cv, dome, SOIL, sh_col=None, lt_col=None,
              top_hl=(18.5, 46.0, 4.5, 1.6, SOIL_LT))


# ---------------------------------------------------------------------------
# 顔(本体ブロブの上に直接プロット。クリップで本体内に収める)
# ---------------------------------------------------------------------------

def draw_face(cv, ey, d, er, mouth_y, mouth_w, cheek=None, happy=False):
    """ey: 目の中心行 / d: 軸からの目中心距離(中心間 2d)/ er: 目半径
    mouth_y: 口の基準行 / mouth_w: 口の半幅(2 or 3) / cheek: (軸距離, 行, rx, ry)
    """
    if happy:
        # にこにこ弧目(∩形・2px厚)。左目のみ定義しミラー。
        ex = int(AX - d)  # 左目中心カラム
        arcs = []
        span = max(2, int(er) + 1)
        for dx in range(-span, span + 1):
            lift = (abs(dx) * abs(dx)) // max(1, span)  # 端ほど下がる
            yy = ey - (span - 1) // 2 + lift - 1
            arcs.append((dx, yy))
        for dx, yy in arcs:
            for t in range(2):
                cv.hpx(yy + t + 1, ex + dx, EYE, clip=GREEN_FAMILY)
    else:
        # ベタ塗りこげ茶の丸目(左目を述語で打ち、ミラー)
        eyes = new_mask()
        half_fill(eyes, circle(AX - d, ey + 0.5, er))
        for (x, y) in mask_cells(eyes):
            if cv.get(x, y) in GREEN_FAMILY:
                cv.set(x, y, EYE)
        # 白ハイライト: 各目の右上に1個だけ(目が大きければ2x2、小さければ1px)
        hs = 2 if er >= 2.5 else 1
        for ecx in (AX - d, AX + d):
            hx = int(ecx + er * 0.22)
            hy = int(ey - er * 0.55)
            for dy in range(hs):
                for dx in range(hs):
                    if cv.get(hx + dx, hy + dy) == EYE:
                        cv.set(hx + dx, hy + dy, WHITE)
    # 口: 小さな笑みの弧(端が上がる)。左半分のみ定義しミラー。
    cx_l = int(AX)  # 23
    if mouth_w >= 3:
        # 幅6の弧・2px厚
        cv.hpx(mouth_y - 1, cx_l - 2, EYE, clip=GREEN_FAMILY)
        cv.hpx(mouth_y, cx_l - 2, EYE, clip=GREEN_FAMILY)
        cv.hpx(mouth_y, cx_l - 1, EYE, clip=GREEN_FAMILY)
        cv.hpx(mouth_y, cx_l, EYE, clip=GREEN_FAMILY)
        cv.hpx(mouth_y + 1, cx_l - 1, EYE, clip=GREEN_FAMILY)
        cv.hpx(mouth_y + 1, cx_l, EYE, clip=GREEN_FAMILY)
    else:
        # 幅4の小さな弧・1px厚
        cv.hpx(mouth_y - 1, cx_l - 2, EYE, clip=GREEN_FAMILY)
        cv.hpx(mouth_y, cx_l - 1, EYE, clip=GREEN_FAMILY)
        cv.hpx(mouth_y, cx_l, EYE, clip=GREEN_FAMILY)
    # ほっぺ(薄ピンク楕円・控えめ・本体内クリップ)
    if cheek:
        cd, cy_, crx, cry = cheek
        ck = new_mask()
        half_fill(ck, ellipse(AX - cd, cy_, crx, cry))
        for (x, y) in mask_cells(ck):
            if cv.get(x, y) in GREEN_FAMILY:
                cv.set(x, y, CHEEK)


def draw_sparkle(cv, sx, sy, arm):
    """4点星(左座標で指定、ミラーで右にも)。輪郭なしの浮きキラ。"""
    for i in range(-arm, arm + 1):
        cv.hpx(sy, sx + i, GOLD)
        cv.hpx(sy + i, sx, GOLD)
    cv.hpx(sy, sx, WHITE)


# ---------------------------------------------------------------------------
# 緑パーツ(本体・手・葉)・花
# ---------------------------------------------------------------------------

def draw_body(cv, preds, top_hl=None):
    m = new_mask()
    half_fill(m, union(*preds))
    draw_part(cv, m, GREEN, sh_col=GREEN_SH, lt_col=GREEN_LT, top_hl=top_hl)
    return m


def draw_hands(cv, hx, hy, r):
    """左右ちょこんと丸い葉っぱの手(本体より前面に小円)。"""
    m = new_mask()
    half_fill(m, circle(hx, hy, r))
    draw_part(cv, m, GREEN, shade=False)
    # 手の下側に1pxの影(ぷにっと感)
    sh, _ = cel_sets(m)
    for (x, y) in sh:
        cv.set(x, y, GREEN_SH)


def draw_top_leaves(cv, lx_off, ly, r, stem_rows=None):
    """頭頂の双葉(左葉のみ定義・ミラー)+ 任意の茎。"""
    if stem_rows:
        st = new_mask()
        for y in stem_rows:
            hspan(st, y, 23, 23)
        draw_part(cv, st, GREEN_SH, shade=False)
    m = new_mask()
    half_fill(m, circle(AX - lx_off, ly, r))
    draw_part(cv, m, GREEN, shade=False)
    _, lt = cel_sets(m)
    for (x, y) in lt:
        cv.set(x, y, GREEN_LT)


def draw_bud(cv):
    """late: 頭頂のつぼみ(ピンク+クリームの先端)+ 短い茎。"""
    st = new_mask()
    for y in range(17, 24):
        hspan(st, y, 22, 23)
    draw_part(cv, st, GREEN, shade=False)
    bud = new_mask()
    half_fill(bud, circle(AX + 0.5, 13.5, 4.3))
    draw_part(cv, bud, PINK, sh_col=PINK_DK, lt_col=None,
              top_hl=(21.5, 11.0, 2.4, 1.6, CREAM))


def draw_flower(cv):
    """final: 5枚花弁のピーチピンク花+クリーム芯。頭頂に直接乗せる。"""
    import math
    petals = []
    for deg in (90, 162, 18, 234, 306):
        a = math.radians(deg)
        pcx = AX + 0.5 + 5.6 * math.cos(a)
        pcy = 11.5 - 5.6 * math.sin(a)
        petals.append(circle(pcx, pcy, 4.1))
    m = new_mask()
    half_fill(m, union(*petals))
    draw_part(cv, m, PINK, sh_col=PINK_DK, lt_col=None)
    core = new_mask()
    half_fill(core, circle(AX + 0.5, 11.5, 3.4))
    draw_part(cv, core, CREAM, shade=False)


# ---------------------------------------------------------------------------
# フレーム定義(成長順)
# ---------------------------------------------------------------------------

def frame_soil():
    cv = Canvas()
    draw_soil_dome(cv)
    draw_pot(cv)
    return cv


def frame_sprout():
    cv = Canvas()
    draw_soil_dome(cv)
    draw_pot(cv)
    draw_top_leaves(cv, 3.0, 35.0, 2.3, stem_rows=range(35, 40))
    draw_body(cv, [circle(AX + 0.5, 45.0, 7.5)],
              top_hl=(20.5, 40.0, 2.6, 1.6, GREEN_LT))
    draw_face(cv, 44, 5.0, 1.6, 47, 2)
    return cv


def frame_mid():
    cv = Canvas()
    draw_soil_dome(cv)
    draw_pot(cv)
    draw_top_leaves(cv, 3.6, 26.0, 2.7, stem_rows=range(27, 31))
    draw_body(cv, [circle(AX + 0.5, 42.5, 10.5), circle(AX + 0.5, 37.0, 9.0)],
              top_hl=(18.5, 31.5, 3.0, 1.8, GREEN_LT))
    draw_hands(cv, AX - 12.0, 41.0, 2.5)
    draw_face(cv, 36, 6.5, 2.2, 42, 2, cheek=(8.0, 40.0, 2.0, 1.2))
    return cv


def frame_late():
    cv = Canvas()
    draw_pot(cv)
    draw_bud(cv)
    draw_body(cv, [ellipse(AX + 0.5, 41.0, 16.0, 11.5),
                   ellipse(AX + 0.5, 33.0, 13.0, 10.5)],
              top_hl=(16.5, 26.5, 3.4, 2.0, GREEN_LT))
    draw_hands(cv, AX - 17.5, 38.0, 2.8)
    draw_face(cv, 32, 9.0, 2.8, 39, 3, cheek=(12.0, 36.5, 2.2, 1.3))
    return cv


def _final_base(cv):
    draw_pot(cv)
    draw_flower(cv)
    body = draw_body(cv, [ellipse(AX + 0.5, 41.5, 17.5, 11.5),
                          ellipse(AX + 0.5, 31.0, 15.0, 11.0)],
                     top_hl=(16.0, 24.5, 3.8, 2.2, GREEN_LT))
    # 本体ブロブ幅 = キャンバスの70-80%(ちびもち比率)を機械検証
    bw = max(sum(1 for x in range(W) if row[x]) and
             (max(x for x in range(W) if row[x]) - min(x for x in range(W) if row[x]) + 1)
             for row in body if any(row))
    assert 0.70 * W <= bw <= 0.80 * W, f"final body blob width {bw}px が70-80%範囲外"
    draw_hands(cv, AX - 18.0, 39.0, 2.9)
    return body


def frame_final_normal():
    cv = Canvas()
    _final_base(cv)
    draw_face(cv, 31, 10.0, 3.2, 38, 3, cheek=(13.5, 35.0, 2.4, 1.4))
    return cv


def frame_final_happy():
    cv = Canvas()
    _final_base(cv)
    draw_face(cv, 31, 10.0, 3.2, 38, 3, cheek=(13.5, 35.0, 2.4, 1.4),
              happy=True)
    draw_sparkle(cv, 8, 7, 2)
    draw_sparkle(cv, 12, 17, 1)
    return cv


FRAMES = [
    ("soil", frame_soil),
    ("sprout", frame_sprout),
    ("mid", frame_mid),
    ("late", frame_late),
    ("final_normal", frame_final_normal),
    ("final_happy", frame_final_happy),
]


# ---------------------------------------------------------------------------
# PNG 書き出し(zlib + struct 直書き / RGBA)
# ---------------------------------------------------------------------------

def write_png(path, w, h, rows):
    raw = b"".join(
        b"\x00" + b"".join(struct.pack("4B", *p) for p in row) for row in rows
    )

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(sig + chunk(b"IHDR", ihdr)
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def canvas_rows(cv):
    rows = []
    for y in range(H):
        row = []
        for x in range(W):
            c = cv.px[y][x]
            row.append((0, 0, 0, 0) if c is None else (c[0], c[1], c[2], 255))
        rows.append(row)
    return rows


# ---------------------------------------------------------------------------
# 機械検証(48x64・足元固定・シルエット左右対称)
# ---------------------------------------------------------------------------

def validate(frames):
    pot_strips = []
    for name, cv in frames:
        assert len(cv.px) == H and all(len(r) == W for r in cv.px), \
            f"{name}: キャンバスが48x64でない"
        # シルエット左右対称(アルファのみ。ハイライト等の色は非対称で良い)
        for y in range(H):
            for x in range(W):
                a = cv.px[y][x] is not None
                b = cv.px[y][W - 1 - x] is not None
                assert a == b, f"{name}: シルエット非対称 ({x},{y})"
        # 足元固定: 最下不透明行が常に H-1(=63)
        bottom = max(y for y in range(H)
                     if any(cv.px[y][x] is not None for x in range(W)))
        assert bottom == H - 1, f"{name}: 足元が浮いている(最下行 {bottom})"
        # 鉢領域(rows 56..63)が全フレーム同一
        pot_strips.append([tuple(cv.px[y]) for y in range(56, H)])
    for name_cv, strip in zip(frames, pot_strips):
        assert strip == pot_strips[0], f"{name_cv[0]}: 鉢の位置/形が他フレームと不一致"
    # 最終形シルエット(手・輪郭込み)がキャンバスに収まり左右1px以上の余白を持つか
    fn = dict(frames)["final_normal"]
    xs = [x for y in range(H) for x in range(W) if fn.px[y][x] is not None]
    assert min(xs) >= 1 and max(xs) <= W - 2, "final silhouette がキャンバス端に接触"


# ---------------------------------------------------------------------------
# コンタクトシート(4倍 NN・クリーム背景・成長順)
# ---------------------------------------------------------------------------

def make_sheet(frames):
    margin = 16
    tile_w, tile_h = W * SCALE, H * SCALE
    sw = margin + len(frames) * (tile_w + margin)
    sh = tile_h + margin * 2
    bg = (SHEET_BG[0], SHEET_BG[1], SHEET_BG[2], 255)
    rows = [[bg] * sw for _ in range(sh)]
    for i, (_name, cv) in enumerate(frames):
        ox = margin + i * (tile_w + margin)
        oy = margin
        for y in range(H):
            for x in range(W):
                c = cv.px[y][x]
                if c is None:
                    continue
                p = (c[0], c[1], c[2], 255)
                for dy in range(SCALE):
                    rr = rows[oy + y * SCALE + dy]
                    for dx in range(SCALE):
                        rr[ox + x * SCALE + dx] = p
    write_png(SHEET_PATH, sw, sh, rows)


def main():
    frames = [(name, fn()) for name, fn in FRAMES]
    validate(frames)
    os.makedirs(PNG_DIR, exist_ok=True)
    for name, cv in frames:
        write_png(os.path.join(PNG_DIR, name + ".png"), W, H, canvas_rows(cv))
    make_sheet(frames)
    print("OK: 6 frames + contact_sheet.png (48x64, 検証済み)")


if __name__ == "__main__":
    main()
