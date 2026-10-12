#!/usr/bin/env python3
"""Lien アプリアイコン v4 — 「タネの子」が鉢のふちからのぞく構図(gen_v4.py / gen_layers.py の部品を再利用)。

1024×1024。iOS が角丸マスクを掛けるので四隅は塗りつぶしのまま出力する。
背景候補を3色出し、contact で比較できるようにする。

使い方: python3 gen_icon_v4.py
"""

import os
import subprocess

import gen_v4 as g
import gen_layers as gl

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "icon")
S = 1024

BGS = {
    "apricot": ("#FFE7CF", "#FFC79A"),
    "mint":    ("#E6F7DC", "#B9E4A2"),
    "sky":     ("#E3F3FF", "#AFD9FA"),
}


def icon_svg(bg):
    c0, c1 = BGS[bg]
    k = 4.75
    tx = S / 2 - g.CX * k
    ty = 196 - (g.BODY_TOP_Y - 38) * k   # 双葉の先端がおよそ y=196 に来る位置
    inner = (g.soil_in_pot() + gl.leaf_open() + gl.MIRROR_OPEN + gl.leaf_open() + "</g>"
             + g.body() + g.face("normal") + g.pot() + g.hands_on_rim())
    sparkles = "".join(sp.replace('stroke-width="2.6"', 'stroke-width="9"') for sp in (g.sparkle(150, 214, 44), g.sparkle(872, 318, 34), g.sparkle(880, 168, 20, g.SPARK_LIGHT)))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">'
            f'{g.defs()}'
            f'<defs><radialGradient id="gBg" cx="0.5" cy="0.32" r="0.85">'
            f'<stop offset="0" stop-color="{c0}"/><stop offset="1" stop-color="{c1}"/></radialGradient></defs>'
            f'<rect width="{S}" height="{S}" fill="url(#gBg)"/>'
            f'{sparkles}'
            f'<g transform="translate({g.f(tx)} {g.f(ty)}) scale({k})">{inner}</g>'
            f'</svg>\n')


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    names = []
    for bg in BGS:
        sp = os.path.join(OUT_DIR, f"icon_{bg}.svg")
        with open(sp, "w") as fh:
            fh.write(icon_svg(bg))
        pp = os.path.join(OUT_DIR, f"icon_{bg}_1024.png")
        subprocess.run([g.CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        f"--window-size={S},{S}", "--force-device-scale-factor=1",
                        f"--screenshot={pp}", "file://" + sp],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        names.append(pp)
    # 比較用: 角丸マスク+ホーム画面サイズ(60pt@3x=180px)と大サイズを並べる
    from PIL import Image, ImageDraw
    big, small = 300, 120
    sheet = Image.new("RGBA", (len(names) * (big + 40) + 40, big + small + 120), (250, 250, 250, 255))
    for i, p in enumerate(names):
        im = Image.open(p).convert("RGBA")
        for size, y in ((big, 30), (small, big + 70)):
            r = im.resize((size, size), Image.LANCZOS)
            m = Image.new("L", (size, size), 0)
            ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.2237), fill=255)
            x = 40 + i * (big + 40) + (big - size) // 2
            sheet.paste(r, (x, y), m)
    sheet.save(os.path.join(HERE, "icon_compare.png"))


if __name__ == "__main__":
    main()
