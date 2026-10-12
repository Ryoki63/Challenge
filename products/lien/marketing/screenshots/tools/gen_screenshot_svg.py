#!/usr/bin/env python3
"""Lien App Store スクリーンショット下絵ジェネレータ(T26 / issue #26)。

【無効 — 2026-10-13 から、11/9〜11/13 のスクショ作り直しまで(issue #66)】
実行すると、下の理由を出して終了コード 2 で止まる(読み込めない旧モジュールの ImportError で落ちるのではなく、
無効にしてあることを明示する)。

  - 装飾の植物は、廃止した旧ドット絵 assets/plant/tools/gen_sprites.py を読み込んでいた。D1 で画風を v4「タネの子」
    (SVG レイヤー34点)に替え、gen_sprites.py は削除した(issue #56)。もう読み込む先が無い
  - コピー(FRAMES)と構成は旧範囲(M ウィジェット+相手の写真)が前提で、D3 で v1.0 の事実と合わなくなった
    (Frame 2 と、Frame 3 のサブコピー。審査 2.3 の正確さ)。UI とアートの凍結後に作り直す(docs/TASKPLAN.md §9.4・../plan.md)
  - 作り直すときは、植物を assets/plant/svg/ のレイヤーと layer_stacks.json(重ね順)から組む形に書き直し、
    FRAMES とレイアウトも見直す(重ね順・左右反転の規則は assets/plant/mapping.md)
  - いまの ../6.7in/ ../6.1in/ の SVG は、旧画風のまま残してある下絵(G4 の参考)。このツールでは再生成されない

以下は、無効にする前の説明(作り直しの出発点として残す)。

6.7インチ(1290x2796)/ 6.1インチ(1179x2556)各5枚の SVG テンプレートを
決定論的に生成する。テキストは <text> 要素のままなので、エディタ/Figma/
イラレでそのまま編集できる。実機スクリーンショットは「device-placeholder」
の枠に差し込む(構成・撮影指示は ../plan.md を参照)。

装飾の植物ドット絵は gen_sprites.py のピクセル定義をそのまま読み込んで
<rect> 群に変換していた(スプライトとトーンが常に一致する)。

使い方(無効中は動かない):
  python3 gen_screenshot_svg.py
出力:
  ../6.7in/01_promise.svg ... 05_ticket.svg   (1290x2796)
  ../6.1in/01_promise.svg ... 05_ticket.svg   (1179x2556)
"""

import os
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_BASE = os.path.normpath(os.path.join(HERE, ".."))

# 無効にしてある理由(main() が出す)。作り直しで植物の描き方を書き直したら、この定数ごと外す
DISABLED_REASON = (
    "gen_screenshot_svg.py は無効です(2026-10-13〜。11/9〜11/13 のスクショ作り直しまで)。\n"
    "  - 植物は、廃止した旧ドット絵 assets/plant/tools/gen_sprites.py を読み込む作りで、そのファイルはもうありません"
    "(画風は D1 で v4「タネの子」の SVG レイヤーに替わりました — issue #56)\n"
    "  - コピー(FRAMES)と構成は旧範囲(M ウィジェット+相手の写真)が前提で、D3 で v1.0 の事実と合いません"
    "(Frame 2・Frame 3 のサブコピー)\n"
    "  - UI とアートの凍結後に作り直します(docs/TASKPLAN.md §9.4、marketing/screenshots/plan.md)。"
    "そのとき、植物を assets/plant/svg/ と layer_stacks.json から組む形に書き直してください\n"
    "  - いまの 6.7in/ 6.1in/ の SVG は旧画風のまま残してある下絵で、このツールでは再生成されません"
)

SIZES = {
    "6.7in": (1290, 2796),   # iPhone 6.7" (Pro Max 系) 縦
    "6.1in": (1179, 2556),   # iPhone 6.1" (無印/Pro 系) 縦
}

# ブランド色(旧 gen_sprites.PALETTE と同系。v4 の配色に合わせて見直す)
BG = "#F4EFE6"        # あたたかいオフホワイト
INK = "#3A2C28"       # 見出し(輪郭ダークブラウン)
SUB_INK = "#6B4A36"   # サブコピー(土の暗色)
FRAME_STROKE = "#C2A98F"
FONT = "Hiragino Maru Gothic ProN, Hiragino Sans, sans-serif"

