"""scan_required_reason_apis.py の単体テスト — nm / strings の出力を差し替えて、--strict-symbols の合否を固定する(issue #66)

lien-release が「ITMS-91053(必須理由 API の宣言漏れ)で TestFlight に弾かれる前に止める」ための検査。本物のバイナリは使わず、
`nm -u`(未定義シンボル。macOS では 1 行 1 シンボルで、型の列は付かない)と `strings -a` の出力を、実行ファイルの名前ごとに
差し替える。偽の .app は、アプリ本体・拡張(PlugIns)・フレームワークの実行ファイルと PrivacyInfo.xcprivacy だけを持つ。
"""

import contextlib
import io
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scan_required_reason_apis as scan  # noqa: E402

REASON = "35F9.1"


def declared(*categories):
    """マニフェストの NSPrivacyAccessedAPITypes。カテゴリは短い名前(SystemBootTime など)"""
    return {
        "NSPrivacyTracking": False,
        "NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": scan.PREFIX + name, "NSPrivacyAccessedAPITypeReasons": [REASON]}
            for name in categories
        ],
    }


def write_bundle(bundle, executable, manifest):
    os.makedirs(bundle, exist_ok=True)
    if executable:
        with open(os.path.join(bundle, executable), "wb") as fh:
            fh.write(b"\x00")  # 中身は読まない(nm / strings を差し替える)
    if manifest is not None:
        with open(os.path.join(bundle, "PrivacyInfo.xcprivacy"), "wb") as fh:
            plistlib.dump(manifest, fh)


def make_app(root, app=None, widget=None, nse=None, frameworks=None):
    """偽の Lien.app を作る。引数はそれぞれのバンドルのマニフェスト(None = マニフェストなし)。
    frameworks は {名前: マニフェスト or None}"""
    path = os.path.join(root, "Lien.app")
    write_bundle(path, "Lien", app)
    write_bundle(os.path.join(path, "PlugIns", "LienWidget.appex"), "LienWidget", widget)
    write_bundle(os.path.join(path, "PlugIns", "LienNSE.appex"), "LienNSE", nse)
    for name, manifest in (frameworks or {}).items():
        write_bundle(os.path.join(path, "Frameworks", name + ".framework"), name, manifest)
    return path


class FakeTools:
    """subprocess の差し替え。実行ファイルの名前(Lien・LienWidget …)ごとに nm -u / strings -a の出力(行のリスト)を返す"""

    def __init__(self, symbols=None, strings=None):
        self.symbols = symbols or {}
        self.strings = strings or {}

    def __call__(self, cmd):
        tool, executable = cmd[0], os.path.basename(cmd[-1])
        table = {"nm": self.symbols, "strings": self.strings}[tool]
        return "\n".join(table.get(executable, [])) + "\n"


class ScanTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def scan(self, app, tools, *flags):
        """main() を走らせて (終了コード, 標準出力) を返す"""
        out = io.StringIO()
        with mock.patch.object(scan, "run", tools), contextlib.redirect_stdout(out):
            code = scan.main([app, *flags])
        return code, out.getvalue()


