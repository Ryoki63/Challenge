#!/usr/bin/env python3
"""公開前ティザーページと法務ページ(GitHub Pages)を組み立てる(MK3 / issue #76)。

正本は Markdown だけ。HTML はこのスクリプトが生成し、手で編集しない。

  1. `marketing/privacy-policy.md` / `marketing/terms.md` → `marketing/legal/{privacy,terms}.html`
     (CHECKLIST-G4 §4「md が原稿の正。改定時は md と html を必ず同時に更新」を、
      手作業ではなく生成で担保する。片方だけ直して食い違う事故を無くす)
  2. `products/lien/web/site/` に配信物を組み立てる(Pages に載せるのはこのディレクトリだけ):
       index.html … 公開前ティザー(1行説明・スクリーンショット3枚・X・近日公開・法務リンク)
       lien/legal/{privacy,terms}.html
       lien/i/index.html … 招待ページ(T11 の既存ページをそのまま複製)
       assets/ … CSS と実画面のスクリーンショット3枚(PNG)
  3. `products/lien/web/site.json` の値(baseUrl / xUrl / appStoreUrl / status)を読む。
     未確定の値は null のままにしておくと、配信物には出ない(`--check-publishable` が止める)。

使い方(products/lien/web):
  python3 tools/build_site.py                    # 生成(コミット対象を書き換える)
  python3 tools/build_site.py --check            # 生成物がコミット済みと一致するか(CI)
  python3 tools/build_site.py --check-publishable # 公開してよい状態か(配備の直前に必ず通す)

**公開してはいけない状態を機械で止める**: `--check-publishable` は
  - `【要記入: G4: …】` が法務ページに残っていたら NG(G4 #42 で人が埋める)
  - `site.json` の baseUrl / xUrl が null なら NG
のいずれかで終了コード 1 を返す。ティザーに「準備中」や偽のリンクを出さないため。

Python 3.9+ の標準ライブラリだけで動く(Markdown のパーサも自前。依存を増やさない)。
"""

import argparse
import html
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.dirname(HERE)
PRODUCT_DIR = os.path.dirname(WEB_DIR)
LIEN_DIR = os.path.dirname(PRODUCT_DIR)
MARKETING_DIR = os.path.join(PRODUCT_DIR, "marketing")
LEGAL_OUT_DIR = os.path.join(MARKETING_DIR, "legal")
SITE_OUT_DIR = os.path.join(WEB_DIR, "site")
STORE_METADATA_DIR = os.path.join(MARKETING_DIR, "store_metadata", "ja")
SCREENSHOT_DIR = os.path.join(MARKETING_DIR, "screenshots", "6.7in")
INVITE_SRC = os.path.join(WEB_DIR, "invite", "index.html")
CONFIG_PATH = os.path.join(WEB_DIR, "site.json")

# 法務ページの正本(md)と生成先(html)
LEGAL_PAGES = (
    # (md, html, <title>, パンくず用の短い名前)
    ("privacy-policy.md", "privacy.html", "Lien プライバシーポリシー", "プライバシーポリシー"),
    ("terms.md", "terms.html", "Lien 利用規約", "利用規約"),
)

ACCENT = "#3D6B52"

# 法務ページの体裁(既存の見た目をそのまま保つ。明暗どちらでも読める)
LEGAL_CSS = """\
  :root { color-scheme: light dark; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic", Meiryo, sans-serif;
    line-height: 1.8;
    margin: 0;
    padding: 0;
    background: #fdfdfb;
    color: #2b2b2b;
  }
  main {
    max-width: 720px;
    margin: 0 auto;
    padding: 2rem 1.25rem 4rem;
  }
  h1 {
    font-size: 1.5rem;
    border-bottom: 2px solid #7aa874;
    padding-bottom: .5rem;
  }
  h2 {
    font-size: 1.15rem;
    margin-top: 2.2rem;
    border-left: 4px solid #7aa874;
    padding-left: .6rem;
  }
  table {
    border-collapse: collapse;
    width: 100%;
    font-size: .92rem;
  }
  th, td {
    border: 1px solid #ccc;
    padding: .5rem .6rem;
    text-align: left;
    vertical-align: top;
  }
  th { background: #eef3ec; }
  ul, ol { padding-left: 1.4rem; }
  li { margin: .3rem 0; }
  .meta { color: #555; font-size: .92rem; }
  .placeholder { background: #fff3c4; padding: 0 .2em; border-radius: 3px; }
  .backlink { font-size: .9rem; margin: 0 0 1rem; }
  .backlink a { color: #3f6b4f; }
  footer {
    text-align: center;
    font-size: .85rem;
    color: #777;
    padding: 1rem 0 2rem;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #1c1c1e; color: #e6e6e6; }
    th { background: #2e352c; }
    th, td { border-color: #555; }
    .meta { color: #aaa; }
    .placeholder { background: #5c5320; }
    .backlink a { color: #9ecfae; }
  }"""