# 5枚構成(コピーの正本。plan.md と対応)
FRAMES = [
    {
        "slug": "01_promise",
        "badge": "約束はひとつ",
        "accent": "#F69AC0",
        "headline": ["約束は、", "ひとつだけ。"],
        "sub": "ふたりで決めて、毎日つづける習慣アプリ",
        "sprite": "stage5_happy",
        "shot": "ホーム画面(植物+ふたりの今日+ストリーク)",
    },
    {
        "slug": "02_widget",
        "badge": "ウィジェット",
        "accent": "#59C165",
        "headline": ["相手の今日が、", "ホーム画面でわかる"],
        "sub": "チェックインすると、相手のウィジェットがすぐ更新",
        "sprite": "stage3_happy",
        "shot": "iOSホーム画面(S/Mウィジェット設置状態)",
    },
    {
        "slug": "03_checkin",
        "badge": "1タップ",
        "accent": "#FFD966",
        "headline": ["「やった!」は", "1タップ"],
        "sub": "写真をそえると、相手のウィジェットに届く",
        "sprite": "stage2_happy",
        "shot": "チェックイン直後(完了アニメ+写真添付ボタン)",
    },
    {
        "slug": "04_poke",
        "badge": "つつく",
        "accent": "#7EC8F5",
        "headline": ["通知は、", "相手の名前で届く"],
        "sub": "「そろそろやろ?」のひと言で、今日もつづく",
        "sprite": "stage4_normal",
        "shot": "ロック画面の通知(つつき+チェックイン通知)",
    },
    {
        "slug": "05_ticket",
        "badge": "お休みチケット",
        "accent": "#E89A60",
        "headline": ["できない日があっても、", "だいじょうぶ"],
        "sub": "お休みチケットが、ふたりのつづきをまもる",
        "sprite": "stage5_normal",
        "shot": "カレンダー(お休みチケット消費日+ストリーク継続)",
    },
]


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def sprite_svg(name, x, y, dot):
    """【無効】装飾の植物。以前は gen_sprites のドット絵(16x24px)を <rect> 群に変換していた(dot = 1ドットのpx)。
    作り直しで、assets/plant/svg/ のレイヤーを layer_stacks.json の重ね順で組む形に書き直す。それまでは使えない"""
    raise RuntimeError(DISABLED_REASON)


