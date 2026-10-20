#!/usr/bin/env python3
"""Lien の紹介・プレス向け素材の検査（Issue #94 / mkt M8）。

`products/lien/marketing/press/` のファクトシート・紹介文3種・スクリーンショット3枚が、
Issue #94 の受入条件と v1.0 の事実範囲に合っているかを、macOS も Xcode も無い CI（ubuntu）で確かめる。
標準ライブラリだけで動く（Pillow を使わない）。

検査する内容:
  1. copy.md: 60 / 200 / 600 字の3種があり、空白・改行を除いた文字数が上限以内で、
     本文の「文字数: N」と実際の文字数が一致すること。
     罰・恥・誇大表現、v1.0 に無い機能、将来の価格案・実績値を含まないこと。
  2. fact-sheet.html: 機能・対象・価格・提供元・連絡先・画面の見出しがあること。
     提供元・連絡先は G4（#42）のトークンのまま（推測で埋めない）。
     v1.0 に無い機能・価格案・実績値・外部URL・メールアドレス・スクリプトを含まないこと。
     スクショ3枚を参照し、alt が空でないこと。
  3. screenshots/: 3枚だけ・1290×2796・アルファなし（color type 2）・5KB以上・
     3枚が別画像であること。元の `../screenshots/6.7in/` と SHA-256 が一致すること。
  4. README.md / screenshots/README.md: 相対リンクが実在すること。

使い方:
  python3 tools/verify_press.py                 # 緑なら OK、赤なら理由を出して終了コード 1
  python3 tools/verify_press.py --root DIR      # テスト用
  python3 tools/verify_press.py --source DIR    # 元画像の場所（テスト用。空文字で照合を省略）

終了コード: 0 = OK / 1 = 不一致あり / 2 = 入力が読めない
"""

import argparse
import hashlib
import re
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parent / "press"
DEFAULT_SOURCE = HERE.parent / "screenshots" / "6.7in"

COPY_LIMITS = {
    "60字以内": 60,
    "200字以内": 200,
    "600字以内": 600,
}

REQUIRED_SECTIONS = (
    "サービス概要",
    "対象",
    "主な機能",
    "提供環境・価格",
    "提供元",
    "連絡先",
    "画面イメージ",
)

# プレスに使う v1.0 の3枚。01_home_both.png は画像内のサブコピー「ふたりで決めて」が
# 本文の「ふたりがそれぞれ」と食い違うため使わない（MK7 の完成画像を加工しない。
# 直すなら captions.json を更新して再生成する）。03_widget.png は v1.0.1 の M を含むため
# 使わない（REQUIREMENTS §3.10）
SCREENSHOTS = (
    "02_home_waiting.png",
    "04_history.png",
    "05_share.png",
)

EXPECTED_WIDTH = 1290
EXPECTED_HEIGHT = 2796
MIN_BYTES = 5_000

# 罰・恥・煽り・誇大表現（REQUIREMENTS §3.5 / DESIGN §3.8 と、store 用 captions の禁止語に合わせる）
BANNED = (
    "失敗",
    "最強",
    "No.1",
    "日本一",
    "絶対",
    "必ず",
    "誰でも",
    "枯れ",
    "サボ",
    "罰",
    "恥",
    "ダメ",
    "怒",
)

# v1.0 に無い機能・将来の話。紹介文とファクトシートには入れない
FUTURE = (
    "v1.1",
    "課金",
    "サブスク",
    "プレミアム",
    "アルバム",
    "Sign in with Apple",
    "Apple連携",
    "Android",
    "複数ペア",
    "花壇",
    "おきゃくさん",
    "ストリーク保険",
    "有料",
)

# 実績・価格の数値（KPI.md / CONCEPT.md の将来案・目標値）。紹介素材には使わない
FORBIDDEN_NUMBERS = (
    "700円",
    "2,400円",
    "2400円",
    "43人",
    "63ペア",
    "500DL",
    "500 DL",
    "500ダウンロード",
    "25%",
    "40%",
    "8%",
    "69%",
    "9,100",
    "2,400万",
    "480円",
)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