# --------------------------------------------------------------------------
# Markdown → HTML(この2文書で使う記法だけを厳密に扱う)
# --------------------------------------------------------------------------

INLINE_CODE_RE = re.compile(r"`([^`]+)`")
BOLD_RE = re.compile(r"\*\*(.+?)\*\*")
LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
# G4 で人が埋めるプレースホルダ。公開前チェックがこの形を探す
PLACEHOLDER_RE = re.compile(r"【要記入: [^】]*】")
LIST_ITEM_RE = re.compile(r"^( *)(- |\d+\. )(.*)$")


def render_inline(text):
    """行内記法。HTML を先にエスケープしてから、こちらの記法だけをタグにする。"""
    out = html.escape(text, quote=False)
    out = INLINE_CODE_RE.sub(r"<code>\1</code>", out)
    out = BOLD_RE.sub(r"<strong>\1</strong>", out)
    out = LINK_RE.sub(r'<a href="\2">\1</a>', out)
    out = PLACEHOLDER_RE.sub(lambda m: f'<span class="placeholder">{m.group(0)}</span>', out)
    return out


def is_table_row(line):
    return line.lstrip().startswith("|")


def split_table_row(line):
    row = line.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|"):
        row = row[:-1]
    return [cell.strip() for cell in row.split("|")]


def render_table(rows):
    """1行目を見出し、2行目(| --- |)を捨て、残りを本体にする。"""
    if len(rows) < 2:
        raise ValueError(f"表の区切り行がありません: {rows[0] if rows else '(空)'}")
    header = split_table_row(rows[0])
    body = rows[2:]
    lines = ["<table>", "  <thead>", "    <tr>" + "".join(f"<th>{render_inline(c)}</th>" for c in header) + "</tr>", "  </thead>", "  <tbody>"]
    for row in body:
        cells = split_table_row(row)
        if len(cells) != len(header):
            raise ValueError(f"表の列数が合いません({len(cells)} != {len(header)}): {row}")
        lines.append("    <tr>" + "".join(f"<td>{render_inline(c)}</td>" for c in cells) + "</tr>")
    lines += ["  </tbody>", "</table>"]
    return "\n".join(lines)


def render_list(items):
    """(深さ, 番号つきか, 本文) の列を、入れ子を保ったまま ul/ol にする。

    利用規約の第4条のように、番号つきの項目の下に箇条書きがぶら下がる。
    深さは本文のインデントそのもの(2スペース=1段)なので、そのまま入れ子にする。
    """

    def render(pos, depth, open_indent, item_indent):
        tag = "ol" if items[pos][1] else "ul"
        lines = [f"{open_indent}<{tag}>"]
        while pos < len(items) and items[pos][0] >= depth:
            indent, ordered, content = items[pos]
            if indent > depth:
                raise ValueError(f"入れ子の深さが飛んでいます: {content!r}")
            if ordered != (tag == "ol"):
                raise ValueError(f"同じ深さで箇条書きと番号つきが混ざっています: {content!r}")
            lines.append(f"{item_indent}<li>{render_inline(content)}")
            following = pos + 1
            if following < len(items) and items[following][0] > depth:
                sub, pos = render(
                    following, items[following][0], item_indent + "  ", item_indent + "    "
                )
                lines[-1] += "\n" + sub
                lines.append(f"{item_indent}</li>")
                continue
            lines[-1] += "</li>"
            pos += 1
        lines.append(f"{open_indent}</{tag}>")
        return "\n".join(lines), pos

    html, _ = render(0, items[0][0], "", "  ")
    return html


