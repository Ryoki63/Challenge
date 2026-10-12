#!/usr/bin/env python3
"""lien-release が作った .xcarchive の中身を、アップロード前に検査する(issue #28)。

  python3 verify_archive.py ARCHIVE --build-number N [--supabase strict|warn] [--signed] [--summary FILE]

見るもの(error = 終了コード 1 / warning = 注意のみ):
  - アプリ・ウィジェット・NSE の Bundle ID(Config/Base.xcconfig の LIEN_BUNDLE_ID_BASE から導く)
  - 版: CFBundleShortVersionString = Base.xcconfig の MARKETING_VERSION(x.y.z)/ CFBundleVersion = ビルド番号
    (3 つのバンドルで一致)
  - 最低 OS 17.0 / ITSAppUsesNonExemptEncryption = false(輸出コンプライアンスの質問を省く)
  - iOS 26 SDK 以上でビルドされたこと(DTSDKName。2026-04-28 以降のアップロード要件)
  - AppIcon: コンパイル済みのアセットカタログ(Assets.car)があること
  - PrivacyInfo.xcprivacy が 3 つのバンドルすべてに入っていて読めること
  - Info.plist の Supabase 接続情報(--supabase strict ならエラー / warn なら警告にとどめる)
  - dSYM があること(warning)
  - 署名済み(--signed)なら codesign の検証とエンタイトルメントの有無(warning)

Python 3.9+ の標準ライブラリだけで動く。
"""

import argparse
import os
import plistlib
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
IOS_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import supabase_config  # noqa: E402


def read_xcconfig(name):
    """Config/Base.xcconfig の `NAME = value`(コメント行は除く)"""
    path = os.path.join(IOS_DIR, "Config", "Base.xcconfig")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            match = re.match(rf"^\s*{re.escape(name)}\s*=\s*(\S+)\s*$", line)
            if match:
                return match.group(1)
    raise SystemExit(f"{path} に {name} がありません")


def load_plist(path):
    with open(path, "rb") as fh:
        return plistlib.load(fh)


class Report:
    def __init__(self):
        self.rows = []  # (状態, 項目, 詳細)
        self.errors = 0
        self.warnings = 0

    def ok(self, item, detail=""):
        self.rows.append(("OK", item, detail))

    def warn(self, item, detail):
        self.warnings += 1
        self.rows.append(("WARN", item, detail))
        print(f"::warning::{item}: {detail}")

    def fail(self, item, detail):
        self.errors += 1
        self.rows.append(("NG", item, detail))
        print(f"::error::{item}: {detail}")

    def check(self, condition, item, ok_detail, ng_detail):
        if condition:
            self.ok(item, ok_detail)
        else:
            self.fail(item, ng_detail)

    def markdown(self):
        lines = ["| 結果 | 項目 | 詳細 |", "|---|---|---|"]
        for status, item, detail in self.rows:
            mark = {"OK": "OK", "WARN": "注意", "NG": "**NG**"}[status]
            lines.append(f"| {mark} | {item} | {detail} |")
        return "\n".join(lines)


# DEBUG ビルドにだけ入るコードの目印(型名)。Release の archive の実行ファイルに出てきたら、構成を取り違えている
DEBUG_ONLY_MARKERS = ["DeviceTokenDebugView"]


def sdk_major(name):
    match = re.match(r"^iphoneos(\d+)", name or "")
    return int(match.group(1)) if match else None