class InputError(Exception):
    """入力が読めない（ファイルが無い・文字コードが壊れている）"""


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise InputError("%s が読めません: %s" % (path, error))
    except UnicodeDecodeError as error:
        raise InputError("%s が UTF-8 として読めません: %s" % (path, error))


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def png_header(path):
    """PNG の (幅, 高さ, カラータイプ) を返す。PNG でなければ InputError。"""
    try:
        data = Path(path).read_bytes()
    except OSError as error:
        raise InputError("%s が読めません: %s" % (path, error))
    if len(data) < 33 or not data.startswith(PNG_SIGNATURE):
        raise InputError("%s は PNG ではありません" % path)
    length, chunk = struct.unpack(">I4s", data[8:16])
    if chunk != b"IHDR" or length != 13:
        raise InputError("%s の先頭が IHDR ではありません" % path)
    width, height = struct.unpack(">II", data[16:24])
    color_type = data[25]
    return width, height, color_type


def char_count(text):
    """空白・改行を除いた文字数。"""
    return len(re.sub(r"\s", "", text))


def parse_copy(text):
    """copy.md から {見出し: (本文, 宣言された文字数 or None)} を取り出す。"""
    pattern = re.compile(r"^## (60字以内|200字以内|600字以内)\s*$", re.MULTILINE)
    matches = list(pattern.finditer(text))
    sections = {}
    duplicates = []
    for index, match in enumerate(matches):
        label = match.group(1)
        if label in sections:
            duplicates.append(label)
            continue
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        chunk = text[match.end():end]
        # 次の「## 使い分け」などの見出しで切る（文字数の宣言はその前にある）
        chunk = re.split(r"\n## ", chunk, maxsplit=1)[0]
        if "\n文字数:" in chunk:
            body, rest = chunk.split("\n文字数:", 1)
            declared_match = re.match(r"\s*(\d+)", rest)
            declared = int(declared_match.group(1)) if declared_match else None
        else:
            body, declared = chunk, None
        sections[label] = (body.strip(), declared)
    return sections, duplicates


def check_copy(root, errors):
    path = root / "copy.md"
    try:
        text = read_text(path)
    except InputError as error:
        errors.append(str(error))
        return

    sections, duplicates = parse_copy(text)
    for label in duplicates:
        errors.append("copy.md: 見出し「%s」が重複している" % label)
    for label, limit in COPY_LIMITS.items():
        if label not in sections:
            errors.append("copy.md: 「## %s」がありません" % label)
            continue
        body, declared = sections[label]
        count = char_count(body)
        if not body:
            errors.append("copy.md: %s の本文が空です" % label)
            continue
        if count > limit:
            errors.append("copy.md: %s が %d 字（上限 %d 字）" % (label, count, limit))
        if declared is None:
            errors.append("copy.md: %s に「文字数: N」がありません" % label)
        elif declared != count:
            errors.append(
                "copy.md: %s の宣言 %d 字と実際 %d 字が違う（数え直して更新する）" % (label, declared, count)
            )
        for word in BANNED:
            if word in body:
                errors.append("copy.md: %s に使わない表現「%s」が入っている" % (label, word))
        for word in FUTURE:
            if word in body:
                errors.append("copy.md: %s に v1.0 に無い機能・将来の話「%s」が入っている" % (label, word))
        for number in FORBIDDEN_NUMBERS:
            if number in body:
                errors.append("copy.md: %s に実績・将来価格の数値「%s」が入っている" % (label, number))
        if re.search(r"https?://", body):
            errors.append("copy.md: %s に外部URLが入っている" % label)
        if EMAIL_RE.search(body):
            errors.append("copy.md: %s にメールアドレスが入っている（G4 前に載せない）" % label)


def first_paragraph_after(html, heading):
    """<h2>heading</h2> の直後の最初の <p> のテキストを返す（タグは除く）。"""
    match = re.search(
        r"<h2[^>]*>%s</h2>(.*?)(?=<h2|</section>)" % re.escape(heading),
        html,
        re.S,
    )
    if not match:
        return None
    paragraph = re.search(r"<p[^>]*>(.*?)</p>", match.group(1), re.S)
    if not paragraph:
        return ""
    return re.sub(r"<[^>]+>", "", paragraph.group(1)).strip()


