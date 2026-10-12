"""verify_archive.py の単体テスト — 偽の .xcarchive を組み立てて検査の合否を確かめる(issue #28)"""

import contextlib
import io
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import verify_archive as va  # noqa: E402

BASE_ID = va.read_xcconfig("LIEN_BUNDLE_ID_BASE")
VERSION = va.read_xcconfig("MARKETING_VERSION")
GOOD_URL = "https://lniheehfbtpfhglinfjm.supabase.co"
GOOD_KEY = "sb_publishable_AbCdEfGhIjKlMnOpQrStUvWx_1234"
MANIFEST = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
            "NSPrivacyAccessedAPITypes": []}


def write_plist(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        plistlib.dump(data, fh)


def app_info(build="42", **overrides):
    info = {
        "CFBundleIdentifier": BASE_ID, "CFBundleShortVersionString": VERSION, "CFBundleVersion": build,
        "MinimumOSVersion": "17.0", "ITSAppUsesNonExemptEncryption": False,
        "DTSDKName": "iphoneos26.5", "DTXcode": "2660",
        "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}},
        "SUPABASE_URL": GOOD_URL, "SUPABASE_ANON_KEY": GOOD_KEY,
    }
    info.update(overrides)
    return info


def ext_info(suffix, point, build="42"):
    return {
        "CFBundleIdentifier": f"{BASE_ID}.{suffix}", "CFBundleShortVersionString": VERSION, "CFBundleVersion": build,
        "MinimumOSVersion": "17.0", "NSExtension": {"NSExtensionPointIdentifier": point},
    }


def make_archive(root, **kwargs):
    archive = os.path.join(root, "Lien.xcarchive")
    app = os.path.join(archive, "Products", "Applications", "Lien.app")
    write_plist(os.path.join(app, "Info.plist"), kwargs.get("app") or app_info())
    write_plist(os.path.join(app, "PrivacyInfo.xcprivacy"), MANIFEST)
    open(os.path.join(app, "Assets.car"), "wb").close()
    for name, suffix, point in (
        ("LienWidget", "widget", "com.apple.widgetkit-extension"),
        ("LienNSE", "nse", "com.apple.usernotifications.service"),
    ):
        bundle = os.path.join(app, "PlugIns", f"{name}.appex")
        write_plist(os.path.join(bundle, "Info.plist"), ext_info(suffix, point, kwargs.get("ext_build", "42")))
        if name not in kwargs.get("skip_manifest", ()):
            write_plist(os.path.join(bundle, "PrivacyInfo.xcprivacy"), MANIFEST)
    os.makedirs(os.path.join(archive, "dSYMs", "Lien.app.dSYM"))
    return archive


def verify(archive, build="42", supabase="strict"):
    with contextlib.redirect_stdout(io.StringIO()):
        return va.verify(archive, build, supabase, signed=False)


class VerifyArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_good_archive_has_no_errors(self):
        report = verify(make_archive(self.tmp))
        self.assertEqual(report.errors, 0, report.markdown())

    def test_build_number_must_match_in_every_bundle(self):
        self.assertGreater(verify(make_archive(self.tmp), build="43").errors, 0)
        other = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, other, ignore_errors=True)
        self.assertGreater(verify(make_archive(other, ext_build="41")).errors, 0, "拡張だけ版がずれている")

    def test_sdk_older_than_26_is_an_error(self):
        report = verify(make_archive(self.tmp, app=app_info(DTSDKName="iphoneos18.5")))
        self.assertGreater(report.errors, 0)
        self.assertIn("iOS 26 SDK 未満", report.markdown())

    def test_missing_privacy_manifest_in_an_extension_is_an_error(self):
        report = verify(make_archive(self.tmp, skip_manifest=("LienNSE",)))
        self.assertGreater(report.errors, 0)

    def test_encryption_flag_and_min_os_are_checked(self):
        self.assertGreater(verify(make_archive(self.tmp, app=app_info(ITSAppUsesNonExemptEncryption=True))).errors, 0)

    def test_missing_supabase_config_is_error_when_strict_and_warning_otherwise(self):
        info = app_info(SUPABASE_URL="", SUPABASE_ANON_KEY="")
        archive = make_archive(self.tmp, app=info)
        self.assertGreater(verify(archive, supabase="strict").errors, 0)
        report = verify(archive, supabase="warn")
        self.assertEqual(report.errors, 0, report.markdown())
        self.assertGreater(report.warnings, 0)

    def test_service_role_key_is_an_error_even_in_warn_mode(self):
        key = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.c2ln"  # {"role":"service_role"}
        archive = make_archive(self.tmp, app=app_info(SUPABASE_ANON_KEY=key))
        self.assertGreater(verify(archive, supabase="warn").errors, 0)

    @unittest.skipUnless(shutil.which("strings"), "strings コマンドが必要")
    def test_debug_only_code_in_the_binary_is_an_error(self):
        archive = make_archive(self.tmp)
        binary = os.path.join(archive, "Products", "Applications", "Lien.app", "Lien")
        with open(binary, "wb") as fh:
            fh.write(b"\x00\x01 plain release binary with no debug types \x00")
        self.assertEqual(verify(archive).errors, 0)
        with open(binary, "wb") as fh:
            fh.write(b"\x00\x01 $s4Lien20DeviceTokenDebugViewV \x00")
        report = verify(archive)
        self.assertGreater(report.errors, 0)
        self.assertIn("DeviceTokenDebugView", report.markdown())

    def test_not_an_app_archive(self):
        os.makedirs(os.path.join(self.tmp, "Empty.xcarchive"))
        self.assertGreater(verify(os.path.join(self.tmp, "Empty.xcarchive")).errors, 0)