def parse_list_items(lines, start):
    """start 行から始まるリストを読み、(items, 次の行) を返す。空行は次の項目まで読み飛ばす。"""
    items = []
    i = start
    while i < len(lines):
        match = LIST_ITEM_RE.match(lines[i])
        if match:
            items.append((len(match.group(1)), match.group(2)[0].isdigit(), match.group(3).strip()))
            i += 1
            continue
        if not lines[i].strip():
            j = i
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines) and LIST_ITEM_RE.match(lines[j]):
                i = j
                continue
        break
    return items, i


def markdown_to_html(text):
    """対応する記法だけを HTML にする。知らない記法は例外にする(黙って崩さない)。"""
    lines = text.splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith("# "):
            blocks.append(("h1", f"<h1>{render_inline(line[2:].strip())}</h1>"))
            i += 1
            continue
        if line.startswith("## "):
            blocks.append(("h2", f"<h2>{render_inline(line[3:].strip())}</h2>"))
            i += 1
            continue
        if line.startswith("- ") or line.startswith("1. "):
            items, i = parse_list_items(lines, i)
            blocks.append(("list", render_list(items)))
            continue
        if is_table_row(line):
            rows = []
            while i < len(lines) and is_table_row(lines[i]):
                rows.append(lines[i])
                i += 1
            blocks.append(("table", render_table(rows)))
            continue
        if line.lstrip().startswith(("#", ">", "```", "    ")):
            raise ValueError(f"未対応の記法です(このスクリプトの対応表を広げてください): {line!r}")
        # 段落(連続する行は1つの段落にする)
        paragraph = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not (
            lines[i].startswith("#") or lines[i].startswith("- ") or is_table_row(lines[i])
        ):
            paragraph.append(lines[i].strip())
            i += 1
        blocks.append(("p", "<p>" + render_inline(" ".join(paragraph)) + "</p>"))

    # 見出しの前と、箇条書きの直後の段落の前に空行を入れる(既存 HTML と同じ体裁)
    parts = []
    previous = None
    for kind, rendered in blocks:
        if kind == "h2" or (kind == "p" and previous == "list"):
            parts.append("\n")
        parts.append(rendered + "\n")
        previous = kind
    return "".join(parts)


def convert_meta_list(body_html):
    """冒頭の「- 制定日: … / - 運営者: …」を <p class="meta">…<br>…</p> に組み替える。"""
    match = re.match(r'(<h1>.*?</h1>\n)<ul>\n  <li>(.*?)</li>\n  <li>(.*?)</li>\n</ul>\n', body_html, re.S)
    if not match:
        raise ValueError("冒頭のメタ情報(制定日・運営者)の箇条書きが見つかりません")
    heading, first, second = match.group(1), match.group(2), match.group(3)
    meta = f'<p class="meta">\n{first}<br>\n{second}\n</p>\n'
    return heading + meta + body_html[match.end():].lstrip("\n")


def render_legal_page(title, breadcrumb, body_html, base_url):
    back = f'<p class="backlink"><a href="{base_url}/">Lien</a> ／ {breadcrumb}</p>\n' if base_url else ""
    return (
        "<!DOCTYPE html>\n"
        '<html lang="ja">\n'
        "<head>\n"
        '<meta charset="UTF-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{title}</title>\n"
        "<style>\n"
        f"{LEGAL_CSS}\n"
        "</style>\n"
        "</head>\n"
        "<body>\n"
        "<main>\n"
        f"{back}"
        f"{body_html}"
        "</main>\n"
        "<footer>Lien</footer>\n"
        "</body>\n"
        "</html>\n"
    )


