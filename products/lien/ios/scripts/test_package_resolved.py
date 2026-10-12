"""package_resolved.py の単体テスト+コミット済み Package.resolved の整合(issue #28)"""

import contextlib
import io
import json
import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
IOS_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import package_resolved as pr  # noqa: E402


def pin(identity, version, revision, location=None):
    return {
        "identity": identity,
        "kind": "remoteSourceControl",
        "location": location or f"https://github.com/example/{identity}.git",
        "state": {"revision": revision, "version": version},
    }


def write(directory, name, pins, origin_hash=None, indent=2):
    path = os.path.join(directory, name)
    data = {"pins": pins, "version": 3}
    if origin_hash:
        data["originHash"] = origin_hash
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=indent)
    return path


def compare(a, b):
    buf = io.StringIO()
    code = pr.compare(a, b, out=buf)
    return code, buf.getvalue()


class CompareTests(unittest.TestCase):
    def test_same_pins_pass_even_if_hash_and_format_differ(self):
        pins = [pin("a", "1.0.0", "r1"), pin("b", "2.0.0", "r2")]
        with tempfile.TemporaryDirectory() as tmp:
            committed = write(tmp, "c.json", pins)
            resolved = write(tmp, "r.json", list(reversed(pins)), origin_hash="abc", indent=4)
            code, out = compare(committed, resolved)
        self.assertEqual(code, 0, out)

    def test_changed_version_fails_and_prints_the_new_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            committed = write(tmp, "c.json", [pin("a", "1.0.0", "r1")])
            resolved = write(tmp, "r.json", [pin("a", "1.1.0", "r9")])
            code, out = compare(committed, resolved)
        self.assertEqual(code, 1)
        self.assertIn("変更 : a 1.0.0", out)
        self.assertIn("1.1.0", out)
        self.assertIn("ここから", out)
        self.assertIn('"revision": "r9"', out)

    def test_added_and_removed_pins_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            committed = write(tmp, "c.json", [pin("a", "1.0.0", "r1"), pin("gone", "1.0.0", "rg")])
            resolved = write(tmp, "r.json", [pin("a", "1.0.0", "r1"), pin("new", "3.0.0", "rn")])
            code, out = compare(committed, resolved)
        self.assertEqual(code, 1)
        self.assertIn("追加 : new", out)
        self.assertIn("削除 : gone", out)

    def test_loads_version_1_format(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "v1.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump({"object": {"pins": [{"package": "Foo", "repositoryURL": "u", "state": {"version": "1.0.0", "revision": "r"}}]}, "version": 1}, fh)
            self.assertEqual(pr.load_pins(path), {"foo": ("u", "1.0.0", "r")})


class CommittedFileTests(unittest.TestCase):
    """リポジトリにコミットした ios/Package.resolved と project.yml の整合"""

    def test_supabase_swift_pin_matches_exact_version_in_project_yml(self):
        with open(os.path.join(IOS_DIR, "project.yml"), encoding="utf-8") as fh:
            match = re.search(r'exactVersion:\s*"?([0-9]+\.[0-9]+\.[0-9]+)"?', fh.read())
        self.assertIsNotNone(match, "project.yml の Supabase は exactVersion で固定する")
        pins = pr.load_pins(os.path.join(IOS_DIR, "Package.resolved"))
        self.assertIn("supabase-swift", pins)
        self.assertEqual(pins["supabase-swift"][1], match.group(1))

    def test_every_pin_has_a_version_and_a_full_revision(self):
        for identity, (location, version, revision) in pr.load_pins(os.path.join(IOS_DIR, "Package.resolved")).items():
            self.assertTrue(location and location.startswith("https://"), identity)
            self.assertRegex(version or "", r"^\d+\.\d+\.\d+$", identity)
            self.assertRegex(revision or "", r"^[0-9a-f]{40}$", identity)


if __name__ == "__main__":
    unittest.main()
