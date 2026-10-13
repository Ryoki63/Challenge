#!/usr/bin/env python3
"""リリースの前に、利用者と審査員に見える「外向きの入力」が揃っているかを確かめる(issue #23 のレビュー指摘)。

  python3 check_release_inputs.py [--require] [--summary FILE] [--support-links PATH]

見るもの(Lien/Core/SupportLinks.swift の値。G4 #42 で人間が確定する):
  1. 運営者の連絡先 `contactEmail` が空でなく、メールアドレスの形であること。
     空のままだと、通報・お問い合わせのメールが宛先なしの下書きで開く(App Store ガイドライン 1.2: 利用者が連絡できること)
  2. 利用規約 `termsURL`・プライバシーポリシー `privacyURL` の公開先が HTTP 200 で返ること。
     404 のままだと、アプリの規約同意のリンクも、審査の App Privacy のポリシー URL も開けない(Pages 公開は TASKPLAN §9.2)

  - --require あり: 1 つでも満たさなければ終了コード 1(リリースを止める)。確かめられなかった(通信の失敗)ときも止める
  - --require なし: 結果と注意を表示するだけで、終了コードは 0(dry-run が、この経路を毎回通して確かめるため)

lien-release では、dry_run=false のとき既定で --require を付ける。内部 TestFlight だけに使うビルド(G4 の前の最初のアップロードなど)は、
`internal_only` を true にして --require を外す(その場合も、結果は step summary に注意として残る。外部テスト・審査には使えない)。

Python 3.9+ の標準ライブラリだけで動く。
"""

import argparse
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
IOS_DIR = os.path.dirname(HERE)
DEFAULT_SUPPORT_LINKS = os.path.join(IOS_DIR, "Lien", "Core", "SupportLinks.swift")

# メールアドレスの一般的な形(ReportComposer が宛先に許す文字の範囲)
EMAIL_RE = re.compile(r"^[A-Za-z0-9._+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}$")
FETCH_TIMEOUT_SECONDS = 20


def parse_support_links(text):
    """SupportLinks.swift から (contactEmail, termsURL, privacyURL) を取り出す。形が変わって読めなければ ValueError"""

    def grab(pattern, name):
        match = re.search(pattern, text)
        if not match:
            raise ValueError(f"SupportLinks.swift から {name} を読めません(書式が変わった? このスクリプトの正規表現を直してください)")
        return match.group(1)

    base = grab(r'static let webBaseURL = "([^"]+)"', "webBaseURL")

    def expand(raw):
        return raw.replace("\\(webBaseURL)", base)

    terms = expand(grab(r'static let termsURL: URL = url\("([^"]+)"\)', "termsURL"))
    privacy = expand(grab(r'static let privacyURL: URL = url\("([^"]+)"\)', "privacyURL"))
    email = grab(r'static let contactEmail = "([^"]*)"', "contactEmail")
    return email.strip(), terms, privacy


def fetch_status(url, timeout=FETCH_TIMEOUT_SECONDS):
    """URL を GET して HTTP ステータスを返す(リダイレクトは辿る)。通信の失敗は None"""
    request = urllib.request.Request(url, headers={"User-Agent": "lien-release-check/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 — https の公開ページだけ
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except (urllib.error.URLError, OSError, ValueError):
        return None


def check(email, terms_url, privacy_url, fetch=fetch_status):
    """[(ok, 項目, 詳細)]。ok=False が 1 つでもあれば、外部テスト・審査には出せない"""
    rows = []
    if not email:
        rows.append((False, "運営者の連絡先", "SupportLinks.contactEmail が空です(G4 #42 で確定して埋める)。通報・お問い合わせのメールが宛先なしで開きます"))
    elif not EMAIL_RE.match(email):
        rows.append((False, "運営者の連絡先", f"SupportLinks.contactEmail がメールアドレスの形ではありません: {email}"))
    else:
        rows.append((True, "運営者の連絡先", "設定済み"))

    for label, url in (("利用規約のページ", terms_url), ("プライバシーポリシーのページ", privacy_url)):
        status = fetch(url)
        if status == 200:
            rows.append((True, label, f"{url} は HTTP 200"))
        elif status is None:
            rows.append((False, label, f"{url} を確かめられませんでした(通信の失敗)。もう一度実行してください"))
        else:
            rows.append((False, label, f"{url} が HTTP {status} です(Pages への公開が済んでいない? TASKPLAN §9.2)"))
    return rows


def markdown(rows, require):
    lines = ["## 外向きの入力(連絡先・規約のページ)", "", "| 結果 | 項目 | 詳細 |", "|---|---|---|"]
    for ok, item, detail in rows:
        lines.append(f"| {'OK' if ok else '**NG**'} | {item} | {detail} |")
    if all(ok for ok, _, _ in rows):
        lines += ["", "- すべて揃っています"]
    elif require:
        lines += ["", "- 揃っていないので、リリースを止めます(内部 TestFlight だけに使うビルドなら、`internal_only` を true にして実行し直す)"]
    else:
        lines += ["", "- **揃っていません。このビルドは外部テスト・審査には使えません**(内部 TestFlight 向けとして上げるのは構いません)"]
    return "\n".join(lines) + "\n"


def main(argv=None, fetch=fetch_status):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--require", action="store_true", help="揃っていないものがあれば終了コード 1(無ければ表示だけ)")
    parser.add_argument("--summary", help="結果の表(Markdown)を追記するファイル(GITHUB_STEP_SUMMARY)")
    parser.add_argument("--support-links", default=DEFAULT_SUPPORT_LINKS, help="SupportLinks.swift のパス(テスト用)")
    args = parser.parse_args(argv)

    try:
        with open(args.support_links, encoding="utf-8") as fh:
            email, terms_url, privacy_url = parse_support_links(fh.read())
    except (OSError, ValueError) as error:
        print(f"::error::{error}")
        return 2

    rows = check(email, terms_url, privacy_url, fetch)
    for ok, item, detail in rows:
        if ok:
            print(f"OK   {item}: {detail}")
        elif args.require:
            print(f"::error::{item}: {detail}")
        else:
            print(f"::warning::{item}: {detail}")
    report = markdown(rows, args.require)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("\n" + report)
    if args.require and not all(ok for ok, _, _ in rows):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
