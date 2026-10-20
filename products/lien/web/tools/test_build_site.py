#!/usr/bin/env python3
"""build_site.py の検査(MK3 / issue #76)。

  cd products/lien/web && python3 -m unittest discover -s tools -p "test_*.py" -v

見ていること:
  - Markdown → HTML が、この2文書で使う記法を落とさず変換できる(知らない記法は例外)
  - 生成物がコミット済みと一致する(md を直して再生成し忘れる事故を CI で止める)
  - 公開物に **入力フォーム・メール収集・外部スクリプト** が無い(issue #76 の完了条件)
  - トップに 1行説明・スクリーンショット3枚・近日公開・法務リンクがある
  - X / App Store のリンクは、URL を設定したときだけ出る(未確定の値をでっち上げない)
  - G4 のプレースホルダが残っているあいだは公開できない(--check-publishable が止める)
"""

import json
import os
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET

import build_site

# 罰・恥・煽り系の禁止ワード(REQUIREMENTS §3.5)。marketing/tools/verify_metadata.py と同じ語
BANNED_PATTERN = re.compile(r"枯れ|サボ|罰|恥|ダメ|怒|遅い|まだやってない")


def load_copy():
    return build_site.read_store_copy()


def default_config(**overrides):
    config = {
        "baseUrl": "https://example.github.io/Challenge",
        "xUrl": None,
        "appStoreUrl": None,
        "contactEmail": None,
        "statusLabel": "近日公開",
    }
    config.update(overrides)
    return config


class RenderInlineTest(unittest.TestCase):
    def test_bold(self):
        self.assertEqual(build_site.render_inline("**太字**です"), "<strong>太字</strong>です")

    def test_placeholder_is_highlighted(self):
        got = build_site.render_inline("【要記入: G4: 制定日】")
        self.assertEqual(got, '<span class="placeholder">【要記入: G4: 制定日】</span>')

    def test_link(self):
        self.assertEqual(
            build_site.render_inline("[規約](https://example.com/a.html)"),
            '<a href="https://example.com/a.html">規約</a>',
        )

    def test_inline_code(self):
        self.assertEqual(build_site.render_inline("`print()` を呼ぶ"), "<code>print()</code> を呼ぶ")

    def test_html_is_escaped(self):
        self.assertEqual(build_site.render_inline("a < b & c > d"), "a &lt; b &amp; c &gt; d")


class MarkdownTest(unittest.TestCase):
    def test_headings_and_paragraphs(self):
        html = build_site.markdown_to_html("# 見出し\n\n本文です。\n")
        self.assertIn("<h1>見出し</h1>", html)
        self.assertIn("<p>本文です。</p>", html)

    def test_h2_gets_blank_line_before_it(self):
        html = build_site.markdown_to_html("前の段落\n\n## 見出し\n")
        self.assertIn("</p>\n\n<h2>見出し</h2>", html)

    def test_flat_list(self):
        html = build_site.markdown_to_html("- あ\n- い\n")
        self.assertEqual(html, "<ul>\n  <li>あ</li>\n  <li>い</li>\n</ul>\n")

    def test_ordered_list(self):
        html = build_site.markdown_to_html("1. あ\n2. い\n")
        self.assertEqual(html, "<ol>\n  <li>あ</li>\n  <li>い</li>\n</ol>\n")

    def test_nested_list(self):
        html = build_site.markdown_to_html("1. 親\n   - 子1\n   - 子2\n2. 次の親\n")
        self.assertIn("<li>親\n    <ul>\n      <li>子1</li>", html)
        self.assertIn("      <li>子2</li>\n    </ul>\n  </li>", html)
        self.assertIn("<li>次の親</li>", html)

    def test_table(self):
        html = build_site.markdown_to_html("| あ | い |\n|---|---|\n| 1 | 2 |\n")
        self.assertIn("<th>あ</th><th>い</th>", html)
        self.assertIn("<td>1</td><td>2</td>", html)

    def test_table_column_mismatch_is_an_error(self):
        with self.assertRaises(ValueError):
            build_site.markdown_to_html("| あ | い |\n|---|---|\n| 1 |\n")

    def test_unknown_block_syntax_raises(self):
        with self.assertRaises(ValueError):
            build_site.markdown_to_html("> 引用は未対応\n")

    def test_mixed_list_kind_at_same_depth_raises(self):
        with self.assertRaises(ValueError):
            build_site.markdown_to_html("- あ\n1. い\n")