def build_legal_pages(base_url=""):
    """[(出力パス, HTML)] を返す。md を読むだけで、ファイルは書かない。"""
    results = []
    for md_name, html_name, title, breadcrumb in LEGAL_PAGES:
        md_path = os.path.join(MARKETING_DIR, md_name)
        with open(md_path, encoding="utf-8") as handle:
            body = convert_meta_list(markdown_to_html(handle.read()))
        results.append(
            (os.path.join(LEGAL_OUT_DIR, html_name), render_legal_page(title, breadcrumb, body, base_url))
        )
    return results


# --------------------------------------------------------------------------
# スクリーンショット(実画面を描画した MK7 の PNG)
# --------------------------------------------------------------------------


SCREENSHOTS = (
    ("shot-1-home.png", "01_home_both.png", "ホームの実画面。ふたり達成とふたりの記録。デモデータ"),
    ("shot-2-waiting.png", "02_home_waiting.png", "ホームの実画面。相手だけチェックインした状態。デモデータ"),
    ("shot-3-history.png", "04_history.png", "カレンダー履歴の実画面。ふたりの達成状況。デモデータ"),
)


# --------------------------------------------------------------------------
# ティザーページ
# --------------------------------------------------------------------------

SITE_CSS = """\
:root {
  --bg: #FBF7EC;
  --bg-2: #E4F1DE;
  --ink: #2B3A32;
  --accent: #3D6B52;
  --muted: #6F7B72;
  --line: #E4E1D8;
  --paper: #FFFFFF;
  --radius: 20px;
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Noto Sans JP", sans-serif;
  color: var(--ink);
  background: linear-gradient(180deg, var(--bg) 0%, var(--bg-2) 100%);
  background-attachment: fixed;
  line-height: 1.8;
}
.wrap { max-width: 880px; margin: 0 auto; padding: 0 20px; }
header.hero { text-align: center; padding: 56px 0 8px; }
.icon {
  width: 96px; height: 96px; border-radius: 22px;
  box-shadow: 0 6px 24px rgba(43, 58, 50, .12);
  display: block; margin: 0 auto 20px;
}
h1 { font-size: 2.1rem; margin: 0 0 6px; letter-spacing: .04em; }
h1 .kana { font-size: .8rem; font-weight: 500; letter-spacing: .12em; color: var(--muted); margin-left: .5em; }
.one-liner { font-size: 1.15rem; font-weight: 600; margin: 0 auto 18px; max-width: 30em; }
.badge {
  display: inline-block; padding: 7px 18px; border-radius: 999px;
  background: var(--accent); color: #fff; font-size: .9rem; font-weight: 700;
  letter-spacing: .06em;
}
.lead { color: var(--muted); font-size: .95rem; max-width: 34em; margin: 18px auto 0; }
section { padding: 40px 0 0; }
h2 { font-size: 1.15rem; margin: 0 0 16px; text-align: center; }
.shots {
  display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px;
  list-style: none; padding: 0; margin: 0;
}
.shots img { width: 100%; height: auto; display: block; border-radius: 16px; box-shadow: 0 4px 18px rgba(43, 58, 50, .10); }
.points { list-style: none; padding: 0; margin: 0; display: grid; gap: 12px; }
.points li {
  background: var(--paper); border: 1px solid var(--line); border-radius: var(--radius);
  padding: 16px 18px; font-size: .98rem;
}
.points strong { display: block; margin-bottom: 2px; }
.points span { color: var(--muted); font-size: .9rem; }
.cta { text-align: center; padding: 44px 0 8px; }
.cta p { color: var(--muted); font-size: .9rem; margin: 14px 0 0; }
.btn {
  display: inline-block; padding: 14px 30px; border-radius: 999px;
  background: var(--accent); color: #fff; text-decoration: none; font-weight: 700;
  font-size: 1rem;
}
.btn.secondary { background: var(--paper); color: var(--accent); border: 1.5px solid var(--accent); }
.support { text-align: center; }
.support p { font-size: .95rem; margin: 0 auto 6px; max-width: 32em; }
.support-contact { font-size: .9rem; }
.support-contact a { color: var(--accent); }
footer {
  margin-top: 56px; padding: 26px 0 44px; border-top: 1px solid rgba(43, 58, 50, .12);
  text-align: center; font-size: .85rem; color: var(--muted);
}
footer nav { display: flex; gap: 18px; justify-content: center; flex-wrap: wrap; margin-bottom: 10px; }
footer a { color: var(--accent); }
@media (max-width: 640px) {
  .shots { grid-template-columns: 1fr; gap: 20px; }
  .shots img { max-width: 320px; margin: 0 auto; }
  h1 { font-size: 1.7rem; }
}
"""