def check_bundle(report, label, bundle, expect_id, version, build, extension_point=None):
    info_path = os.path.join(bundle, "Info.plist")
    if not os.path.isfile(info_path):
        report.fail(f"{label}", f"{os.path.relpath(info_path)} がありません")
        return None
    info = load_plist(info_path)
    report.check(
        info.get("CFBundleIdentifier") == expect_id, f"{label}: Bundle ID",
        expect_id, f"{info.get('CFBundleIdentifier')!r} (期待: {expect_id})",
    )
    report.check(
        info.get("CFBundleShortVersionString") == version, f"{label}: 版 (CFBundleShortVersionString)",
        version, f"{info.get('CFBundleShortVersionString')!r} (期待: {version} = Base.xcconfig の MARKETING_VERSION)",
    )
    report.check(
        str(info.get("CFBundleVersion")) == str(build), f"{label}: ビルド番号 (CFBundleVersion)",
        str(build), f"{info.get('CFBundleVersion')!r} (期待: {build})",
    )
    report.check(
        str(info.get("MinimumOSVersion")) == "17.0", f"{label}: 最低 OS",
        "17.0", f"{info.get('MinimumOSVersion')!r} (期待: 17.0)",
    )
    if extension_point:
        actual = (info.get("NSExtension") or {}).get("NSExtensionPointIdentifier")
        report.check(actual == extension_point, f"{label}: 拡張ポイント", extension_point, f"{actual!r}")
    manifest_path = os.path.join(bundle, "PrivacyInfo.xcprivacy")
    if not os.path.isfile(manifest_path):
        report.fail(f"{label}: PrivacyInfo.xcprivacy", "バンドルに入っていません(project.yml の sources を確認)")
    else:
        try:
            manifest = load_plist(manifest_path)
            report.check(
                manifest.get("NSPrivacyTracking") is False, f"{label}: PrivacyInfo.xcprivacy",
                "あり・トラッキングなし", "NSPrivacyTracking が false ではありません",
            )
        except Exception as error:  # noqa: BLE001 - plist の壊れ方は多様
            report.fail(f"{label}: PrivacyInfo.xcprivacy", f"読めません: {error}")
    return info


def check_release_configuration(report, binary):
    """Release 構成の archive であること: DEBUG 専用コードが実行ファイルに入っていない。
    (入っていると、Config が無いときの致命扱いも DEBUG 側(Stub に落ちる)になってしまう)"""
    if not os.path.isfile(binary):
        report.warn("Release 構成の確認", "実行ファイルが見つかりません")
        return
    try:
        out = subprocess.run(["strings", "-a", binary], capture_output=True, text=True, errors="replace").stdout
    except OSError:
        report.warn("Release 構成の確認", "strings コマンドが使えません")
        return
    leaked = [m for m in DEBUG_ONLY_MARKERS if m in out]
    report.check(
        not leaked, "Release 構成(DEBUG 専用コードなし)", "DEBUG 専用の型は入っていない",
        f"{', '.join(leaked)} が入っています。Release 構成の archive ではありません",
    )


# codesign でエンタイトルメントを plist(XML)として標準出力へ出す引数(issue #66)。
# 旧来の `--entitlements :-` は「パスに ':' を付ける指定は非推奨で、将来のリリースで使えなくなる」と警告される。
# 現行の構文は `--entitlements -` に `--xml` を足したもの。`--xml` を付けないと、plist ではない人向けの整形
# (`[Dict] [Key] …`)で出てくるので、読めなくなる(`Executable=…` の行は標準エラー出力へ出る)
CODESIGN_ENTITLEMENTS_ARGS = ["--entitlements", "-", "--xml"]


def read_entitlements(path):
    """署名済みのコード(.app や実行ファイル)のエンタイトルメントを辞書で返す。読めなければ {}"""
    result = subprocess.run(["codesign", "-d", *CODESIGN_ENTITLEMENTS_ARGS, path], capture_output=True, text=True)
    if not result.stdout.strip():
        return {}
    try:
        data = plistlib.loads(result.stdout.encode("utf-8"))
    except Exception:  # noqa: BLE001 - plist でない出力(構文が合わない・署名がない)は「読めない」として扱う
        return {}
    return data if isinstance(data, dict) else {}


def check_signed(report, app):
    """署名済み archive の確認(想定外の挙動で止めないよう、問題は warning にとどめる)"""
    verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", app], capture_output=True, text=True)
    if verify.returncode == 0:
        report.ok("codesign --verify", "署名は有効")
    else:
        report.warn("codesign --verify", (verify.stderr or verify.stdout).strip()[:300])
    entitlements = read_entitlements(app)
    if not entitlements:
        report.warn("署名のエンタイトルメント", "読み取れませんでした")
        return
    groups = entitlements.get("com.apple.security.application-groups") or []
    report.check(bool(groups), "署名のエンタイトルメント: App Group", ", ".join(groups), "App Group が署名に入っていません")
    aps = entitlements.get("aps-environment")
    if aps:
        report.ok("署名のエンタイトルメント: aps-environment", f"{aps}(archive は開発署名。配布の書き出しで production に替わる)")
    else:
        report.fail("署名のエンタイトルメント: aps-environment", "ありません(push が届かないビルドになる)")


