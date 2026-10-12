"""supabase_config.py の単体テスト(python3 -m unittest。CI の lien-ios でも回す — issue #28)"""

import base64
import contextlib
import io
import json
import os
import plistlib
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import supabase_config as sc  # noqa: E402


def b64url(obj):
    raw = json.dumps(obj).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def jwt(role):
    return ".".join([b64url({"alg": "HS256", "typ": "JWT"}), b64url({"iss": "supabase", "role": role}), "c2lnbmF0dXJl"])


GOOD_URL = "https://lniheehfbtpfhglinfjm.supabase.co"
GOOD_KEY = "sb_publishable_AbCdEfGhIjKlMnOpQrStUvWx_1234"


def run_main(argv, env=None):
    """main を呼び、(終了コード, 標準出力) を返す。環境変数は一時的に差し替える"""
    saved = {k: os.environ.get(k) for k in ("SUPABASE_URL", "SUPABASE_ANON_KEY", "GITHUB_ACTIONS")}
    try:
        for k in saved:
            os.environ.pop(k, None)
        os.environ.update(env or {})
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = sc.main(argv)
        return code, buf.getvalue()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


class ValidateUrlTests(unittest.TestCase):
    def test_accepts_supabase_url_with_or_without_trailing_slash(self):
        self.assertEqual(sc.validate_url(GOOD_URL), ([], []))
        self.assertEqual(sc.validate_url(GOOD_URL + "/"), ([], []))

    def test_rejects_unset_values(self):
        for value in ("", "   ", "$(SUPABASE_URL)", "https://YOUR-PROJECT-REF.supabase.co"):
            errors, _ = sc.validate_url(value)
            self.assertTrue(errors, value)

    def test_rejects_non_https_and_paths(self):
        self.assertTrue(sc.validate_url("http://lniheehfbtpfhglinfjm.supabase.co")[0])
        self.assertTrue(sc.validate_url(GOOD_URL + "/rest/v1")[0])
        self.assertTrue(sc.validate_url(GOOD_URL + "?a=1")[0])
        self.assertTrue(sc.validate_url("https://localhost")[0], "ドットの無いホスト名")

    def test_warns_when_host_is_not_supabase_co(self):
        errors, warnings = sc.validate_url("https://api.example.com")
        self.assertEqual(errors, [])
        self.assertTrue(warnings)


class ValidateAnonKeyTests(unittest.TestCase):
    def test_accepts_publishable_and_anon_jwt(self):
        self.assertEqual(sc.validate_anon_key(GOOD_KEY), ([], []))
        self.assertEqual(sc.validate_anon_key(jwt("anon")), ([], []))

    def test_secret_and_service_role_keys_are_dangerous(self):
        for value in ("sb_secret_" + "A" * 30, jwt("service_role")):
            errors, _ = sc.validate_anon_key(value)
            self.assertTrue(errors and all(e.startswith(sc.DANGER) for e in errors), value[:12])

    def test_other_jwt_roles_are_errors(self):
        errors, _ = sc.validate_anon_key(jwt("authenticated"))
        self.assertTrue(errors)

    def test_rejects_unset_short_and_odd_characters(self):
        for value in ("", "$(SUPABASE_ANON_KEY)", "YOUR_SUPABASE_ANON_KEY", "short", "has space key 0123456789abcdef"):
            self.assertTrue(sc.validate_anon_key(value)[0], value)

    def test_unknown_long_format_is_only_a_warning(self):
        errors, warnings = sc.validate_anon_key("abcdefghijklmnopqrstuvwxyz0123456789")
        self.assertEqual(errors, [])
        self.assertTrue(warnings)


class XcconfigTests(unittest.TestCase):
    def test_slashes_are_escaped_for_xcconfig(self):
        self.assertEqual(sc.xcconfig_escape("https://x.supabase.co"), "https:/$()/x.supabase.co")

    def test_render_strips_trailing_slash_and_escapes(self):
        text = sc.render_xcconfig(GOOD_URL + "/", GOOD_KEY)
        self.assertIn("SUPABASE_URL = https:/$()/lniheehfbtpfhglinfjm.supabase.co\n", text)
        self.assertIn(f"SUPABASE_ANON_KEY = {GOOD_KEY}\n", text)

    def test_write_xcconfig_writes_a_private_file_and_hides_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "Secrets.xcconfig")
            code, stdout = run_main(
                ["write-xcconfig", "--out", out], {"SUPABASE_URL": GOOD_URL, "SUPABASE_ANON_KEY": GOOD_KEY}
            )
            self.assertEqual(code, 0)
            self.assertNotIn(GOOD_KEY, stdout)
            self.assertNotIn("supabase.co", stdout)
            self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)
            with open(out, encoding="utf-8") as fh:
                self.assertIn("SUPABASE_URL = https:/$()/", fh.read())

    def test_write_xcconfig_refuses_bad_values_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "Secrets.xcconfig")
            code, _ = run_main(
                ["write-xcconfig", "--out", out], {"SUPABASE_URL": GOOD_URL, "SUPABASE_ANON_KEY": jwt("service_role")}
            )
            self.assertEqual(code, 1)
            self.assertFalse(os.path.exists(out))
            code, _ = run_main(["write-xcconfig", "--out", out], {})
            self.assertEqual(code, 1, "環境変数が無い")
            self.assertFalse(os.path.exists(out))


class CheckPlistTests(unittest.TestCase):
    def check(self, info, *flags):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "Info.plist")
            with open(path, "wb") as fh:
                plistlib.dump(info, fh)
            return run_main(["check-plist", path, *flags])

    def test_good_values_pass(self):
        code, stdout = self.check({"SUPABASE_URL": GOOD_URL, "SUPABASE_ANON_KEY": GOOD_KEY})
        self.assertEqual(code, 0)
        self.assertNotIn(GOOD_KEY, stdout)

    def test_missing_values_fail_unless_warn_only(self):
        for info in ({}, {"SUPABASE_URL": "", "SUPABASE_ANON_KEY": ""}, {"SUPABASE_URL": "$(SUPABASE_URL)"}):
            self.assertEqual(self.check(info)[0], 1, info)
            self.assertEqual(self.check(info, "--warn-only")[0], 0, info)

    def test_service_role_key_fails_even_when_warn_only(self):
        info = {"SUPABASE_URL": GOOD_URL, "SUPABASE_ANON_KEY": jwt("service_role")}
        self.assertEqual(self.check(info)[0], 1)
        self.assertEqual(self.check(info, "--warn-only")[0], 1)


if __name__ == "__main__":
    unittest.main()