def check_fact_sheet(root, errors):
    path = root / "fact-sheet.html"
    try:
        html = read_text(path)
    except InputError as error:
        errors.append(str(error))
        return

    if 'lang="ja"' not in html:
        errors.append("fact-sheet.html: lang=\"ja\" がない")
    title = re.search(r"<title>(.*?)</title>", html, re.S)
    if not title or "Lien" not in title.group(1):
        errors.append("fact-sheet.html: <title> に Lien がない")

    headings = [re.sub(r"\s+", "", value) for value in re.findall(r"<h2[^>]*>(.*?)</h2>", html, re.S)]
    for section in REQUIRED_SECTIONS:
        if not any(section in heading for heading in headings):
            errors.append("fact-sheet.html: 見出し「%s」がない" % section)

    for phrase in ("全機能無料", "v1.0", "恋人・夫婦・友達・家族"):
        if phrase not in html:
            errors.append("fact-sheet.html: 「%s」がない" % phrase)
    for source in ("REQUIREMENTS.md", "CONCEPT.md", "terms.html"):
        if source not in html:
            errors.append("fact-sheet.html: 出典「%s」がない" % source)
    provider = first_paragraph_after(html, "提供元")
    contact = first_paragraph_after(html, "連絡先")
    if provider is not None and not provider:
        errors.append("fact-sheet.html: 提供元の値が空（G4 確定前は <OPERATOR_NAME>、確定後は事業者名）")
    if contact is not None:
        if not contact:
            errors.append("fact-sheet.html: 連絡先の値が空（G4 確定前は <CONTACT_EMAIL>、確定後はメールアドレス）")
        elif "CONTACT_EMAIL" not in contact and not EMAIL_RE.search(contact):
            errors.append("fact-sheet.html: 連絡先にメールアドレスか <CONTACT_EMAIL> がない")
    for token in ("OPERATOR_NAME", "CONTACT_EMAIL"):
        if token in html and "G4" not in html:
            errors.append("fact-sheet.html: G4 のトークン「%s」があるのに、G4 の注記がない" % token)

    for word in BANNED:
        if word in html:
            errors.append("fact-sheet.html: 使わない表現「%s」が入っている" % word)
    for word in FUTURE:
        if word in html:
            errors.append("fact-sheet.html: v1.0 に無い機能・将来の話「%s」が入っている" % word)
    for number in FORBIDDEN_NUMBERS:
        if number in html:
            errors.append("fact-sheet.html: 実績・将来価格の数値「%s」が入っている" % number)
    if re.search(r"https?://", html):
        errors.append("fact-sheet.html: 外部URLが入っている（自己完結の資料にする）")
    for email in EMAIL_RE.findall(html):
        if contact is None or email not in contact:
            errors.append("fact-sheet.html: メールアドレスは連絡先欄だけに置く（%s）" % email)
    if re.search(r"<script\b|<iframe\b|<form\b|javascript:|\son[a-z]+\s*=", html, re.I):
        errors.append("fact-sheet.html: script / iframe / form / イベントハンドラが入っている")

    tags = re.findall(r"<img\b[^>]*>", html, re.I)
    if len(tags) != len(SCREENSHOTS):
        errors.append("fact-sheet.html: スクショの <img> が %d 個（期待 %d）" % (len(tags), len(SCREENSHOTS)))
    sources = []
    for tag in tags:
        src_match = re.search(r'\bsrc="([^"]+)"', tag, re.I)
        alt_match = re.search(r'\balt="([^"]*)"', tag, re.I)
        if not src_match:
            errors.append("fact-sheet.html: <img> に src がない")
        else:
            src = src_match.group(1)
            sources.append(src)
            if not src.startswith("screenshots/"):
                errors.append("fact-sheet.html: 画像 %s が screenshots/ の下にない" % src)
            if not (root / src).exists():
                errors.append("fact-sheet.html: 画像 %s が実在しない" % src)
        if not alt_match or not alt_match.group(1).strip():
            errors.append("fact-sheet.html: <img> の alt が空")
    if sorted(Path(src).name for src in sources) != sorted(SCREENSHOTS):
        errors.append("fact-sheet.html: 参照している画像が3枚と一致しない: %s" % sorted(sources))


