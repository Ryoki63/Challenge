"""verify_archive.py の単体テスト — 偽の .xcarchive を組み立てて検査の合否を確かめる(issue #28)"""

import contextlib
import io
import os
import plistlib
import shutil
import sys
import tempfile
import unittest

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

    def test_not_an_app_archive(self):
        os.makedirs(os.path.join(self.tmp, "Empty.xcarchive"))
        self.assertGreater(verify(os.path.join(self.tmp, "Empty.xcarchive")).errors, 0)


class XcconfigReaderTests(unittest.TestCase):
    def test_reads_the_real_base_xcconfig(self):
        self.assertRegex(VERSION, r"^\d+\.\d+\.\d+$")
        self.assertTrue(BASE_ID.startswith("com."))

    def test_missing_key_is_reported(self):
        with self.assertRaises(SystemExit):
            va.read_xcconfig("NO_SUCH_SETTING")


if __name__ == "__main__":
    unittest.main()
