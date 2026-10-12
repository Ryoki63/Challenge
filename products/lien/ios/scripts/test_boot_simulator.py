"""boot_simulator.py の単体テスト — simctl の出力を差し替えて、デバイスの選び方と起動の呼び方を固定する(issue #66)"""

import contextlib
import io
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import boot_simulator as bs  # noqa: E402


def device(name, udid, state="Shutdown", available=True):
    entry = {"name": name, "udid": udid, "state": state, "isAvailable": available}
    if not available:
        entry["availabilityError"] = "runtime profile not found"
    return entry


# `xcrun simctl list devices available --json` の形(必要な部分だけ)
LISTING = {
    "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
            device("iPhone 17", "UDID-18-5"), device("iPhone 16", "UDID-16-185"),
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [device("iPhone 17", "UDID-26-0")],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            device("iPhone 17", "UDID-26-5", state="Shutdown"), device("iPhone 17 Pro", "UDID-PRO-26-5"),
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [device("iPhone 17", "UDID-TV")],
    }
}


class ChooseDeviceTests(unittest.TestCase):
    def test_the_newest_ios_runtime_wins(self):
        self.assertEqual(bs.choose_device(LISTING, "iPhone 17"), ("UDID-26-5", "iOS 26.5", "Shutdown"))

    def test_versions_are_compared_as_numbers_not_text(self):
        listing = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-9-3": [device("iPhone 17", "UDID-9-3")],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [device("iPhone 17", "UDID-26-10")],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [device("iPhone 17", "UDID-26-5")],
        }}
        self.assertEqual(bs.choose_device(listing, "iPhone 17")[0], "UDID-26-10")

    def test_the_name_must_match_exactly(self):
        self.assertEqual(bs.choose_device(LISTING, "iPhone 17 Pro")[0], "UDID-PRO-26-5")
        self.assertEqual(bs.choose_device(LISTING, "iPhone 16")[0], "UDID-16-185")

    def test_other_platforms_are_ignored(self):
        listing = {"devices": {"com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [device("iPhone 17", "UDID-TV")]}}
        with self.assertRaises(LookupError):
            bs.choose_device(listing, "iPhone 17")

    def test_unavailable_devices_are_ignored(self):
        listing = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [device("iPhone 17", "UDID-BROKEN", available=False)],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [device("iPhone 17", "UDID-26-0")],
        }}
        self.assertEqual(bs.choose_device(listing, "iPhone 17")[0], "UDID-26-0")

    def test_a_missing_device_lists_what_exists(self):
        with self.assertRaises(LookupError) as caught:
            bs.choose_device(LISTING, "iPhone 99")
        message = str(caught.exception)
        self.assertIn("iPhone 99", message)
        self.assertIn("iPhone 17 Pro (iOS 26.5)", message)

    def test_the_current_state_is_reported(self):
        listing = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [device("iPhone 17", "U", state="Booted")]}}
        self.assertEqual(bs.choose_device(listing, "iPhone 17"), ("U", "iOS 26.5", "Booted"))

    def test_ios_version_parsing(self):
        self.assertEqual(bs.ios_version("com.apple.CoreSimulator.SimRuntime.iOS-26-5"), (26, 5))
        self.assertEqual(bs.ios_version("com.apple.CoreSimulator.SimRuntime.iOS-26"), (26,))
        self.assertIsNone(bs.ios_version("com.apple.CoreSimulator.SimRuntime.watchOS-11-0"))
        self.assertIsNone(bs.ios_version("something.else"))


class MainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.output = os.path.join(self.tmp, "output")
        self.summary = os.path.join(self.tmp, "summary.md")

    def read(self, path):
        if not os.path.exists(path):
            return ""
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def main(self, listing=LISTING, boot_code=0, seconds=123.4, extra=()):
        booted = []
        ticks = iter([1000.0, 1000.0 + seconds])

        def boot(udid):
            booted.append(udid)
            return boot_code

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = bs.main(
                ["iPhone 17", "--github-output", self.output, "--summary", self.summary, *extra],
                devices=lambda: listing, boot=boot, clock=lambda: next(ticks))
        self.booted = booted
        return code, out.getvalue()

    def test_boots_the_chosen_device_and_reports_the_time(self):
        code, out = self.main()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.booted, ["UDID-26-5"])
        self.assertIn("iPhone 17 (iOS 26.5)", out)
        self.assertIn("123 秒", out)
        self.assertEqual(self.read(self.output), "udid=UDID-26-5\nruntime=iOS 26.5\nboot_seconds=123\n")
        summary = self.read(self.summary)
        self.assertIn("## シミュレータの起動", summary)
        self.assertIn("| iPhone 17 (iOS 26.5) | Shutdown | 123 秒 |", summary)

    def test_a_failed_boot_is_an_error_and_writes_no_udid(self):
        code, out = self.main(boot_code=3)
        self.assertEqual(code, 1, out)
        self.assertIn("::error::", out)
        self.assertEqual(self.read(self.output), "")
        self.assertEqual(self.read(self.summary), "")

    def test_a_missing_device_is_an_error_and_boots_nothing(self):
        code, out = self.main(listing={"devices": {}})
        self.assertEqual(code, 1, out)
        self.assertIn("::error::", out)
        self.assertEqual(self.booted, [])

    def test_an_unreadable_listing_is_an_error(self):
        def broken():
            raise RuntimeError("simctl list が失敗しました: boom")

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = bs.main(["iPhone 17"], devices=broken, boot=lambda udid: 0)
        self.assertEqual(code, 1)
        self.assertIn("::error::simctl list が失敗しました", out.getvalue())

    def test_the_outputs_are_optional(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = bs.main(["iPhone 17"], devices=lambda: LISTING, boot=lambda udid: 0, clock=lambda: 0.0)
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