class MetaListTest(unittest.TestCase):
    def test_meta_list_becomes_one_paragraph(self):
        body = build_site.markdown_to_html(
            "# 題\n\n- 制定日: 2026年1月1日\n- 運営者: だれか\n\n本文\n"
        )
        out = build_site.convert_meta_list(body)
        self.assertIn('<p class="meta">\n制定日: 2026年1月1日<br>\n運営者: だれか\n</p>\n<p>本文</p>', out)
        self.assertNotIn("<ul>", out)


class LegalPagesTest(unittest.TestCase):
    """md が正本であること・生成結果に Markdown の記号が残らないことを見る。"""

    def setUp(self):
        self.pages = {os.path.basename(path): content for path, content in build_site.build_legal_pages("")}

    def test_both_pages_are_generated(self):
        self.assertEqual(set(self.pages), {"privacy.html", "terms.html"})

    def test_no_markdown_leftovers(self):
        for name, content in self.pages.items():
            body = re.search(r"<main>(.*?)</main>", content, re.S).group(1)
            self.assertNotIn("**", body, name)
            self.assertNotIn("|---", body, name)
            self.assertNotRegex(body, r"(?m)^## ", name)
            self.assertNotIn("【要記入", re.sub(r'<span class="placeholder">.*?</span>', "", body), name)

    def test_every_heading_of_the_source_appears(self):
        for md_name, html_name, _, _ in build_site.LEGAL_PAGES:
            with open(os.path.join(build_site.MARKETING_DIR, md_name), encoding="utf-8") as handle:
                source = handle.read()
            headings = [line[3:].strip() for line in source.splitlines() if line.startswith("## ")]
            self.assertTrue(headings)
            for heading in headings:
                self.assertIn(f"<h2>{heading}</h2>", self.pages[html_name], f"{html_name}: {heading}")

    def test_placeholders_are_highlighted_not_dropped(self):
        # G4 で人が埋めるまで、4項目は消さずに目立たせる(埋め忘れを公開物で見つけられるように)
        for name in ("privacy.html", "terms.html"):
            self.assertIn('<span class="placeholder">【要記入: G4:', self.pages[name])

    def test_language_and_viewport(self):
        for content in self.pages.values():
            self.assertIn('<html lang="ja">', content)
            self.assertIn('name="viewport"', content)

    def test_no_form_in_legal_pages(self):
        for content in self.pages.values():
            self.assertNotIn("<form", content)
            self.assertNotIn("<input", content)


