"""ci_status.py の単体テスト — GitHub Actions の API の応答を差し替えて、リリース前の「同じ SHA の CI が緑」の判定を固定する(issue #66)"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ci_status  # noqa: E402

SHA = "a" * 40
OTHER = "b" * 40


def run(number, status="completed", conclusion="success", sha=SHA, event="push"):
    return {
        "run_number": number, "status": status, "conclusion": conclusion, "head_sha": sha, "event": event,
        "html_url": f"https://github.com/example/repo/actions/runs/{number}",
    }


class EvaluateTests(unittest.TestCase):
    def test_a_successful_run_for_the_same_sha_is_ok(self):
        ok, state, detail = ci_status.evaluate([run(7)], SHA, "lien-ios.yml")
        self.assertTrue(ok)
        self.assertEqual(state, "success")
        self.assertIn("run #7", detail)

    def test_a_run_for_another_sha_does_not_count(self):
        ok, state, _ = ci_status.evaluate([run(7, sha=OTHER)], SHA, "lien-ios.yml")
        self.assertFalse(ok)
        self.assertEqual(state, "実行なし")

    def test_no_run_for_lien_ios_says_to_run_it_by_hand(self):
        ok, state, detail = ci_status.evaluate([], SHA, "lien-ios.yml")
        self.assertFalse(ok)
        self.assertEqual(state, "実行なし")
        self.assertIn("手動実行", detail)

    def test_no_run_for_another_workflow_has_its_own_hint(self):
        _, _, detail = ci_status.evaluate([], SHA, "lien-ci.yml")
        self.assertIn("lien-ci.yml", detail)

    def test_a_failed_run_is_not_ok(self):
        ok, state, detail = ci_status.evaluate([run(7, conclusion="failure")], SHA, "lien-ios.yml")
        self.assertFalse(ok)
        self.assertEqual(state, "success ではない")
        self.assertIn("failure", detail)

    def test_cancelled_and_skipped_and_timed_out_are_not_ok(self):
        for conclusion in ("cancelled", "skipped", "timed_out", "neutral", "action_required", None):
            with self.subTest(conclusion=conclusion):
                ok, _, _ = ci_status.evaluate([run(7, conclusion=conclusion)], SHA, "lien-ios.yml")
                self.assertFalse(ok)

    def test_a_run_in_progress_is_not_ok_yet(self):
        for status in ("queued", "in_progress", "waiting", "pending", "requested"):
            with self.subTest(status=status):
                ok, state, detail = ci_status.evaluate([run(7, status=status, conclusion=None)], SHA, "lien-ios.yml")
                self.assertFalse(ok)
                self.assertEqual(state, "実行中")
                self.assertIn("待って", detail)

    def test_a_rerun_that_succeeded_after_a_failure_is_ok(self):
        # 同じ SHA を手動で実行し直して通った場合(インフラの失敗など)。success が 1 つでもあれば OK
        ok, _, detail = ci_status.evaluate([run(8, conclusion="failure"), run(9)], SHA, "lien-ios.yml")
        self.assertTrue(ok)
        self.assertIn("run #9", detail)

    def test_the_newest_success_is_reported(self):
        _, _, detail = ci_status.evaluate([run(5), run(9), run(7)], SHA, "lien-ios.yml")
        self.assertIn("run #9", detail)

    def test_pending_is_reported_before_an_old_failure(self):
        ok, state, _ = ci_status.evaluate(
            [run(8, conclusion="failure"), run(9, status="in_progress", conclusion=None)], SHA, "lien-ios.yml")
        self.assertFalse(ok)
        self.assertEqual(state, "実行中")


class MainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.summary = os.path.join(self.tmp, "summary.md")

    def main(self, runs_by_workflow, *flags, sha=SHA):
        """runs_by_workflow: {ワークフロー: 実行の一覧 or 例外}。(終了コード, 標準出力, summary) を返す"""
        calls = []

        def fetch(repo, workflow, wanted_sha):
            calls.append((repo, workflow, wanted_sha))
            value = runs_by_workflow[workflow]
            if isinstance(value, Exception):
                raise value
            return value

        argv = ["--repo", "example/repo", "--sha", sha, "--summary", self.summary, *flags]
        for workflow in runs_by_workflow:
            argv += ["--workflow", workflow]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = ci_status.main(argv, fetch=fetch)
        summary = ""
        if os.path.exists(self.summary):
            with open(self.summary, encoding="utf-8") as fh:
                summary = fh.read()
        self.calls = calls
        return code, out.getvalue(), summary

    def test_require_passes_when_every_workflow_is_green(self):
        code, out, summary = self.main({"lien-ios.yml": [run(3)], "lien-ci.yml": [run(12)]}, "--require")
        self.assertEqual(code, 0, out)
        self.assertNotIn("::error::", out)
        self.assertIn("| lien-ios.yml | OK | success |", summary)
        self.assertIn("| lien-ci.yml | OK | success |", summary)
        self.assertEqual(self.calls, [("example/repo", "lien-ios.yml", SHA), ("example/repo", "lien-ci.yml", SHA)])

    def test_require_stops_when_one_workflow_is_not_green(self):
        code, out, summary = self.main({"lien-ios.yml": [run(3, conclusion="failure")], "lien-ci.yml": [run(12)]}, "--require")
        self.assertEqual(code, 1, out)
        self.assertIn("::error::lien-ios.yml", out)
        self.assertIn("| lien-ios.yml | **NG** | success ではない |", summary)
        self.assertIn("| lien-ci.yml | OK |", summary)

    def test_require_stops_when_there_is_no_run(self):
        code, out, _ = self.main({"lien-ios.yml": []}, "--require")
        self.assertEqual(code, 1, out)
        self.assertIn("実行なし", out)

    def test_require_stops_when_the_api_cannot_be_read(self):
        # 読めなかったときに黙って通すと、確認していないのに「確認済み」になる
        code, out, summary = self.main({"lien-ios.yml": RuntimeError("gh api が失敗しました: HTTP 403")}, "--require")
        self.assertEqual(code, 1, out)
        self.assertIn("確認できない", out)
        self.assertIn("HTTP 403", summary)

    def test_without_require_it_only_reports(self):
        # dry-run: 緑でなくても終了コードは 0。警告として出し、dry_run=false で止まることを書く
        code, out, summary = self.main({"lien-ios.yml": [run(3, conclusion="failure")], "lien-ci.yml": []})
        self.assertEqual(code, 0, out)
        self.assertNotIn("::error::", out)
        self.assertIn("::warning::lien-ios.yml", out)
        self.assertIn("::warning::lien-ci.yml", out)
        self.assertIn("dry_run=false ではここで止まる", out)
        self.assertIn("表示のみ(dry-run)", summary)

    def test_without_require_an_unreadable_api_is_still_only_a_warning(self):
        code, out, _ = self.main({"lien-ios.yml": RuntimeError("network down")})
        self.assertEqual(code, 0, out)
        self.assertIn("::warning::lien-ios.yml", out)

    def test_a_short_or_malformed_sha_is_rejected(self):
        for sha in ("abc123", "g" * 40, "A" * 40, ""):
            with self.subTest(sha=sha):
                code, out, _ = self.main({"lien-ios.yml": [run(3)]}, "--require", sha=sha)
                self.assertEqual(code, 2, out)
                self.assertIn("::error::", out)
                self.assertEqual(self.calls, [])


class FetchRunsTests(unittest.TestCase):
    """`gh api` の呼び方と、応答の読み方(gh は差し替える)"""

    def completed(self, stdout="", returncode=0, stderr=""):
        return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=stderr)

    def test_the_api_path_filters_by_workflow_and_head_sha(self):
        payload = json.dumps({"workflow_runs": [run(3)]})
        with mock.patch.object(ci_status.subprocess, "run", return_value=self.completed(payload)) as runner:
            runs = ci_status.fetch_runs("example/repo", "lien-ios.yml", SHA)
        self.assertEqual([r["run_number"] for r in runs], [3])
        args = runner.call_args[0][0]
        self.assertEqual(args[:2], ["gh", "api"])
        self.assertEqual(
            args[-1], f"repos/example/repo/actions/workflows/lien-ios.yml/runs?head_sha={SHA}&per_page=100")

    def test_a_failing_gh_is_an_error(self):
        with mock.patch.object(ci_status.subprocess, "run", return_value=self.completed("", 1, "HTTP 403: forbidden")):
            with self.assertRaises(RuntimeError) as caught:
                ci_status.fetch_runs("example/repo", "lien-ios.yml", SHA)
        self.assertIn("HTTP 403", str(caught.exception))

    def test_a_non_json_response_is_an_error(self):
        with mock.patch.object(ci_status.subprocess, "run", return_value=self.completed("<html>")):
            with self.assertRaises(RuntimeError):
                ci_status.fetch_runs("example/repo", "lien-ios.yml", SHA)

    def test_a_response_without_runs_is_empty(self):
        with mock.patch.object(ci_status.subprocess, "run", return_value=self.completed("{}")):
            self.assertEqual(ci_status.fetch_runs("example/repo", "lien-ios.yml", SHA), [])


if __name__ == "__main__":
    unittest.main()
