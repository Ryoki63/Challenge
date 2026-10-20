#!/usr/bin/env python3
"""verify_press.py の検査ロジックの単体テスト（Issue #94 / mkt M8）。

CI（`store-metadata` ジョブ）とローカルの両方で実行する:
  cd products/lien/marketing && python3 -m unittest discover -s tools -p "test_*.py"

検査を壊しても気づけるように、緑になる例だけでなく、赤になる例
（文字数超過・宣言とのずれ・禁止語・将来機能・価格案・必須項目の欠け・G4 トークンの欠け・
外部URL・スクショの欠け/寸法違い/アルファ付き/重複/元画像との不一致・リンク切れ）を固定する。
PNG は標準ライブラリ（zlib + struct）で作る。Pillow は使わない。
"""

import os
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import verify_press as vp  # noqa: E402  (sys.path の追加後に読み込む)


# MARK: - テスト用の PNG

def png_bytes(width, height, color_type=2, pixel=(210, 225, 200)):
    """単色の PNG を作る（color_type 2 = RGB / 6 = RGBA / 0 = グレー）。"""
    channels = {0: 1, 2: 3, 6: 4}[color_type]
    color = bytes(pixel[:channels])
    raw = (b"\x00" + color * width) * height

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


# MARK: - テスト用の press/ を作る

def copy_body(limit, suffix=""):
    """上限ちょうどの本文（Lien + ひらがな）。suffix で壊す。"""
    prefix = "Lien（リアン）"
    return prefix + "あ" * (limit - len(prefix) - len(suffix)) + suffix


def copy_text(bodies=None, declared=None):
    bodies = dict(bodies or {})
    declared = dict(declared or {})
    defaults = {label: copy_body(limit) for label, limit in vp.COPY_LIMITS.items()}
    defaults.update(bodies)
    chunks = []
    for label in vp.COPY_LIMITS:
        body = defaults[label]
        count = len("".join(body.split()))
        chunks.append("## %s\n\n%s\n\n文字数: %d\n" % (label, body, declared.get(label, count)))
    return "# 紹介文\n\n" + "\n".join(chunks)


def fact_sheet_html():
    return """<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>Lien（リアン）ファクトシート</title></head>
<body>
<p>提供元・連絡先は G4 で確定する。</p>
<h2>サービス概要</h2><p>ふたりで使う習慣アプリ。</p>
<h2>対象</h2><p>恋人・夫婦・友達・家族など。</p>
<h2>v1.0 の主な機能</h2><p>チェックインとウィジェット。</p>
<h2>提供環境・価格</h2><p>iOS アプリ。v1.0 は全機能無料。</p>
<h2>提供元</h2><p>&lt;OPERATOR_NAME&gt;</p>
<h2>連絡先</h2><p>&lt;CONTACT_EMAIL&gt;</p>
<h2>本資料に載せていないこと</h2><p>実績値は記載しない。</p>
<h2>画面イメージ（v4）</h2>
<img src="screenshots/02_home_waiting.png" alt="ホーム（相手が待っている）">
<img src="screenshots/06_home_solo.png" alt="ソロのホーム（招待）">
<img src="screenshots/05_share.png" alt="シェア画像">
<p>出典: docs/REQUIREMENTS.md、docs/CONCEPT.md、legal/terms.html。</p>
</body>
</html>
"""


def readme_text():
    return """# プレス向け素材

- [ファクトシート](fact-sheet.html)
- [紹介文](copy.md)
- [スクリーンショット](screenshots/)

mkt-review のレビュー待ち。提供元・連絡先は G4 で確定する。v1.0 の範囲だけを書く。
"""


def screenshots_readme_text():
    return """# スクリーンショット

- [相手待ち](02_home_waiting.png)
- [ペアのはじめかた](06_home_solo.png)
- [シェア画像](05_share.png)
"""


def write_fixture(root, source, copy=None, fact=None, readme=None, shots_readme=None, png_overrides=None):
    root = Path(root)
    source = Path(source)
    (root / "screenshots").mkdir(parents=True)
    (source).mkdir(parents=True, exist_ok=True)
    (root / "copy.md").write_text(copy if copy is not None else copy_text(), encoding="utf-8")
    (root / "fact-sheet.html").write_text(fact if fact is not None else fact_sheet_html(), encoding="utf-8")
    (root / "README.md").write_text(readme if readme is not None else readme_text(), encoding="utf-8")
    (root / "screenshots" / "README.md").write_text(
        shots_readme if shots_readme is not None else screenshots_readme_text(), encoding="utf-8"
    )
    overrides = png_overrides or {}
    for index, name in enumerate(vp.SCREENSHOTS):
        data = overrides.get(name, png_bytes(1290, 2796, 2, (200 + index, 220, 180)))
        (root / "screenshots" / name).write_bytes(data)
        (source / name).write_bytes(data)


class PressKitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.root = base / "press"
        self.source = base / "source"
        write_fixture(self.root, self.source)

    def tearDown(self):
        self.tmp.cleanup()

    def errors(self):
        return vp.verify(self.root, self.source)

    # MARK: 緑

    def test_valid_fixture_has_no_error(self):
        self.assertEqual(self.errors(), [])

    # MARK: copy.md

    def test_copy_over_limit(self):
        body = copy_body(60) + "あ"
        (self.root / "copy.md").write_text(copy_text({"60字以内": body}), encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("60字以内 が 61 字" in error for error in errors), errors)

    def test_declared_count_mismatch(self):
        (self.root / "copy.md").write_text(copy_text(declared={"200字以内": 1}), encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("宣言 1 字と実際 200 字" in error for error in errors), errors)

    def test_banned_word_in_copy(self):
        body = copy_body(200, suffix="必ず")
        (self.root / "copy.md").write_text(copy_text({"200字以内": body}), encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("使わない表現「必ず」" in error for error in errors), errors)

    def test_future_feature_in_copy(self):
        body = copy_body(200, suffix="課金")
        (self.root / "copy.md").write_text(copy_text({"200字以内": body}), encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("v1.0 に無い機能・将来の話「課金」" in error for error in errors), errors)

    def test_price_in_copy(self):
        body = copy_body(200, suffix="月700円")
        (self.root / "copy.md").write_text(copy_text({"200字以内": body}), encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("実績・将来価格の数値「700円」" in error for error in errors), errors)

    def test_external_url_in_copy(self):
        body = copy_body(200, suffix="https://example.com")
        (self.root / "copy.md").write_text(copy_text({"200字以内": body}), encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("外部URL" in error for error in errors), errors)

    def test_email_in_copy(self):
        body = copy_body(200, suffix="a@example.com")
        (self.root / "copy.md").write_text(copy_text({"200字以内": body}), encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("メールアドレス" in error for error in errors), errors)

    def test_duplicate_copy_heading(self):
        text = copy_text() + "\n## 60字以内\n\nLien\n\n文字数: 4\n"
        (self.root / "copy.md").write_text(text, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("見出し「60字以内」が重複" in error for error in errors), errors)

    # MARK: fact-sheet.html

    def test_missing_fact_section(self):
        html = fact_sheet_html().replace("<h2>連絡先</h2>", "<h2>連絡</h2>")
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("見出し「連絡先」がない" in error for error in errors), errors)

    def test_missing_contact_value(self):
        html = fact_sheet_html().replace("<p>&lt;CONTACT_EMAIL&gt;</p>", "<p></p>")
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("連絡先の値が空" in error for error in errors), errors)

    def test_filled_provider_and_contact_are_ok(self):
        html = (
            fact_sheet_html()
            .replace("<p>&lt;OPERATOR_NAME&gt;</p>", "<p>Lien 運営</p>")
            .replace("<p>&lt;CONTACT_EMAIL&gt;</p>", "<p>support@example.com</p>")
        )
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        self.assertEqual(self.errors(), [])

    def test_email_outside_contact_is_rejected(self):
        html = fact_sheet_html().replace("<p>実績値は記載しない。</p>", "<p>連絡は a@example.com まで。</p>")
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("メールアドレスは連絡先欄だけ" in error for error in errors), errors)

    def test_fact_sheet_banned_word(self):
        html = fact_sheet_html().replace("<p>実績値は記載しない。</p>", "<p>必ず続く。</p>")
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("使わない表現「必ず」" in error for error in errors), errors)

    def test_fact_sheet_future_feature(self):
        html = fact_sheet_html().replace("<p>実績値は記載しない。</p>", "<p>課金は v1.1。</p>")
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("将来の話「課金」" in error for error in errors), errors)

    def test_fact_sheet_price(self):
        html = fact_sheet_html().replace("<p>実績値は記載しない。</p>", "<p>月700円。</p>")
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("数値「700円」" in error for error in errors), errors)

    def test_fact_sheet_external_url(self):
        html = fact_sheet_html().replace("<p>実績値は記載しない。</p>", '<p>https://example.com</p>')
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("外部URL" in error for error in errors), errors)

    def test_fact_sheet_script(self):
        html = fact_sheet_html().replace("</body>", "<script>alert(1)</script></body>")
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("script / iframe / form" in error for error in errors), errors)

    def test_fact_sheet_img_alt_missing(self):
        html = fact_sheet_html().replace(' alt="シェア画像"', "")
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("alt が空" in error for error in errors), errors)

    def test_fact_sheet_img_missing(self):
        html = fact_sheet_html().replace(
            '<img src="screenshots/05_share.png" alt="シェア画像">', ""
        )
        (self.root / "fact-sheet.html").write_text(html, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("<img> が 2 個" in error for error in errors), errors)

    # MARK: screenshots/

    def test_screenshot_wrong_dimensions(self):
        (self.root / "screenshots" / "02_home_waiting.png").write_bytes(png_bytes(100, 100))
        errors = self.errors()
        self.assertTrue(any("寸法が 100×100" in error for error in errors), errors)

    def test_screenshot_with_alpha(self):
        (self.root / "screenshots" / "02_home_waiting.png").write_bytes(png_bytes(1290, 2796, 6))
        errors = self.errors()
        self.assertTrue(any("color type 2）でない" in error for error in errors), errors)

    def test_screenshot_duplicate(self):
        data = (self.root / "screenshots" / "02_home_waiting.png").read_bytes()
        (self.root / "screenshots" / "06_home_solo.png").write_bytes(data)
        errors = self.errors()
        self.assertTrue(any("と同じ画像" in error for error in errors), errors)

    def test_screenshot_missing(self):
        (self.root / "screenshots" / "05_share.png").unlink()
        errors = self.errors()
        self.assertTrue(any("screenshots/05_share.png がありません" in error for error in errors), errors)

    def test_screenshot_extra(self):
        (self.root / "screenshots" / "99_extra.png").write_bytes(png_bytes(1290, 2796))
        errors = self.errors()
        self.assertTrue(any("余計な画像を置かない" in error for error in errors), errors)

    def test_screenshot_not_matching_source(self):
        path = self.root / "screenshots" / "02_home_waiting.png"
        path.write_bytes(path.read_bytes() + b"x")
        errors = self.errors()
        self.assertTrue(any("SHA-256 で一致しない" in error for error in errors), errors)

    # MARK: README

    def test_dead_readme_link(self):
        text = readme_text() + "\n- [無いファイル](missing.md)\n"
        (self.root / "README.md").write_text(text, encoding="utf-8")
        errors = self.errors()
        self.assertTrue(any("リンク先 missing.md が実在しない" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