class StrictSymbolsTests(ScanTestCase):
    def test_undeclared_symbol_fails_in_strict_mode(self):
        app = make_app(self.tmp, app=declared())
        code, out = self.scan(app, FakeTools(symbols={"Lien": ["_mach_absolute_time"]}), "--strict-symbols")
        self.assertEqual(code, 1, out)
        self.assertIn("::error::", out)
        self.assertIn("### 宣言が足りない可能性が高いもの(シンボル)", out)
        self.assertIn("- Lien: SystemBootTime ← _mach_absolute_time", out)

    def test_declared_symbol_passes_in_strict_mode(self):
        app = make_app(self.tmp, app=declared("SystemBootTime"))
        code, out = self.scan(app, FakeTools(symbols={"Lien": ["_mach_absolute_time"]}), "--strict-symbols")
        self.assertEqual(code, 0, out)
        self.assertNotIn("::error::", out)
        self.assertNotIn("宣言が足りない可能性が高いもの", out)

    def test_undeclared_symbol_is_only_reported_without_strict_mode(self):
        app = make_app(self.tmp, app=declared())
        code, out = self.scan(app, FakeTools(symbols={"Lien": ["_mach_absolute_time"]}))
        self.assertEqual(code, 0, out)
        self.assertNotIn("::error::", out)
        self.assertIn("- Lien: SystemBootTime ← _mach_absolute_time", out)

    def test_symbols_with_a_variant_suffix_are_detected(self):
        # `_stat$INODE64` のように `$` 以降が付く形も、C の関数そのものとして数える
        app = make_app(self.tmp, app=declared())
        code, out = self.scan(app, FakeTools(symbols={"Lien": ["_stat$INODE64", "_fstat$INODE64"]}), "--strict-symbols")
        self.assertEqual(code, 1, out)
        self.assertIn("FileTimestamp ← _fstat$INODE64 _stat$INODE64", out)

    def test_every_file_timestamp_and_disk_space_function_is_covered(self):
        cases = {
            "FileTimestamp": ["_stat", "_fstat", "_lstat", "_fstatat", "_getattrlist", "_fgetattrlist", "_getattrlistat",
                              "_getattrlistbulk"],
            "DiskSpace": ["_statfs", "_statvfs", "_fstatfs", "_fstatvfs"],
            "SystemBootTime": ["_mach_absolute_time"],
        }
        for category, symbols in cases.items():
            for symbol in symbols:
                with self.subTest(symbol=symbol):
                    root = tempfile.mkdtemp(dir=self.tmp)
                    app = make_app(root, app=declared())
                    code, out = self.scan(app, FakeTools(symbols={"Lien": [symbol]}), "--strict-symbols")
                    self.assertEqual(code, 1, out)
                    self.assertIn(f"- Lien: {category} ← {symbol}", out)

    def test_similar_looking_symbols_are_not_detected(self):
        app = make_app(self.tmp, app=declared())
        similar = ["_statistics", "_stat_helper", "_mach_absolute_time_nsec", "__stat", "_fstatx", "_my_statfs"]
        code, out = self.scan(app, FakeTools(symbols={"Lien": similar}), "--strict-symbols")
        self.assertEqual(code, 0, out)
        self.assertIn("- 検出なし", out)

    def test_fat_binary_headers_in_the_nm_output_are_ignored(self):
        app = make_app(self.tmp, app=declared())
        nm = ["", "Lien.app/Lien (for architecture arm64):", "_exit", "dyld_stub_binder"]
        code, out = self.scan(app, FakeTools(symbols={"Lien": nm}), "--strict-symbols")
        self.assertEqual(code, 0, out)

    def test_strings_only_detection_never_fails(self):
        # 文字列だけ(Swift / Objective-C のメタデータに出る API 名)は確度が低いので、表に出すだけ
        app = make_app(self.tmp, app=declared())
        tools = FakeTools(strings={"Lien": ["systemUptime", "attributesOfItemAtPath:error:", "volumeAvailableCapacity"]})
        code, out = self.scan(app, tools, "--strict-symbols")
        self.assertEqual(code, 0, out)
        self.assertNotIn("::error::", out)
        self.assertIn("低(文字列)", out)
        self.assertIn("`attributesOfItem` の出どころ: `attributesOfItemAtPath:error:`", out)

    def test_user_defaults_strings_are_not_traced_to_their_origin(self):
        # 自前のコードが使っているので、出どころは出さない(PrivacyManifestTests がソースから宣言を検査する)
        app = make_app(self.tmp, app=declared("UserDefaults"))
        code, out = self.scan(app, FakeTools(strings={"Lien": ["NSUserDefaults", "UserDefaults"]}), "--strict-symbols")
        self.assertEqual(code, 0, out)
        self.assertIn("UserDefaults | 低(文字列)", out)
        self.assertNotIn("の出どころ", out)


