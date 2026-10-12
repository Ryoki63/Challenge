#!/usr/bin/env python3
"""iOS シミュレータを 1 台起動して、起動が終わるまで待つ。かかった時間を表示する(issue #66)。

  python3 boot_simulator.py "iPhone 17" [--github-output FILE] [--summary FILE]

lien-ios の `xcodebuild test` は、シミュレータが起動していなければ自分で起動して待つ。その待ち時間が
「Build & test」の中に隠れて見えないまま、ステップが 10〜13 分に伸びていた(ビルドが終わってからテストが始まるまでに
2〜8 分の空白があった)。起動だけを別のステップに切り出して、所要を「そのステップの時間」と「ジョブサマリ」に出す。

  - 名前が一致する、利用できるデバイスのうち、最新の iOS ランタイムのものを選ぶ(xcodebuild の `name=…` の既定と同じ)
  - `xcrun simctl bootstatus <udid> -b` で、起動していなければ起動し、データの移行も含めて終わるまで待つ
  - --github-output: `udid=…` を書く(後続の xcodebuild が `-destination 'platform=iOS Simulator,id=…'` で同じ1台を使う)

Python 3.9+ の標準ライブラリだけで動く。
"""

import argparse
import json
import re
import subprocess
import sys
import time

RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime."


def ios_version(runtime_key):
    """`com.apple.CoreSimulator.SimRuntime.iOS-26-5` → (26, 5)。iOS 以外(tvOS・watchOS …)は None"""
    match = re.fullmatch(re.escape(RUNTIME_PREFIX) + r"iOS-(\d+(?:-\d+)*)", runtime_key)
    return tuple(int(part) for part in match.group(1).split("-")) if match else None


def choose_device(listing, name):
    """simctl list devices available --json の結果から (udid, 'iOS 26.5', state)。無ければ LookupError"""
    candidates = []
    seen = []
    for runtime_key, devices in (listing.get("devices") or {}).items():
        version = ios_version(runtime_key)
        if version is None:
            continue
        for device in devices:
            if device.get("isAvailable", True) is False:
                continue
            seen.append(f"{device.get('name')} (iOS {'.'.join(map(str, version))})")
            if device.get("name") == name:
                candidates.append((version, device))
    if not candidates:
        raise LookupError(f"{name!r} という名前の、利用できる iOS シミュレータがありません。ある機種: {', '.join(sorted(set(seen))) or 'なし'}")
    version, device = max(candidates, key=lambda item: item[0])
    return device["udid"], "iOS " + ".".join(map(str, version)), device.get("state", "?")


def list_devices():
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"simctl list が失敗しました: {(result.stderr or result.stdout).strip()[:300]}")
    return json.loads(result.stdout)


def boot_and_wait(udid):
    """起動していなければ起動し、終わるまで待つ(進み具合は simctl が標準出力に出す)。終了コードを返す"""
    return subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=False).returncode


def main(argv=None, devices=list_devices, boot=boot_and_wait, clock=time.monotonic):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("name", help='シミュレータの名前(例: "iPhone 17")')
    parser.add_argument("--github-output", help="udid=… を追記するファイル(GITHUB_OUTPUT)")
    parser.add_argument("--summary", help="所要の表(Markdown)を追記するファイル(GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv)

    try:
        udid, runtime, state = choose_device(devices(), args.name)
    except (LookupError, RuntimeError, ValueError) as error:
        print(f"::error::{error}")
        return 1

    label = f"{args.name} ({runtime})"
    print(f"{label}: {udid}(いまの状態: {state})。起動して、終わるまで待ちます")
    started = clock()
    code = boot(udid)
    seconds = clock() - started
    if code != 0:
        print(f"::error::{label} の起動が失敗しました(simctl bootstatus の終了コード {code}、{seconds:.0f} 秒)")
        return 1
    print(f"{label} の起動が終わりました({seconds:.0f} 秒)")

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            fh.write(f"udid={udid}\nruntime={runtime}\nboot_seconds={seconds:.0f}\n")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(
                "## シミュレータの起動\n\n"
                "| デバイス | 起動前の状態 | 起動にかかった時間 |\n|---|---|---|\n"
                f"| {label} | {state} | {seconds:.0f} 秒 |\n\n"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