def read_store_copy():
    """ストアのサブタイトルと、REQUIREMENTS §3.3・3.4・3.10 に基づく紹介文を返す。"""
    path = os.path.join(STORE_METADATA_DIR, "subtitle.txt")
    with open(path, encoding="utf-8") as handle:
        subtitle = handle.read().strip()
    return {
        "subtitle": subtitle,
        "promotional_text": "それぞれが決めた約束を、1日1タップでチェックイン。ホーム画面やウィジェットで、ふたりの今日がわかります。",
    }


def render_index(config, copy):
    """ティザー本体。外部スクリプト・外部フォント・入力フォームを一切置かない。"""
    base = config["baseUrl"]
    status_label = config.get("statusLabel") or "近日公開"
    screenshots = "".join(
        f'    <li><img src="assets/{name}" alt="{html.escape(alt)}" width="1290" height="2796" loading="lazy"></li>\n'
        for name, source, alt in SCREENSHOTS
    )

    # X へのリンクは @ハンドルが確定してから出す(site.json の xUrl)。未確定のあいだは何も出さない
    x_url = config.get("xUrl")
    if x_url:
        x_link = f'    <a class="btn secondary" href="{html.escape(x_url)}" rel="noopener">X で開発の様子を見る</a>\n'
    else:
        x_link = "    <!-- xUrl 未設定: site.json に X の URL を入れると、ここにリンクが出る -->\n"

    contact = config.get("contactEmail")
    support = ""
    if contact:
        support = (
            '  <p class="support-contact">お問い合わせ: '
            f'<a href="mailto:{html.escape(contact)}">{html.escape(contact)}</a></p>\n'
        )

    app_store_url = config.get("appStoreUrl")
    if app_store_url:
        store_block = (
            f'    <a class="btn" href="{html.escape(app_store_url)}" rel="noopener">App Store で見る</a>\n'
            "    <p>iPhone 向け・無料でご利用いただけます。</p>\n"
        )
        badge = "配信中"
    else:
        store_block = (
            f'    <span class="badge">{html.escape(status_label)}</span>\n'
            "    <p>公開したら、このページでお知らせします。</p>\n"
        )
        badge = status_label

    return f"""<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lien(リアン) — {html.escape(copy['subtitle'])}</title>
<meta name="description" content="{html.escape(copy['promotional_text'])}">
<meta property="og:title" content="Lien(リアン) — {html.escape(copy['subtitle'])}">
<meta property="og:description" content="{html.escape(copy['promotional_text'])}">
<meta property="og:type" content="website">
<meta property="og:url" content="{html.escape(base)}/">
<meta property="og:image" content="{html.escape(base)}/assets/icon-1024.png">
<meta name="twitter:card" content="summary">
<link rel="icon" href="assets/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="assets/site.css">
</head>
<body>
<div class="wrap">

<header class="hero">
  <img class="icon" src="assets/icon.svg" alt="Lien のアイコン" width="96" height="96">
  <h1>Lien <span class="kana">リアン</span></h1>
  <p class="one-liner">{html.escape(copy['subtitle'])}</p>
  <span class="badge">{html.escape(badge)}</span>
  <p class="lead">{html.escape(copy['promotional_text'])}</p>
</header>

<section>
  <h2>どんなアプリ?</h2>
  <ul class="points">
    <li><strong>約束は、ひとりひとつだけ</strong><span>それぞれが、毎日つづけたい約束を1つ決めます。タイムラインも、いいね数も、ランキングもありません。</span></li>
    <li><strong>チェックインは、1日1タップ</strong><span>やった日は1タップでチェックイン。写真をそえてもOKです。</span></li>
    <li><strong>相手の今日が、ウィジェットでわかる</strong><span>ホーム画面に、自分と相手の今日の○×、ストリーク、植物が出ます。</span></li>
    <li><strong>できない日には、お休みチケット</strong><span>毎月2枚のペア共有チケット。残りがある日は自動で使い、ふたりの記録をまもります。残りがない日は今日から再スタート。最高記録は残ります。</span></li>
    <li><strong>広告も、トラッキングもありません</strong><span>ふたりの毎日に、静かに寄りそうアプリです。</span></li>
  </ul>
</section>

<section>
  <h2>画面</h2>
  <p class="lead">開発中の実画面を使った紹介画像です。名前・約束・日数はデモデータです。</p>
  <ul class="shots">
{screenshots}  </ul>
</section>

<div class="cta">
{store_block}{x_link}</div>

<section class="support">
  <h2>サポート</h2>
  <p>ご意見・ご要望は、アプリ内の「お問い合わせ」からお送りください。</p>
{support}</section>

<footer>
  <nav>
    <a href="lien/legal/privacy.html">プライバシーポリシー</a>
    <a href="lien/legal/terms.html">利用規約</a>
  </nav>
  <p>Lien(リアン)</p>
</footer>

</div>
</body>
</html>
"""


