"""install-xcodegen.sh のテスト — 偽の xcodegen.zip(file:// で渡す)で、SHA-256 の照合・版の確認・配置の検査を固定する(issue #66)

本物の XcodeGen はダウンロードしない(ネットワークに出ない)。本物の版と SHA-256 は、CI(lien-ios・lien-release)が
実際にダウンロードして照合する。ここでは「固定した値が書式として正しい」ことと、照合・検査の分岐を確かめる。
"""

import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "install-xcodegen.sh")
VERSION = "9.9.9"

FAKE_XCODEGEN = "#!/bin/sh\necho 'Version: %s'\n"


def build_zip(path, version=VERSION, binary=True, presets=True, printed_version=None):
    """XcodeGen の scripts/archive.sh と同じ配置の zip(xcodegen/bin/xcodegen・xcodegen/share/xcodegen/SettingPresets/)"""
    with zipfile.ZipFile(path, "w") as archive:
        if binary:
            info = zipfile.ZipInfo("xcodegen/bin/xcodegen")
            info.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(info, FAKE_XCODEGEN % (printed_version or version))
        if presets:
            archive.writestr("xcodegen/share/xcodegen/SettingPresets/base.yml", "SDKROOT: iphoneos\n")
        archive.writestr("xcodegen/LICENSE", "MIT\n")
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


class InstallXcodegenTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.runner_temp = os.path.join(self.tmp, "runner_temp")
        os.makedirs(self.runner_temp)
        self.github_path = os.path.join(self.tmp, "github_path")
        self.summary = os.path.join(self.tmp, "summary.md")
        self.zip_path = os.path.join(self.tmp, "xcodegen.zip")

    def install(self, sha256, url=None, version=VERSION, github=True):
        env = {
            "PATH": os.environ["PATH"], "HOME": self.tmp,
            "RUNNER_TEMP": self.runner_temp,
            "XCODEGEN_VERSION": version, "XCODEGEN_SHA256": sha256,
            "XCODEGEN_URL": url or ("file://" + self.zip_path),
        }
        if github:
            env["GITHUB_PATH"] = self.github_path
            env["GITHUB_STEP_SUMMARY"] = self.summary
        return subprocess.run(["bash", SCRIPT], env=env, capture_output=True, text=True)

    def read(self, path):
        if not os.path.exists(path):
            return ""
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def test_installs_the_pinned_version_and_adds_it_to_the_path(self):
        sha = build_zip(self.zip_path)
        result = self.install(sha)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        bin_dir = os.path.join(self.runner_temp, f"xcodegen-{VERSION}", "xcodegen", "bin")
        self.assertEqual(self.read(self.github_path).strip(), bin_dir)
        self.assertTrue(os.access(os.path.join(bin_dir, "xcodegen"), os.X_OK))
        self.assertIn("SHA-256: 一致", result.stdout)
        self.assertIn(f"xcodegen --version: Version: {VERSION}", result.stdout)
        summary = self.read(self.summary)
        self.assertIn("## XcodeGen", summary)
        self.assertIn(f"`{VERSION}`", summary)
        self.assertFalse(os.path.exists(os.path.join(self.runner_temp, f"xcodegen-{VERSION}.zip")), "zip は消す")

    def test_the_installed_binary_runs_from_where_it_was_unpacked(self):
        sha = build_zip(self.zip_path)
        self.assertEqual(self.install(sha).returncode, 0)
        binary = os.path.join(self.runner_temp, f"xcodegen-{VERSION}", "xcodegen", "bin", "xcodegen")
        self.assertIn(VERSION, subprocess.run([binary, "--version"], capture_output=True, text=True).stdout)

    def test_a_different_sha256_is_refused_and_nothing_is_added_to_the_path(self):
        build_zip(self.zip_path)
        result = self.install("0" * 64)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("::error::", result.stdout)
        self.assertIn("SHA-256 が固定した値と違います", result.stdout)
        self.assertEqual(self.read(self.github_path), "")
        self.assertFalse(os.path.exists(os.path.join(self.runner_temp, f"xcodegen-{VERSION}", "xcodegen")), "展開しない")

    def test_a_download_failure_is_an_error(self):
        result = self.install("0" * 64, url="file://" + os.path.join(self.tmp, "no-such.zip"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("ダウンロードできません", result.stdout)
        self.assertEqual(self.read(self.github_path), "")

    def test_a_binary_that_reports_another_version_is_refused(self):
        sha = build_zip(self.zip_path, printed_version="1.0.0")
        result = self.install(sha)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(f"{VERSION} ではありません", result.stdout)
        self.assertEqual(self.read(self.github_path), "")

    def test_a_zip_without_the_binary_is_refused(self):
        sha = build_zip(self.zip_path, binary=False)
        result = self.install(sha)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("zip の中身が想定と違います", result.stdout)

    def test_a_zip_without_setting_presets_is_refused(self):
        # SettingPresets が無いと、xcodegen は `No "base" settings found` と出すだけで、既定のビルド設定が入らない .xcodeproj を作ってしまう
        sha = build_zip(self.zip_path, presets=False)
        result = self.install(sha)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("SettingPresets がありません", result.stdout)
        self.assertEqual(self.read(self.github_path), "")

    def test_outside_github_actions_it_prints_how_to_extend_the_path(self):
        sha = build_zip(self.zip_path)
        result = self.install(sha, github=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PATH に足してください", result.stdout)


class PinnedValuesTests(unittest.TestCase):
    """スクリプトに書いた、固定する版と SHA-256 が書式として正しい(書き換えのときの打ち間違いを止める)"""

    @classmethod
    def setUpClass(cls):
        with open(SCRIPT, encoding="utf-8") as fh:
            cls.source = fh.read()

    def test_the_pinned_version_is_a_release_number(self):
        match = re.search(r'^XCODEGEN_VERSION="\$\{XCODEGEN_VERSION:-(\d+\.\d+\.\d+)\}"$', self.source, re.M)
        self.assertIsNotNone(match, "XCODEGEN_VERSION の既定が x.y.z で書かれていない")

    def test_the_pinned_sha256_is_64_lowercase_hex_characters(self):
        match = re.search(r'^XCODEGEN_SHA256="\$\{XCODEGEN_SHA256:-([0-9a-f]{64})\}"$', self.source, re.M)
        self.assertIsNotNone(match, "XCODEGEN_SHA256 の既定が 64 桁の小文字 16 進で書かれていない")

    def test_the_script_is_executable_and_valid_shell(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK), "scripts/install-xcodegen.sh に実行権限がない(chmod +x)")
        self.assertEqual(subprocess.run(["bash", "-n", SCRIPT]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