def build_svg(size_label, w, h, frame, index):
    pad = round(w * 0.07)
    dot = max(8, round(h * 0.0056))          # スプライト1ドットのpx
    sp_w, sp_h = 16 * dot, 24 * dot
    sp_x, sp_y = w - pad - sp_w, round(h * 0.045)

    badge_y = round(h * 0.040)
    badge_h = round(h * 0.0205)
    badge_fs = round(badge_h * 0.62)
    badge_w = badge_fs * (len(frame["badge"]) + 2)

    head_fs = round(w * 0.062)
    head_y0 = badge_y + badge_h + round(head_fs * 1.35)
    line_h = round(head_fs * 1.38)
    sub_fs = round(w * 0.031)
    sub_y = head_y0 + line_h * (len(frame["headline"]) - 1) + round(sub_fs * 2.1)

    dev_w = round(w * 0.84)
    dev_x = (w - dev_w) // 2
    dev_y = round(h * 0.225)
    dev_h = h - dev_y + 60          # 下端は画面外へ抜く(下ブリード)
    dev_rx = round(w * 0.085)

    label_y = dev_y + round(h * 0.30)
    label_fs = round(w * 0.026)

    head_texts = "\n".join(
        '  <text x="%d" y="%d" font-family="%s" font-size="%d" '
        'font-weight="bold" fill="%s">%s</text>'
        % (pad, head_y0 + i * line_h, FONT, head_fs, INK, esc(line))
        for i, line in enumerate(frame["headline"]))

    placeholder_lines = [
        "ここに実機スクリーンショットを差し込む",
        frame["shot"],
        "書き出し: %s / plan.md の Frame %d を参照" % (
            {"6.7in": "1290x2796", "6.1in": "1179x2556"}[size_label], index),
    ]
    label_texts = "\n".join(
        '    <text x="%d" y="%d" text-anchor="middle" font-family="%s" '
        'font-size="%d" fill="%s">%s</text>'
        % (w // 2, label_y + i * round(label_fs * 1.8), FONT,
           label_fs, FRAME_STROKE, esc(line))
        for i, line in enumerate(placeholder_lines))

    return """<?xml version="1.0" encoding="UTF-8"?>
<!--
  Lien App Store スクリーンショット下絵 Frame %d (%s %dx%d)
  - テキストはすべて <text> 要素。エディタでそのまま編集可
  - id="device-placeholder" の枠を実機スクショ(PNG)に差し替えて書き出す
  - 構成・撮影指示・デモデータは ../plan.md を参照
  - 生成: tools/gen_screenshot_svg.py(手で編集してもよいが、再生成で上書きされる点に注意)
-->
<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">
  <rect id="bg" x="0" y="0" width="%d" height="%d" fill="%s"/>
  <rect id="accent-bar" x="0" y="0" width="%d" height="%d" fill="%s"/>
  <g id="badge">
    <rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="%s"/>
    <text x="%d" y="%d" text-anchor="middle" font-family="%s" font-size="%d" font-weight="bold" fill="%s">%s</text>
  </g>
%s
  <text id="subcopy" x="%d" y="%d" font-family="%s" font-size="%d" fill="%s">%s</text>
%s
  <g id="device-placeholder">
    <rect x="%d" y="%d" width="%d" height="%d" rx="%d"
          fill="#FFFFFF" stroke="%s" stroke-width="6" stroke-dasharray="24 18"/>
%s
  </g>
</svg>
""" % (
        index, size_label, w, h,
        w, h, w, h,
        w, h, BG,
        w, round(h * 0.008), frame["accent"],
        pad, badge_y, badge_w, badge_h, badge_h // 2, frame["accent"],
        pad + badge_w // 2, badge_y + round(badge_h * 0.70), FONT, badge_fs,
        INK, esc(frame["badge"]),
        head_texts,
        pad, sub_y, FONT, sub_fs, SUB_INK, esc(frame["sub"]),
        sprite_svg(frame["sprite"], sp_x, sp_y, dot),
        dev_x, dev_y, dev_w, dev_h, dev_rx, FRAME_STROKE,
        label_texts,
    )


def generate():
    """【無効】SVG を書き出す本体。植物の描き方(sprite_svg)を書き直すまで、main() は呼ばない"""
    written = []
    for size_label, (w, h) in SIZES.items():
        out_dir = os.path.join(OUT_BASE, size_label)
        os.makedirs(out_dir, exist_ok=True)
        for i, frame in enumerate(FRAMES, start=1):
            path = os.path.join(out_dir, frame["slug"] + ".svg")
            text = build_svg(size_label, w, h, frame, i)  # 先に組み立てる(失敗したとき、既存のファイルを空にしない)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            written.append((path, w, h))

    # --- 自己検証: XMLとして妥当 / ルートがsvg / 寸法属性が正しい ---
    for path, w, h in written:
        root = ET.parse(path).getroot()
        assert root.tag.endswith("svg"), path
        assert root.get("width") == str(w) and root.get("height") == str(h), \
            "%s: %sx%s != %dx%d" % (path, root.get("width"), root.get("height"), w, h)
        ids = {el.get("id") for el in root.iter() if el.get("id")}
        assert "device-placeholder" in ids and "subcopy" in ids, path
    assert len(written) == len(SIZES) * len(FRAMES) == 10
    print("OK: %d SVGs (XML valid) -> %s/{6.7in,6.1in}/" % (len(written), OUT_BASE))
    return 0


def main():
    """無効中は、理由を標準エラーへ出して終了コード 2。ファイルは1つも書かない。
    作り直しで sprite_svg を書き直したら、この関数を `return generate()` にして DISABLED_REASON を外す"""
    print(DISABLED_REASON, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