def verify(archive, build_number, supabase_mode, signed):
    report = Report()
    app = os.path.join(archive, "Products", "Applications", "Lien.app")
    if not os.path.isdir(app):
        report.fail("archive の構成", f"{os.path.relpath(app)} がありません(アプリの archive になっていません)")
        return report

    base_id = read_xcconfig("LIEN_BUNDLE_ID_BASE")
    version = read_xcconfig("MARKETING_VERSION")
    report.check(
        re.match(r"^\d+\.\d+\.\d+$", version) is not None, "MARKETING_VERSION (Base.xcconfig)",
        version, f"{version!r} は x.y.z 形式ではありません",
    )

    info = check_bundle(report, "Lien (アプリ)", app, base_id, version, build_number)
    check_bundle(
        report, "LienWidget", os.path.join(app, "PlugIns", "LienWidget.appex"),
        f"{base_id}.widget", version, build_number, "com.apple.widgetkit-extension",
    )
    check_bundle(
        report, "LienNSE", os.path.join(app, "PlugIns", "LienNSE.appex"),
        f"{base_id}.nse", version, build_number, "com.apple.usernotifications.service",
    )

    if info is not None:
        major = sdk_major(info.get("DTSDKName"))
        report.check(
            major is not None and major >= 26, "ビルドに使った SDK",
            f"{info.get('DTSDKName')}(Xcode {info.get('DTXcode')})",
            f"{info.get('DTSDKName')!r} は iOS 26 SDK 未満(2026-04-28 以降は Xcode 26 / iOS 26 SDK 必須)",
        )
        report.check(
            info.get("ITSAppUsesNonExemptEncryption") is False, "ITSAppUsesNonExemptEncryption",
            "false(輸出コンプライアンスの質問を省く)", f"{info.get('ITSAppUsesNonExemptEncryption')!r}",
        )
        icons = (info.get("CFBundleIcons") or {}).get("CFBundlePrimaryIcon") or {}
        icon_name = info.get("CFBundleIconName") or (icons.get("CFBundleIconName") if isinstance(icons, dict) else None)
        report.check(os.path.isfile(os.path.join(app, "Assets.car")), "Assets.car (AppIcon を含むカタログ)", "あり", "ありません")
        if icon_name == "AppIcon":
            report.ok("CFBundleIconName", "AppIcon")
        else:
            report.warn("CFBundleIconName", f"AppIcon が Info.plist に見つかりません(icons={icons!r}, name={icon_name!r})")

        # Supabase 接続情報
        errors, warnings = supabase_config.validate(info.get("SUPABASE_URL", ""), info.get("SUPABASE_ANON_KEY", ""))
        for message in warnings:
            report.warn("Supabase 接続情報", message)
        dangerous = [m for m in errors if m.startswith(supabase_config.DANGER)]
        if not errors:
            report.ok("Supabase 接続情報", "URL・anon キーが入っている(値は表示しない)")
        elif supabase_mode == "strict" or dangerous:
            # service_role / secret キーの同梱は、dry-run でも必ず失敗にする
            for message in errors:
                report.fail("Supabase 接続情報", message)
        else:
            report.warn("Supabase 接続情報", "; ".join(errors) + "(dry-run のため警告にとどめる。TestFlight にはアップロードしない)")

    check_release_configuration(report, os.path.join(app, "Lien"))

    dsym = os.path.join(archive, "dSYMs", "Lien.app.dSYM")
    if os.path.isdir(dsym):
        report.ok("dSYM", "Lien.app.dSYM")
    else:
        report.warn("dSYM", "Lien.app.dSYM がありません(クラッシュログの解析ができなくなる)")

    if signed:
        check_signed(report, app)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("archive")
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--supabase", choices=["strict", "warn"], default="strict")
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--summary", help="結果の表(Markdown)を追記するファイル(GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv)

    report = verify(os.path.abspath(args.archive.rstrip("/")), args.build_number, args.supabase, args.signed)
    table = report.markdown()
    print()
    print(table)
    print()
    print(f"エラー {report.errors} 件 / 注意 {report.warnings} 件")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("## archive の検査\n\n" + table + f"\n\nエラー {report.errors} 件 / 注意 {report.warnings} 件\n\n")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
