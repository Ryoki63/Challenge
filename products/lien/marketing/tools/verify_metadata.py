#!/usr/bin/env python3
"""T32準備 完了条件の自己検証(CI でも実行)。

検証対象は `products/lien/marketing/store_metadata/ja/` 配下の確定値ファイル
(App Store Connect に実際に投入する文言)。`store_metadata/alternatives.md` は
不採用案・リスク注記を保存する参考ドキュメントであり、ストアに提出しないため
本スクリプトの検証対象外(存在チェックのみ行う)。

検証内容:
  1. 必須ファイルが全て存在する(store_metadata/ja/*.txt 6本 + alternatives.md)
  2. 文字数制限(App Store Connect の入力上限)
     - name.txt            <= 30
     - subtitle.txt        <= 30
     - keywords.txt        <= 100 (カンマ区切り。空白を含めない運用も確認)
     - promotional_text.txt <= 170
     - description.txt     <= 4000
     - release_notes.txt    <= 4000
  3. 罰なし原則(REQUIREMENTS §3.5 / DESIGN §3.8)の禁止ワードを含まないこと。
     パターンは `products/lien/supabase/functions/_shared/messages_test.ts` の
     BANNED_PATTERN と同一の語を使う(そのファイルは編集しない。本スクリプトに
     複製して保持する)

既知の未確定事項(要確認。alternatives.md にも記載):
  - Apple の文字数カウント方式(Unicode コードポイント単位か、UTF-16 コード
    ユニット単位か、バイト数か)を一次情報で確認できていない。本スクリプトは
    「コードポイント数」と「UTF-16 コードユニット数」の**大きい方**を使う
    保守的(厳しい方)カウントで判定する。これにより、どちらの方式で数えても
    本スクリプトを通過した文言は上限を超えない

使い方:
  python3 verify_metadata.py   # 失敗時 exit 1
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MARKETING_DIR = os.path.normpath(os.path.join(HERE, ".."))
STORE_METADATA_DIR = os.path.join(MARKETING_DIR, "store_metadata")
JA_DIR = os.path.join(STORE_METADATA_DIR, "ja")
ALTERNATIVES_PATH = os.path.join(STORE_METADATA_DIR, "alternatives.md")

# ファイル名 -> 文字数上限(App Store Connect の仕様値。aso.md / #32 進め方コメント記載の値を踏襲)
LIMITS = {
    "name.txt": 30,
    "subtitle.txt": 30,
    "keywords.txt": 100,
    "promotional_text.txt": 170,
    "description.txt": 4000,
    "release_notes.txt": 4000,
}

REQUIRED_FILES = list(LIMITS.keys())

# 罰・恥・煽り系の禁止ワード(REQUIREMENTS §3.5 / DESIGN §3.8)。
# products/lien/supabase/functions/_shared/messages_test.ts の BANNED_PATTERN と
# 同一の語を保つ(そのファイルは編集しない。ここに同じ語を複製して流用する)。
BANNED_PATTERN = re.compile(r"枯れ|サボ|罰|恥|ダメ|怒|遅い|まだやってない")

errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


def effective_length(text):
    """保守的な文字数カウント(要確認: Apple の正確なカウント方式は未確認)。

    Unicode コードポイント数と UTF-16 コードユニット数の大きい方を返す。
    基本多言語面(BMP)の文字(日本語含む)はどちらでも 1 として数えられるため
    この2方式では差が出ない。絵文字など補助面の文字が入ると UTF-16 では
    サロゲートペア=2 ユニットとして数えられるため、こちらの方が厳しくなる。
    """
    codepoints = len(text)
    utf16_units = len(text.encode("utf-16-le")) // 2
    return max(codepoints, utf16_units)


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        # 末尾の改行はテキストファイル作成時の付随物であり、ストア入力欄に
        # そのまま貼る実内容ではないため、長さ判定からは除外する。
        return f.read().rstrip("\n")


def main():
    # 1) 必須ファイル存在チェック
    check(os.path.isdir(JA_DIR), "missing directory: %s" % JA_DIR)
    for name in REQUIRED_FILES:
        path = os.path.join(JA_DIR, name)
        check(os.path.isfile(path), "missing required file: %s" % path)
    check(os.path.isfile(ALTERNATIVES_PATH),
          "missing required file: %s" % ALTERNATIVES_PATH)

    if errors:
        # 必須ファイルが無い状態で以降のチェックを続けると無意味な例外になるため、
        # ここで一旦打ち切って報告する。
        for e in errors:
            print("NG: %s" % e)
        return 1

    # 2) 文字数制限 + 3) 禁止ワード
    texts = {}
    for name in REQUIRED_FILES:
        path = os.path.join(JA_DIR, name)
        text = read_text(path)
        texts[name] = text

        check(len(text) > 0, "%s: empty content" % name)

        limit = LIMITS[name]
        length = effective_length(text)
        check(length <= limit,
              "%s: length %d exceeds limit %d" % (name, length, limit))

        m = BANNED_PATTERN.search(text)
        check(m is None,
              "%s: contains banned word (罰なし原則違反): %r" % (name, m.group() if m else None))

    # keywords.txt 固有の形式チェック(カンマ区切り・空白なし・重複なし)
    if "keywords.txt" in texts:
        kw_text = texts["keywords.txt"]
        check("\n" not in kw_text, "keywords.txt: must be a single line")
        terms = kw_text.split(",")
        check(all(t.strip() == t and t != "" for t in terms),
              "keywords.txt: terms must not be empty or have leading/trailing whitespace: %r" % terms)
        check(" " not in kw_text,
              "keywords.txt: must not contain spaces (comma-separated, no spaces)")
        check(len(terms) == len(set(terms)),
              "keywords.txt: duplicate terms found: %r" % terms)

    if errors:
        for e in errors:
            print("NG: %s" % e)
        return 1

    print("OK: store_metadata/ja/*.txt (6 files) + alternatives.md verified "
          "(limits + 罰なし原則 banned-word check)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