def build_icon_png():
    """SNS のカードに使う PNG(アイコン)。無ければ None(og:image を出さない)。"""
    src = os.path.join(PRODUCT_DIR, "assets", "icon", "icon_1024.png")
    if not os.path.exists(src):
        return None
    with open(src, "rb") as handle:
        return handle.read()


def render_icon_svg():
    """v4 のアイコン(空色)をそのまま使う。読み込み失敗時は単色の角丸にする。"""
    path = os.path.join(PRODUCT_DIR, "assets", "icon", "icon_v4_sky.svg")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
        f'<rect width="1024" height="1024" rx="220" fill="{ACCENT}"/></svg>\n'
    )


# --------------------------------------------------------------------------
# 組み立て・検査
# --------------------------------------------------------------------------


def load_config(path=CONFIG_PATH):
    with open(path, encoding="utf-8") as handle:
        config = json.load(handle)
    for key in ("baseUrl", "xUrl", "appStoreUrl", "contactEmail", "statusLabel"):
        if key not in config:
            raise ValueError(f"site.json に {key} がありません")
    return config


def build_all(config):
    """{出力パス: 中身} を返す。書き込みはしない(検査と生成で同じ関数を使う)。"""
    base = config.get("baseUrl") or ""
    outputs = {}

    # 法務ページは「正本(marketing/legal)」と「配信物(site/lien/legal)」の両方に同じ中身を置く。
    # 配信するのは site/ だけなので、site/ 側だけで完結させる
    for path, content in build_legal_pages(base):
        outputs[path] = content
        outputs[os.path.join(SITE_OUT_DIR, "lien", "legal", os.path.basename(path))] = content

    copy = read_store_copy()
    outputs[os.path.join(SITE_OUT_DIR, "index.html")] = render_index(config, copy)
    outputs[os.path.join(SITE_OUT_DIR, "assets", "site.css")] = SITE_CSS
    outputs[os.path.join(SITE_OUT_DIR, "assets", "icon.svg")] = render_icon_svg()
    for name, source, alt in SCREENSHOTS:
        with open(os.path.join(SCREENSHOT_DIR, source), "rb") as handle:
            outputs[os.path.join(SITE_OUT_DIR, "assets", name)] = handle.read()
    icon_png = build_icon_png()
    if icon_png is not None:
        outputs[os.path.join(SITE_OUT_DIR, "assets", "icon-1024.png")] = icon_png

    return outputs