class IndexPageTest(unittest.TestCase):
    def setUp(self):
        self.copy = load_copy()
        self.html = build_site.render_index(default_config(), self.copy)

    def test_one_liner_comes_from_the_approved_store_copy(self):
        # 1行説明は、確定済みのストア文言(subtitle)をそのまま使う(独自コピーを増やさない)
        self.assertIn(f'<p class="one-liner">{self.copy["subtitle"]}</p>', self.html)

    def test_exactly_three_screenshots(self):
        shots = re.findall(r'<img src="assets/(shot-[^"]+)"', self.html)
        self.assertEqual(len(shots), 3, shots)
        self.assertEqual(len(set(shots)), 3)

    def test_coming_soon_badge(self):
        self.assertIn("近日公開", self.html)

    def test_legal_links(self):
        self.assertIn('href="lien/legal/privacy.html"', self.html)
        self.assertIn('href="lien/legal/terms.html"', self.html)

    def test_no_input_form_and_no_email_collection(self):
        # issue #76: 個人情報を集めるフォームは置かない(メール収集は行わない)
        self.assertNotIn("<form", self.html)
        self.assertNotIn("<input", self.html)
        self.assertNotIn('type="email"', self.html)
        self.assertNotIn("mailto:", self.html)

    def test_no_scripts_and_no_external_resources(self):
        # 計測 SDK・外部フォント・CDN を読み込まない(依存ゼロの静的ページ)
        self.assertNotIn("<script", self.html)
        self.assertNotIn("<iframe", self.html)
        external = re.findall(r'(?:src|href)="(https?://[^"]+)"', self.html)
        for url in external:
            self.assertTrue(url.startswith("https://"), url)

    def test_no_banned_words(self):
        visible = re.sub(r"<[^>]+>", "", self.html)
        self.assertIsNone(BANNED_PATTERN.search(visible), BANNED_PATTERN.search(visible))

    def test_x_link_is_absent_until_configured(self):
        self.assertNotIn("X で開発の様子を見る", self.html)
        self.assertIn("xUrl 未設定", self.html)

    def test_x_link_appears_when_configured(self):
        html = build_site.render_index(default_config(xUrl="https://x.com/example"), self.copy)
        self.assertIn('href="https://x.com/example"', html)
        self.assertIn("X で開発の様子を見る", html)

    def test_app_store_link_replaces_the_badge(self):
        html = build_site.render_index(
            default_config(appStoreUrl="https://apps.apple.com/jp/app/id0000000000"), self.copy
        )
        self.assertIn("App Store で見る", html)
        self.assertIn("配信中", html)
        self.assertNotIn("公開したら、このページでお知らせします", html)

    def test_contact_appears_only_when_configured(self):
        html = build_site.render_index(default_config(contactEmail="support@example.com"), self.copy)
        self.assertIn('href="mailto:support@example.com"', html)

    def test_og_url_uses_base_url(self):
        self.assertIn('<meta property="og:url" content="https://example.github.io/Challenge/">', self.html)

    def test_every_relative_link_resolves(self):
        """ページ内の相対リンク・画像が、生成物として実在するか。"""
        outputs = build_site.build_all(default_config())
        site = build_site.SITE_OUT_DIR
        targets = re.findall(r'(?:src|href)="(?!https?:|mailto:|#)([^"]+)"', self.html)
        self.assertTrue(targets)
        for target in targets:
            path = os.path.normpath(os.path.join(site, target))
            self.assertIn(path, outputs, f"生成物にありません: {target}")


class BuildAllTest(unittest.TestCase):
    def test_outputs_cover_the_deployable_set(self):
        outputs = build_site.build_all(default_config())
        names = {os.path.relpath(path, build_site.SITE_OUT_DIR) for path in outputs if path.startswith(build_site.SITE_OUT_DIR)}
        for required in (
            "index.html",
            "assets/site.css",
            "assets/icon.svg",
            "assets/shot-1-home.svg",
            "assets/shot-2-widget.svg",
            "assets/shot-3-checkin.svg",
            "lien/legal/privacy.html",
            "lien/legal/terms.html",
        ):
            self.assertIn(required, names)

    def test_site_legal_copies_match_the_source_of_truth(self):
        outputs = build_site.build_all(default_config())
        for _, html_name, _, _ in build_site.LEGAL_PAGES:
            canonical = os.path.join(build_site.LEGAL_OUT_DIR, html_name)
            deployed = os.path.join(build_site.SITE_OUT_DIR, "lien", "legal", html_name)
            self.assertEqual(outputs[canonical], outputs[deployed], html_name)

    def test_screenshots_are_valid_svg_of_the_right_size(self):
        outputs = build_site.build_all(default_config())
        for name in ("shot-1-home.svg", "shot-2-widget.svg", "shot-3-checkin.svg"):
            content = outputs[os.path.join(build_site.SITE_OUT_DIR, "assets", name)]
            root = ET.fromstring(content)
            self.assertEqual(root.get("width"), "660")
            self.assertEqual(root.get("height"), "1430")
            self.assertIn('xmlns="http://www.w3.org/2000/svg"', content)

    def test_no_external_references_in_screenshots(self):
        # SVG を <img> で読むと外部参照は読み込まれない。立ち絵は埋め込みで完結させる
        outputs = build_site.build_all(default_config())
        for name in ("shot-1-home.svg", "shot-2-widget.svg", "shot-3-checkin.svg"):
            content = outputs[os.path.join(build_site.SITE_OUT_DIR, "assets", name)]
            self.assertNotIn("xlink:href", content)
            self.assertNotIn("<image", content)

    def test_widget_screenshot_does_not_claim_photos(self):
        # v1.0 のウィジェットに相手の写真は出ない(D3)。出しているように見せない
        outputs = build_site.build_all(default_config())
        content = outputs[os.path.join(build_site.SITE_OUT_DIR, "assets", "shot-2-widget.svg")]
        self.assertNotIn("写真", content)