def check_screenshots(root, source_dir, errors):
    directory = root / "screenshots"
    if not directory.is_dir():
        errors.append("screenshots/ がありません")
        return

    actual = sorted(path.name for path in directory.glob("*.png"))
    if actual != sorted(SCREENSHOTS):
        errors.append(
            "screenshots/: PNG が %s（期待 %s）。余計な画像を置かない"
            % (actual, sorted(SCREENSHOTS))
        )

    digests = {}
    for name in SCREENSHOTS:
        path = directory / name
        if not path.exists():
            errors.append("screenshots/%s がありません" % name)
            continue
        if path.stat().st_size < MIN_BYTES:
            errors.append("screenshots/%s が %d bytes と小さすぎる（空画像でないか）" % (name, path.stat().st_size))
        try:
            width, height, color_type = png_header(path)
        except InputError as error:
            errors.append(str(error))
            continue
        if (width, height) != (EXPECTED_WIDTH, EXPECTED_HEIGHT):
            errors.append(
                "screenshots/%s: 寸法が %d×%d（期待 %d×%d）"
                % (name, width, height, EXPECTED_WIDTH, EXPECTED_HEIGHT)
            )
        if color_type != 2:
            errors.append("screenshots/%s: アルファなしの RGB（color type 2）でない: %d" % (name, color_type))
        digest = sha256(path)
        if digest in digests:
            errors.append("screenshots/%s が %s と同じ画像（3枚は別の画面）" % (name, digests[digest]))
        digests[digest] = name

        if source_dir is not None:
            source = Path(source_dir) / name
            if not source.exists():
                errors.append("元画像 %s がありません（MK7 の 6.7in と照合できない）" % source)
            elif sha256(source) != digest:
                errors.append(
                    "screenshots/%s が元画像 %s と SHA-256 で一致しない（加工・差し替え漏れ）" % (name, source)
                )


def check_markdown_links(root, errors):
    readmes = (root / "README.md", root / "screenshots" / "README.md")
    for path in readmes:
        if not path.exists():
            errors.append("%s がありません" % path)
            continue
        try:
            text = read_text(path)
        except InputError as error:
            errors.append(str(error))
            continue
        for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", text):
            target = target.strip()
            if target.startswith(("http://", "https://", "#", "mailto:")):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            if not (path.parent / target).resolve().exists():
                errors.append("%s: リンク先 %s が実在しない" % (path.relative_to(root), target))

    readme = root / "README.md"
    if readme.exists():
        try:
            text = read_text(readme)
        except InputError as error:
            errors.append(str(error))
            text = ""
        for phrase in ("mkt-review", "G4", "v1.0"):
            if phrase not in text:
                errors.append("README.md: 「%s」の記載がない" % phrase)


def verify(root=DEFAULT_ROOT, source_dir=DEFAULT_SOURCE):
    """root（press/）を検査して、エラーの一覧を返す。空なら OK。"""
    root = Path(root)
    errors = []
    check_copy(root, errors)
    check_fact_sheet(root, errors)
    check_screenshots(root, Path(source_dir) if source_dir else None, errors)
    check_markdown_links(root, errors)
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description="Lien の紹介・プレス向け素材の検査（Issue #94）")
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="press/ の場所（既定: このリポジトリ）")
    parser.add_argument(
        "--source",
        default=str(DEFAULT_SOURCE),
        help="元画像（6.7in）の場所。空文字で SHA-256 の照合を省略する",
    )
    args = parser.parse_args(argv)

    try:
        errors = verify(Path(args.root), Path(args.source) if args.source else None)
    except InputError as error:
        print("NG: %s" % error, file=sys.stderr)
        return 2

    if errors:
        print("NG: %d 件" % len(errors), file=sys.stderr)
        for error in errors:
            print("  - %s" % error, file=sys.stderr)
        return 1

    print(
        "OK: 紹介文3種（60/200/600字以内）+ ファクトシート（機能・対象・価格・提供元・連絡先）"
        "+ スクショ3枚（%d×%d・アルファなし・元画像と一致）" % (EXPECTED_WIDTH, EXPECTED_HEIGHT)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
