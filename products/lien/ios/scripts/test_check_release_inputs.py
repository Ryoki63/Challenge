"""check_release_inputs.py の単体テスト — 運営者の連絡先と法務ページの公開が、リリース前に確かめられることを固定する(issue #23)"""

import contextlib
import io
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_release_inputs as cri  # noqa: E402

SAMPLE = r'''
enum SupportLinks {
    static let webBaseURL = "https://example.github.io/Challenge"
    static let termsURL: URL = url("\(webBaseURL)/lien/legal/terms.html")
    static let privacyURL: URL = url("\(webBaseURL)/lien/legal/privacy.html")
    static let contactEmail = "%s"
}
'''
TERMS = "https://example.github.io/Challenge/lien/legal/terms.html"
PRIVACY = "https://example.github.io/Challenge/lien/legal/privacy.html"


def sample(email):
    return SAMPLE % email


def fetch_all(status):
    return lambda url: status


class ParseTests(unittest.TestCase):
    def test_reads_the_email_and_expands_the_legal_urls(self):
        email, terms, privacy = cri.parse_support_links(sample("support@example.com"))
        self.assertEqual(email, "support@example.com")
        self.assertEqual(terms, TERMS)
        self.assertEqual(privacy, PRIVACY)

    def test_an_empty_email_is_empty(self):
        self.assertEqual(cri.parse_support_links(sample(""))[0], "")
        self.assertEqual(cri.parse_support_links(sample("  "))[0], "")

    def test_an_unreadable_file_is_an_error_not_a_pass(self):
        with self.assertRaises(ValueError):
            cri.parse_support_links("enum SupportLinks {}")

    def test_the_real_support_links_file_is_readable(self):
        # 書式が変わって正規表現が読めなくなったら、ここで落ちる(黙って素通りしない)
        with open(cri.DEFAULT_SUPPORT_LINKS, encoding="utf-8") as fh:
            email, terms, privacy = cri.parse_support_links(fh.read())
        self.assertTrue(terms.startswith("https://") and terms.endswith("terms.html"), terms)
        self.assertTrue(privacy.startswith("https://") and privacy.endswith("privacy.html"), privacy)
        self.assertNotIn("webBaseURL", terms + privacy, "補間が展開されている")
        self.assertIsInstance(email, str)


class CheckTests(unittest.TestCase):
    def test_everything_in_place_passes(self):
        rows = cri.check("support@example.com", TERMS, PRIVACY, fetch_all(200))
        self.assertTrue(all(ok for ok, _, _ in rows))
        self.assertEqual(len(rows), 3)

    def test_an_empty_contact_fails(self):
        rows = cri.check("", TERMS, PRIVACY, fetch_all(200))
        ok, item, detail = rows[0]
        self.assertFalse(ok)
        self.assertEqual(item, "運営者の連絡先")
        self.assertIn("contactEmail", detail)

    def test_a_malformed_contact_fails(self):
        for bad in ["support", "support@", "@example.com", "support@example", "a b@example.com"]:
            rows = cri.check(bad, TERMS, PRIVACY, fetch_all(200))
            self.assertFalse(rows[0][0], bad)
        for good in ["support@example.com", "first.last+lien@sub.example.co.jp"]:
            self.assertTrue(cri.check(good, TERMS, PRIVACY, fetch_all(200))[0][0], good)

    def test_a_legal_page_that_is_not_published_fails(self):
        # 2026-10-13 時点の実態: Pages 未公開で 404
        rows = cri.check("support@example.com", TERMS, PRIVACY, fetch_all(404))
        self.assertTrue(rows[0][0])
        self.assertFalse(rows[1][0])
        self.assertFalse(rows[2][0])
        self.assertIn("HTTP 404", rows[1][2])

    def test_only_the_unpublished_page_fails(self):
        rows = cri.check("support@example.com", TERMS, PRIVACY, lambda url: 200 if url == TERMS else 404)
        self.assertEqual([ok for ok, _, _ in rows], [True, True, False])

    def test_a_network_failure_fails_rather_than_passing(self):
        rows = cri.check("support@example.com", TERMS, PRIVACY, fetch_all(None))
        self.assertFalse(rows[1][0])
        self.assertIn("確かめられませんでした", rows[1][2])

    def test_a_redirect_target_or_server_error_is_not_ok(self):
        for status in (301, 403, 500, 503):
            rows = cri.check("support@example.com", TERMS, PRIVACY, fetch_all(status))
            self.assertFalse(rows[1][0], status)


class MainTests(unittest.TestCase):
    def run_main(self, email, fetch, *extra):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "SupportLinks.swift")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(sample(email))
            summary = os.path.join(directory, "summary.md")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = cri.main(["--support-links", path, "--summary", summary, *extra], fetch=fetch)
            with open(summary, encoding="utf-8") as fh:
                return code, output.getvalue(), fh.read()

    def test_require_stops_the_release_when_something_is_missing(self):
        code, output, summary = self.run_main("", fetch_all(404), "--require")
        self.assertEqual(code, 1)
        self.assertIn("::error::運営者の連絡先", output)
        self.assertIn("リリースを止めます", summary)
        self.assertIn("internal_only", summary)

    def test_without_require_it_only_warns(self):
        code, output, summary = self.run_main("", fetch_all(404))
        self.assertEqual(code, 0, "dry-run では止めない")
        self.assertIn("::warning::運営者の連絡先", output)
        self.assertNotIn("::error::", output)
        self.assertIn("外部テスト・審査には使えません", summary)

    def test_require_passes_when_everything_is_in_place(self):
        code, output, summary = self.run_main("support@example.com", fetch_all(200), "--require")
        self.assertEqual(code, 0)
        self.assertNotIn("::error::", output)
        self.assertIn("すべて揃っています", summary)

    def test_an_unparseable_file_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "SupportLinks.swift")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("enum SupportLinks {}")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = cri.main(["--support-links", path, "--require"], fetch=fetch_all(200))
        self.assertEqual(code, 2)
        self.assertIn("::error::", output.getvalue())


if __name__ == "__main__":
    unittest.main()
