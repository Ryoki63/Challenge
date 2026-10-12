#!/usr/bin/env python3
"""export_attachments.py の単体テスト(xcresulttool は呼ばず、書き出し済みのディレクトリを使う)。

lien-ios の「Release script unit tests」(python3 -m unittest discover -s scripts -p 'test_*.py')で実行される。
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import export_attachments as ea  # noqa: E402

UUID = "3E1C9A52-7B4D-4F0E-9C2A-1D5B8E6F7A90"


class CleanNameTest(unittest.TestCase):
    def test_strips_index_and_uuid(self):
        self.assertEqual(ea.clean_name("plant_01_states_light_0_%s.png" % UUID, "x.png"), "plant_01_states_light.png")

    def test_collapses_a_doubled_extension(self):
        # attachment.name に ".png" を含めた場合: "name.png" + "_0_<UUID>" + ".png"
        self.assertEqual(ea.clean_name("plant_01_states_light.png_0_%s.png" % UUID, "x.png"), "plant_01_states_light.png")
        self.assertEqual(ea.clean_name("plant_01_states_light.png", "x.png"), "plant_01_states_light.png")

    def test_falls_back_to_the_exported_name(self):
        self.assertEqual(ea.clean_name(None, "ABCD.png"), "ABCD.png")
        self.assertEqual(ea.clean_name("", "ABCD.png"), "ABCD.png")

    def test_path_separators_are_replaced(self):
        self.assertEqual(ea.clean_name("a/b:c.png", "x.png"), "a_b_c.png")


class ExportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="export_attachments_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.export_dir = os.path.join(self.tmp, "exported")
        self.out_dir = os.path.join(self.tmp, "out")
        os.makedirs(self.export_dir)

    def write(self, name, content=b"png"):
        with open(os.path.join(self.export_dir, name), "wb") as fh:
            fh.write(content)

    def manifest(self, data):
        with open(os.path.join(self.export_dir, "manifest.json"), "w", encoding="utf-8") as fh:
            json.dump(data, fh)

    def test_exports_matching_attachments_with_readable_names(self):
        self.write("AAA.png", b"one")
        self.write("BBB.png", b"two")
        self.write("CCC.txt", b"log")
        self.manifest([
            {"testIdentifier": "PlantRenderTests/testRenderContactSheets()", "attachments": [
                {"exportedFileName": "AAA.png", "suggestedHumanReadableName": "plant_01_states_light.png_0_%s.png" % UUID},
                {"exportedFileName": "BBB.png", "suggestedHumanReadableName": "plant_02_states_dark_1_%s.png" % UUID},
                {"exportedFileName": "CCC.txt", "suggestedHumanReadableName": "Debug Description_2_%s.txt" % UUID},
            ]},
        ])
        copied = ea.collect(self.export_dir, self.out_dir, "plant_")
        self.assertEqual(sorted(copied), ["plant_01_states_light.png", "plant_02_states_dark.png"])
        with open(os.path.join(self.out_dir, "plant_01_states_light.png"), "rb") as fh:
            self.assertEqual(fh.read(), b"one")
        self.assertFalse(os.path.exists(os.path.join(self.out_dir, "Debug Description.txt")))

    def test_finds_attachments_in_any_nesting_and_dedupes_names(self):
        self.write("AAA.png", b"first")
        self.write("BBB.png", b"retry")
        self.manifest({"testRuns": [{"tests": [{"attachments": [
            {"exportedFileName": "AAA.png", "suggestedHumanReadableName": "plant_01.png"}]},
            {"attachments": [{"exportedFileName": "BBB.png", "suggestedHumanReadableName": "plant_01.png"}]}]}]})
        copied = ea.collect(self.export_dir, self.out_dir, "")
        self.assertEqual(sorted(copied), ["plant_01.png", "plant_01_1.png"])

    def test_skips_entries_whose_file_is_missing(self):
        self.manifest([{"attachments": [{"exportedFileName": "GONE.png", "suggestedHumanReadableName": "plant_x.png"}]}])
        self.assertEqual(ea.collect(self.export_dir, self.out_dir, "plant_"), [])

    def test_main_exit_codes(self):
        self.write("AAA.png")
        self.manifest([{"attachments": [{"exportedFileName": "AAA.png", "suggestedHumanReadableName": "plant_a.png"}]}])
        self.assertEqual(ea.main(["unused.xcresult", self.out_dir, "--prefix", "plant_", "--from-dir", self.export_dir]), 0)
        self.assertEqual(ea.main(["unused.xcresult", self.out_dir, "--prefix", "nothing_", "--from-dir", self.export_dir]), 1)
        # 書き出し済みでない・xcresult が無い
        empty = os.path.join(self.tmp, "empty")
        os.makedirs(empty)
        self.assertEqual(ea.main(["unused.xcresult", self.out_dir, "--from-dir", empty]), 2)
        self.assertEqual(ea.main([os.path.join(self.tmp, "missing.xcresult"), self.out_dir]), 2)


if __name__ == "__main__":
    unittest.main()
