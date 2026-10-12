#!/usr/bin/env python3
"""リリースの前に、同じコミット(SHA)の CI が緑かを GitHub Actions の API で確かめる(issue #66)。

  python3 ci_status.py --repo OWNER/REPO --sha SHA --workflow lien-ios.yml [--workflow lien-ci.yml ...]
                       [--require] [--summary FILE]

lien-release(dry_run=false)は TestFlight にアップロードする。そのビルドの元になったコミットで、テストが通っていない
ものを上げないために、起動の最初に「このコミットの lien-ios(と lien-ci)が success か」を `gh api` で確かめる。

  - --require あり: 1 つでも success でなければ終了コード 1(リリースを止める)。API を読めなかったときも止める
  - --require なし: 結果を表示するだけで、終了コードは 0(dry-run が、この経路を毎回通して確かめるため)

lien-ios は products/lien/ios などが変わった push でだけ起動する(macOS の課金が大きいため)。ios 以外だけの
コミットには lien-ios の実行が無いので、その場合は「手動実行してから」と案内して止める。

`gh` が GH_TOKEN(GitHub Actions の ${{ github.token }}。actions: read)で認証されている前提。Python 3.9+ の標準ライブラリだけで動く。
"""

import argparse
import json
import re
import subprocess
import sys

# 実行中・待機中の status(completed 以外)
PENDING_STATUSES = {"queued", "in_progress", "waiting", "pending", "requested"}


def fetch_runs(repo, workflow, sha):
    """そのワークフローの、head_sha が一致する実行の一覧(新しい順)。`gh api` の失敗は RuntimeError"""
    path = f"repos/{repo}/actions/workflows/{workflow}/runs?head_sha={sha}&per_page=100"
    result = subprocess.run(
        ["gh", "api", "-H", "Accept: application/vnd.github+json", path],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"gh api が失敗しました: {(result.stderr or result.stdout).strip()[:300]}")
    try:
        return json.loads(result.stdout).get("workflow_runs", [])
    except (ValueError, AttributeError) as error:
        raise RuntimeError(f"gh api の応答を読めません: {error}") from error


def describe(run):
    return f"run #{run.get('run_number')}({run.get('event')}。{run.get('html_url')})"


def evaluate(runs, sha, workflow):
    """(ok, 状態, 説明)。同じ SHA に success の実行が 1 つでもあれば OK(同じ SHA を手動で再実行して通った場合も OK)"""
    mine = [run for run in runs if run.get("head_sha") == sha]
    mine.sort(key=lambda run: run.get("run_number") or 0, reverse=True)
    succeeded = [run for run in mine if run.get("status") == "completed" and run.get("conclusion") == "success"]
    if succeeded:
        return True, "success", describe(succeeded[0])
    pending = [run for run in mine if run.get("status") in PENDING_STATUSES]
    if pending:
        return False, "実行中", f"{describe(pending[0])} がまだ終わっていません。終わって success になるのを待ってから、もう一度実行してください"
    if mine:
        conclusions = sorted({str(run.get("conclusion")) for run in mine if run.get("status") == "completed"})
        return False, "success ではない", f"{describe(mine[0])} の結果は {', '.join(conclusions) or '不明'} です。原因を直して緑にしてください"
    if workflow == "lien-ios.yml":
        hint = (
            "lien-ios は ios などが変わった push でだけ起動します。このコミットで起動していなければ、Actions の lien-ios を"
            "同じブランチで手動実行(Run workflow)し、緑になってからもう一度実行してください"
        )
    else:
        hint = "push 直後なら、起動するまで少し待ってください。起動しなければ、Actions の lien-ci を手動実行してください"
    return False, "実行なし", f"このコミットの {workflow} の実行がありません。{hint}"


def main(argv=None, fetch=fetch_runs):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="OWNER/REPO(GitHub Actions では $GITHUB_REPOSITORY)")
    parser.add_argument("--sha", required=True, help="確かめるコミット(GitHub Actions では $GITHUB_SHA)")
    parser.add_argument("--workflow", action="append", required=True, help="ワークフローのファイル名(例: lien-ios.yml)。複数指定できる")
    parser.add_argument("--require", action="store_true", help="success でないものがあれば終了コード 1(無ければ表示だけ)")
    parser.add_argument("--summary", help="結果の表(Markdown)を追記するファイル(GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv)

    if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
        print(f"::error::--sha はコミットの 40 桁の SHA にしてください: {args.sha!r}")
        return 2

    rows = []
    failed = []
    for workflow in args.workflow:
        try:
            ok, state, detail = evaluate(fetch(args.repo, workflow, args.sha), args.sha, workflow)
        except RuntimeError as error:
            ok, state, detail = False, "確認できない", str(error)
        rows.append((workflow, "OK" if ok else "**NG**", state, detail))
        if ok:
            print(f"::notice::{workflow}: このコミットで success です({detail})")
        else:
            failed.append(workflow)
            if args.require:
                print(f"::error::{workflow}: {state}。{detail}")
            else:
                print(f"::warning::{workflow}: {state}。{detail}(dry-run のため警告にとどめる。dry_run=false ではここで止まる)")

    if args.summary:
        lines = [
            "## このコミットの CI",
            "",
            f"確認するコミット: `{args.sha[:12]}`({'必須。success でなければ止める' if args.require else '表示のみ(dry-run)'})",
            "",
            "| ワークフロー | 結果 | 状態 | 詳細 |",
            "|---|---|---|---|",
        ]
        lines += [f"| {workflow} | {mark} | {state} | {detail} |" for workflow, mark, state, detail in rows]
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n\n")

    return 1 if (failed and args.require) else 0


if __name__ == "__main__":
    sys.exit(main())