def write_outputs(outputs):
    for path, content in outputs.items():
        directory = os.path.dirname(path)
        os.makedirs(directory, exist_ok=True)
        if isinstance(content, bytes):
            with open(path, "wb") as handle:
                handle.write(content)
            continue
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
    # 招待ページは手で保守している既存ファイルを複製する(中身は変換しない)
    invite_out = os.path.join(SITE_OUT_DIR, "lien", "i", "index.html")
    os.makedirs(os.path.dirname(invite_out), exist_ok=True)
    shutil.copyfile(INVITE_SRC, invite_out)
    # Jekyll を通さない(_ で始まるパスを消さない)。GitHub Actions 配備でも置いておく
    with open(os.path.join(SITE_OUT_DIR, ".nojekyll"), "w", encoding="utf-8"):
        pass


def check_committed(outputs):
    """生成物がコミット済みの内容と一致するか。違えば差分を返す。"""
    problems = []
    for path, content in outputs.items():
        if not os.path.exists(path):
            problems.append(f"未生成: {describe(path)}")
            continue
        if isinstance(content, bytes):
            with open(path, "rb") as handle:
                current = handle.read()
        else:
            with open(path, encoding="utf-8") as handle:
                current = handle.read()
        if current != content:
            problems.append(f"生成物が古い: {describe(path)}(python3 tools/build_site.py を実行してコミットしてください)")
    invite_out = os.path.join(SITE_OUT_DIR, "lien", "i", "index.html")
    if not os.path.exists(invite_out):
        problems.append(f"未生成: {describe(invite_out)}")
    else:
        with open(INVITE_SRC, encoding="utf-8") as a, open(invite_out, encoding="utf-8") as b:
            if a.read() != b.read():
                problems.append(f"生成物が古い: {describe(invite_out)}(web/invite/index.html の複製)")
    return problems


def check_publishable(config, site_index_html, legal_html):
    """公開してよい状態か。G4 のプレースホルダが残っていたら絶対に配備しない。"""
    problems = []
    for path, content in legal_html:
        if PLACEHOLDER_RE.search(content):
            problems.append(
                f"{describe(path)} に G4 のプレースホルダが残っています(【要記入: G4: …】)。"
                "CHECKLIST-G4.md §1 の4項目を md に記入してから公開してください"
            )
    if not config.get("baseUrl"):
        problems.append("site.json の baseUrl が未設定です(og:url と法務ページの戻りリンクに使います)")
    if not config.get("xUrl"):
        problems.append("site.json の xUrl が未設定です(X へのリンクはアカウントの @ハンドル確定後に設定します)")
    if "http://" in site_index_html:
        problems.append("index.html に http:// のリンクがあります(https にしてください)")
    return problems


def describe(path):
    return os.path.relpath(path, LIEN_DIR)


def run_check(outputs):
    problems = check_committed(outputs)
    for problem in problems:
        print(f"NG  {problem}")
    if problems:
        return 1
    print(f"OK  生成物 {len(outputs)} 件はコミット済みの内容と一致します")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="ティザーページと法務ページを生成する(issue #76)")
    parser.add_argument("--check", action="store_true", help="生成しなおさず、コミット済みの生成物と一致するかだけを見る")
    parser.add_argument("--check-publishable", action="store_true", help="公開してよい状態か(G4 のプレースホルダ・未確定の URL)を見る")
    parser.add_argument("--config", default=CONFIG_PATH, help="site.json のパス(テスト用)")
    args = parser.parse_args(argv)

    config = load_config(args.config)
    outputs = build_all(config)

    if args.check or args.check_publishable:
        status = run_check(outputs)
    else:
        write_outputs(outputs)
        print(f"OK  {len(outputs)} 件を生成しました({describe(SITE_OUT_DIR)} / {describe(LEGAL_OUT_DIR)})")
        status = 0

    if args.check_publishable:
        legal_html = [(path, content) for path, content in outputs.items() if path.endswith(("privacy.html", "terms.html"))]
        site_index = outputs[os.path.join(SITE_OUT_DIR, "index.html")]
        problems = check_publishable(config, site_index, legal_html)
        for problem in problems:
            print(f"NG  {problem}")
        if problems:
            status = 1
        else:
            print("OK  公開してよい状態です(G4 の記入済み・baseUrl と xUrl が設定済み)")

    return status


if __name__ == "__main__":
    sys.exit(main())