class DriftTest(unittest.TestCase):
    def test_committed_outputs_match_the_generator(self):
        """md を直したら再生成する。忘れると CI が止まる。"""
        outputs = build_site.build_all(build_site.load_config())
        problems = build_site.check_committed(outputs)
        self.assertEqual(problems, [], "\n".join(problems))


class PublishableTest(unittest.TestCase):
    def test_blocks_while_g4_placeholders_remain(self):
        config = build_site.load_config()
        outputs = build_site.build_all(config)
        legal = [(p, c) for p, c in outputs.items() if p.endswith(("privacy.html", "terms.html"))]
        index = outputs[os.path.join(build_site.SITE_OUT_DIR, "index.html")]
        problems = build_site.check_publishable(config, index, legal)
        self.assertTrue(any("プレースホルダ" in p for p in problems), problems)

    def test_blocks_when_x_url_is_missing(self):
        config = build_site.load_config()
        outputs = build_site.build_all(config)
        legal = [(p, c) for p, c in outputs.items() if p.endswith(("privacy.html", "terms.html"))]
        index = outputs[os.path.join(build_site.SITE_OUT_DIR, "index.html")]
        problems = build_site.check_publishable(config, index, legal)
        self.assertTrue(any("xUrl" in p for p in problems), problems)

    def test_passes_when_everything_is_filled_in(self):
        config = default_config(xUrl="https://x.com/example")
        filled = [("privacy.html", "<p>制定日: 2026年1月1日</p>"), ("terms.html", "<p>制定日: 2026年1月1日</p>")]
        self.assertEqual(build_site.check_publishable(config, "<p>ok</p>", filled), [])

    def test_blocks_http_links(self):
        config = default_config(xUrl="https://x.com/example")
        problems = build_site.check_publishable(config, '<a href="http://example.com">x</a>', [])
        self.assertTrue(any("http://" in p for p in problems), problems)


class ConfigTest(unittest.TestCase):
    def test_site_json_has_the_required_keys(self):
        with open(build_site.CONFIG_PATH, encoding="utf-8") as handle:
            config = json.load(handle)
        for key in ("baseUrl", "xUrl", "appStoreUrl", "contactEmail", "statusLabel"):
            self.assertIn(key, config)

    def test_base_url_matches_the_app_support_links(self):
        """アプリの SupportLinks.webBaseURL と、配信する土台を一致させる(審査で開く URL の正本)。"""
        with open(build_site.CONFIG_PATH, encoding="utf-8") as handle:
            config = json.load(handle)
        swift = os.path.join(
            build_site.PRODUCT_DIR, "ios", "Lien", "Core", "SupportLinks.swift"
        )
        with open(swift, encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn(f'static let webBaseURL = "{config["baseUrl"]}"', source)

    def test_missing_key_raises(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as handle:
            json.dump({"baseUrl": "https://example.com"}, handle)
            path = handle.name
        try:
            with self.assertRaises(ValueError):
                build_site.load_config(path)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
