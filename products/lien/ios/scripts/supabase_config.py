#!/usr/bin/env python3
"""Supabase 接続情報(SUPABASE_URL / SUPABASE_ANON_KEY)の検証と Secrets.xcconfig の生成(issue #28)。

Config(アプリ側の Config.swift)は「空・雛形のまま・変数が展開されずに残った値」を未設定として扱い、
Release ビルドでは起動時に止まる。ここはその手前 — **TestFlight へ上げる前に、archive の Info.plist に
正しい接続情報が入っていること**を CI で確かめる側。

  python3 supabase_config.py write-xcconfig [--out PATH]
      環境変数 SUPABASE_URL / SUPABASE_ANON_KEY を検証し、Config/Secrets.xcconfig を書く
      (xcconfig では // がコメントになるので URL の // は /$()/ に置き換える)
  python3 supabase_config.py check-plist INFO_PLIST [--warn-only]
      Info.plist の値を検証する。--warn-only なら問題があっても終了コード 0(警告にとどめる)

値そのものは出力しない(URL もキーも。anon キーは公開前提だが、ログに残さない習慣にする)。
アプリに同梱してはいけない service_role / secret キーが入っていたら必ずエラーにする。
Python 3.9+ の標準ライブラリだけで動く。
"""

import argparse
import base64
import json
import os
import plistlib
import re
import sys

URL_KEY = "SUPABASE_URL"
ANON_KEY = "SUPABASE_ANON_KEY"

DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Config", "Secrets.xcconfig")

# アプリに同梱してはいけないキー(service_role / secret)を見つけたときのエラーの先頭に付ける印。
# --warn-only(dry-run)でも、この印が付いたエラーは警告に落とさず必ず失敗にする
DANGER = "[危険] "

_HOST_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$")
_KEY_CHARS_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def is_unset(value):
    """Config.swift の Config.isUnset と同じ規則(空・雛形のまま・展開されずに残った $(…))"""
    v = (value or "").strip()
    return v == "" or "YOUR-PROJECT-REF" in v or "YOUR_SUPABASE_ANON_KEY" in v or v.startswith("$(")


def validate_url(value):
    """(errors, warnings) を返す。値は含めない"""
    errors, warnings = [], []
    if is_unset(value):
        return [f"{URL_KEY} が未設定(空・雛形のまま・変数が展開されていない)"], warnings
    v = value.strip()
    if not v.startswith("https://"):
        errors.append(f"{URL_KEY} は https:// で始まる必要がある")
        return errors, warnings
    rest = v[len("https://"):].rstrip("/")
    if "/" in rest or "?" in rest or "#" in rest or " " in rest:
        errors.append(f"{URL_KEY} にパス・クエリ・空白を付けない(https://<project-ref>.supabase.co の形)")
        return errors, warnings
    host = rest.split(":")[0]
    if not _HOST_RE.match(host):
        errors.append(f"{URL_KEY} のホスト名の形が不正")
    elif not host.endswith(".supabase.co"):
        warnings.append(f"{URL_KEY} のホストが *.supabase.co ではない(独自ドメインなら問題なし。取り違えでないか確認)")
    return errors, warnings


def _jwt_role(token):
    """JWT 形式なら payload の role を返す(JWT でない・読めないなら None)"""
    parts = token.split(".")
    if len(parts) != 3 or not token.startswith("eyJ"):
        return None
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        data = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except (ValueError, UnicodeError):
        return None
    role = data.get("role") if isinstance(data, dict) else None
    return role if isinstance(role, str) else None


def validate_anon_key(value):
    """(errors, warnings) を返す。service_role / secret キーは必ずエラー"""
    errors, warnings = [], []
    if is_unset(value):
        return [f"{ANON_KEY} が未設定(空・雛形のまま・変数が展開されていない)"], warnings
    v = value.strip()
    if v.startswith("sb_secret_"):
        return [f"{DANGER}{ANON_KEY} に secret キー(sb_secret_…)が入っている。アプリに同梱すると漏れる。publishable / anon キーを使う"], warnings
    if not _KEY_CHARS_RE.match(v):
        return [f"{ANON_KEY} に使えない文字が含まれる(英数字と . _ - だけ)"], warnings
    role = _jwt_role(v)
    if role is not None:
        if role == "service_role":
            return [f"{DANGER}{ANON_KEY} に service_role キーが入っている。アプリに同梱すると DB が丸見えになる。anon キーを使う"], warnings
        if role != "anon":
            errors.append(f"{ANON_KEY} の JWT の role が anon ではない")
    elif v.startswith("sb_publishable_"):
        pass
    else:
        warnings.append(f"{ANON_KEY} の形式が anon JWT でも sb_publishable_ でもない(新しい形式なら問題なし)")
    if len(v) < 20:
        errors.append(f"{ANON_KEY} が短すぎる(コピー漏れ?)")
    return errors, warnings


def validate(url, anon_key):
    errors, warnings = [], []
    for fn, value in ((validate_url, url), (validate_anon_key, anon_key)):
        e, w = fn(value)
        errors += e
        warnings += w
    return errors, warnings


def xcconfig_escape(value):
    """xcconfig では // がコメント開始になるので、// を /$()/ に置き換える"""
    return value.replace("//", "/$()/")


def render_xcconfig(url, anon_key):
    return (
        "// Secrets.xcconfig — lien-release が GitHub Secrets から生成(コミットしない。gitignore 済み)\n"
        f"{URL_KEY} = {xcconfig_escape(url.strip().rstrip('/'))}\n"
        f"{ANON_KEY} = {xcconfig_escape(anon_key.strip())}\n"
    )


def _annotate(level, message):
    """GitHub Actions では注釈(::error:: / ::warning::)、それ以外は普通の行"""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::{level}::{message}")
    else:
        print(f"{level}: {message}")


def cmd_write_xcconfig(args):
    url = os.environ.get(URL_KEY, "")
    key = os.environ.get(ANON_KEY, "")
    errors, warnings = validate(url, key)
    for w in warnings:
        _annotate("warning", w)
    if errors:
        for e in errors:
            _annotate("error", e)
        return 1
    out = os.path.abspath(args.out)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(render_xcconfig(url, key))
    os.chmod(out, 0o600)
    print(f"Secrets.xcconfig を書きました: {os.path.relpath(out)}(値は表示しません)")
    return 0


def cmd_check_plist(args):
    with open(args.plist, "rb") as fh:
        info = plistlib.load(fh)
    url = info.get(URL_KEY, "")
    key = info.get(ANON_KEY, "")
    errors, warnings = validate(url if isinstance(url, str) else "", key if isinstance(key, str) else "")
    for w in warnings:
        _annotate("warning", w)
    if errors:
        dangerous = any(e.startswith(DANGER) for e in errors)
        level = "warning" if args.warn_only and not dangerous else "error"
        for e in errors:
            _annotate(level, f"{os.path.basename(os.path.dirname(args.plist)) or args.plist}: {e}")
        if args.warn_only and not dangerous:
            print("接続情報が入っていない archive です(dry-run のため警告にとどめます)。TestFlight にはアップロードしません")
            return 0
        return 1
    print("Info.plist の Supabase 接続情報: OK(値は表示しません)")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    w = sub.add_parser("write-xcconfig", help="環境変数から Secrets.xcconfig を作る")
    w.add_argument("--out", default=DEFAULT_OUT)
    w.set_defaults(func=cmd_write_xcconfig)
    c = sub.add_parser("check-plist", help="Info.plist の接続情報を検証する")
    c.add_argument("plist")
    c.add_argument("--warn-only", action="store_true")
    c.set_defaults(func=cmd_check_plist)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