class WhichBundleMustDeclareTests(ScanTestCase):
    def test_the_bundle_that_uses_the_symbol_must_declare_it_itself(self):
        # アプリ本体が宣言していても、シンボルを使っているのが拡張なら、拡張のマニフェストに無ければ失敗
        app = make_app(self.tmp, app=declared("DiskSpace"), widget=declared())
        code, out = self.scan(app, FakeTools(symbols={"LienWidget": ["_statfs"]}), "--strict-symbols")
        self.assertEqual(code, 1, out)
        self.assertIn("- LienWidget: DiskSpace ← _statfs", out)
        self.assertIn("| DiskSpace | 高(シンボル) | `_statfs` | **いいえ** | はい |", out)

    def test_declaring_in_the_extension_itself_passes(self):
        app = make_app(self.tmp, app=declared(), widget=declared("DiskSpace"))
        code, out = self.scan(app, FakeTools(symbols={"LienWidget": ["_statfs"]}), "--strict-symbols")
        self.assertEqual(code, 0, out)

    def test_each_category_is_checked_on_its_own(self):
        app = make_app(self.tmp, app=declared("SystemBootTime"))
        tools = FakeTools(symbols={"Lien": ["_mach_absolute_time", "_statfs"]})
        code, out = self.scan(app, tools, "--strict-symbols")
        self.assertEqual(code, 1, out)
        self.assertIn("- Lien: DiskSpace ← _statfs", out)
        self.assertNotIn("- Lien: SystemBootTime", out)

    def test_an_embedded_framework_is_scanned_with_its_own_manifest(self):
        app = make_app(self.tmp, app=declared("SystemBootTime"), frameworks={"Supa": None})
        code, out = self.scan(app, FakeTools(symbols={"Supa": ["_mach_absolute_time"]}), "--strict-symbols")
        self.assertEqual(code, 1, out)
        self.assertIn("- Supa: SystemBootTime ← _mach_absolute_time", out)

    def test_a_bundle_without_its_executable_is_skipped(self):
        app = make_app(self.tmp, app=declared())
        os.remove(os.path.join(app, "PlugIns", "LienNSE.appex", "LienNSE"))
        names = [name for name, _bundle, _exe in scan.find_executables(app)]
        self.assertEqual(names, ["Lien", "LienWidget"])

    def test_executables_are_found_in_the_app_plugins_and_frameworks(self):
        app = make_app(self.tmp, app=declared(), frameworks={"Supa": None, "Crypto": None})
        names = [name for name, _bundle, _exe in scan.find_executables(app)]
        self.assertEqual(names, ["Lien", "LienNSE", "LienWidget", "Crypto", "Supa"])


class ManifestReadingTests(ScanTestCase):
    def test_a_broken_manifest_is_unreadable_and_counts_as_undeclared(self):
        app = make_app(self.tmp, app=declared("SystemBootTime"))
        with open(os.path.join(app, "PrivacyInfo.xcprivacy"), "wb") as fh:
            fh.write(b"this is not a plist")
        self.assertIsNone(scan.read_manifest(os.path.join(app, "PrivacyInfo.xcprivacy")))
        code, out = self.scan(app, FakeTools(symbols={"Lien": ["_mach_absolute_time"]}), "--strict-symbols")
        self.assertEqual(code, 1, out)
        self.assertIn("PrivacyInfo.xcprivacy`: 読めません", out)

    def test_a_missing_manifest_counts_as_undeclared(self):
        app = make_app(self.tmp, app=None)
        self.assertIsNone(scan.read_manifest(os.path.join(app, "PrivacyInfo.xcprivacy")))
        code, out = self.scan(app, FakeTools(symbols={"Lien": ["_mach_absolute_time"]}), "--strict-symbols")
        self.assertEqual(code, 1, out)

    def test_declared_categories_and_reasons_are_read(self):
        app = make_app(self.tmp, app=declared("SystemBootTime", "DiskSpace"))
        manifest = scan.read_manifest(os.path.join(app, "PrivacyInfo.xcprivacy"))
        self.assertEqual(
            manifest,
            {scan.PREFIX + "SystemBootTime": [REASON], scan.PREFIX + "DiskSpace": [REASON]},
        )

    def test_a_manifest_without_api_types_declares_nothing(self):
        app = make_app(self.tmp, app={"NSPrivacyTracking": False})
        self.assertEqual(scan.read_manifest(os.path.join(app, "PrivacyInfo.xcprivacy")), {})


class InputErrorTests(ScanTestCase):
    def test_a_missing_app_is_an_input_error_not_a_pass(self):
        code, out = self.scan(os.path.join(self.tmp, "Nothing.app"), FakeTools(), "--strict-symbols")
        self.assertEqual(code, 2, out)
        self.assertIn("::error::", out)

    def test_a_trailing_slash_on_the_app_path_is_accepted(self):
        app = make_app(self.tmp, app=declared())
        code, out = self.scan(app + "/", FakeTools(), "--strict-symbols")
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