class SignedArchiveTests(unittest.TestCase):
    """署名済みの archive の検査(--signed)。dry-run では通らない経路なので、codesign の呼び方と出力の読み方をここで固定する
    (旧来の `--entitlements :-` は非推奨の構文。現行は `--entitlements - --xml` — issue #66)"""

    GOOD = {
        "com.apple.security.application-groups": ["group.com.example.lien"],
        "aps-environment": "development",
    }

    @staticmethod
    def plist_text(data):
        return plistlib.dumps(data).decode("utf-8")

    def fake_codesign(self, entitlements_output="", verify_code=0):
        """subprocess.run の差し替え。--verify と -d で返すものを分ける。呼ばれた引数は self.calls に残す"""
        self.calls = []

        def run(args, **kwargs):
            self.calls.append(list(args))
            if "--verify" in args:
                return subprocess.CompletedProcess(
                    args, verify_code, stdout="", stderr="" if verify_code == 0 else "invalid signature")
            return subprocess.CompletedProcess(
                args, 0, stdout=entitlements_output, stderr="Executable=/x/Lien.app/Lien\n")

        return run

    def check(self, entitlements_output, verify_code=0):
        report = va.Report()
        with contextlib.redirect_stdout(io.StringIO()):
            with mock.patch.object(va.subprocess, "run", side_effect=self.fake_codesign(entitlements_output, verify_code)):
                va.check_signed(report, "/x/Lien.app")
        return report

    def test_entitlements_are_requested_with_the_current_syntax(self):
        with mock.patch.object(va.subprocess, "run", side_effect=self.fake_codesign(self.plist_text(self.GOOD))):
            entitlements = va.read_entitlements("/x/Lien.app")
        self.assertEqual(self.calls, [["codesign", "-d", "--entitlements", "-", "--xml", "/x/Lien.app"]])
        self.assertEqual(entitlements, self.GOOD)
        self.assertFalse([arg for call in self.calls for arg in call if arg.startswith(":")], "非推奨の ':-' は使わない")

    def test_good_entitlements_have_no_errors_or_warnings(self):
        report = self.check(self.plist_text(self.GOOD))
        self.assertEqual((report.errors, report.warnings), (0, 0), report.markdown())
        self.assertIn("aps-environment", report.markdown())

    def test_missing_aps_environment_is_an_error(self):
        report = self.check(self.plist_text({"com.apple.security.application-groups": ["group.com.example.lien"]}))
        self.assertEqual(report.errors, 1, report.markdown())
        self.assertIn("aps-environment", report.markdown())

    def test_missing_app_group_is_an_error(self):
        report = self.check(self.plist_text({"aps-environment": "development"}))
        self.assertEqual(report.errors, 1, report.markdown())
        self.assertIn("App Group", report.markdown())

    def test_output_that_is_not_a_plist_is_only_a_warning(self):
        # `--xml` を付けないときの、人向けの整形。plist ではないので読めない扱い(エラーにはしない)
        pretty = "[Dict]\n\t[Key] aps-environment\n\t[Value]\n\t\t[String] development\n"
        report = self.check(pretty)
        self.assertEqual((report.errors, report.warnings), (0, 1), report.markdown())
        with mock.patch.object(va.subprocess, "run", side_effect=self.fake_codesign(pretty)):
            self.assertEqual(va.read_entitlements("/x/Lien.app"), {})

    def test_no_output_is_only_a_warning(self):
        report = self.check("")
        self.assertEqual((report.errors, report.warnings), (0, 1), report.markdown())

    def test_failed_verify_is_only_a_warning(self):
        report = self.check(self.plist_text(self.GOOD), verify_code=1)
        self.assertEqual((report.errors, report.warnings), (0, 1), report.markdown())

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("codesign"), "macOS の codesign が必要")
    def test_real_codesign_returns_the_entitlements_as_a_plist(self):
        # 本物の codesign で確かめる(macOS のランナーで走る)。ad-hoc 署名した実行ファイルから、署名したエンタイトルメントが戻ること
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        target = os.path.join(tmp, "Lien")
        shutil.copy("/usr/bin/true", target)
        write_plist(os.path.join(tmp, "entitlements.plist"), self.GOOD)
        signed = subprocess.run(
            ["codesign", "--force", "-s", "-", "--entitlements", os.path.join(tmp, "entitlements.plist"), target],
            capture_output=True, text=True)
        if signed.returncode != 0:
            self.skipTest(f"この環境では ad-hoc 署名ができない: {signed.stderr.strip()[:200]}")
        self.assertEqual(va.read_entitlements(target), self.GOOD)


class XcconfigReaderTests(unittest.TestCase):
    def test_reads_the_real_base_xcconfig(self):
        self.assertRegex(VERSION, r"^\d+\.\d+\.\d+$")
        self.assertTrue(BASE_ID.startswith("com."))

    def test_missing_key_is_reported(self):
        with self.assertRaises(SystemExit):
            va.read_xcconfig("NO_SUCH_SETTING")


if __name__ == "__main__":
    unittest.main()
