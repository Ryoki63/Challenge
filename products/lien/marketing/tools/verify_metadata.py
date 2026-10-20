#!/usr/bin/env python3
"""T32 ストアメタデータの自己検証(CI でも実行)。

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
  4. keywords.txt の形式(1行・カンマ区切り・前後空白なし・語の重複なし・
     語同士の包含重複なし。「継続」と「継続力」のような重複は索引の無駄)
  5. keywords.txt が表示名・サブタイトルで既に索引される語を繰り返していないこと。
     Apple は表示名・サブタイトル・キーワードを合わせて検索索引にするため、
     同じ語をキーワード欄に置いても索引は増えない(issue #32 の「検証」に記載の検査)
  6. 競合サービス名(Pairy 系)を含まないこと。
     docs/TASKPLAN.md §9.4 の T32「Pairy 語は全廃」と alternatives.md §3.2 の
     判断を機械的に担保する(将来の編集でうっかり戻るのを防ぐ)

既知の未確定事項(要確認。alternatives.md にも記載):
  - Apple の文字数カウント方式(Unicode コードポイント単位か、UTF-16 コード
    ユニット単位か、バイト数か)を一次情報で確認できていない。本スクリプトは
    「コードポイント数」と「UTF-16 コードユニット数」の**大きい方**を使う
    保守的(厳しい方)カウントで判定する。これにより、どちらの方式で数えても
    本スクリプトを通過した文言は上限を超えない

使い方:
  python3 verify_metadata.py            # 失敗時 exit 1
  python3 verify_metadata.py --print    # 検証が緑のとき、ASC に貼る値を表示する
"""

import os
import re
import sys
import unicodedata

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

# 競合サービス名(TASKPLAN §9.4 T32「Pairy 語は全廃」)。
# NFKC 正規化 + 小文字化してから部分一致で見るので、全角/半角・大文字小文字の
# 表記ゆれも拾う。「ペアリ」は「ペアリング」等の一般語に当たるため入れない。
COMPETITOR_TERMS = ("pairy", "ぺあり", "ペアリー")


def normalize(text):
    """比較用に NFKC 正規化 + 小文字化する(全角英字・大文字小文字の表記ゆれ対策)。"""
    return unicodedata.normalize("NFKC", text).casefold()


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


def load_fields(ja_dir):
    return {name: read_text(os.path.join(ja_dir, name)) for name in REQUIRED_FILES}


def competitor_hits(text):
    normalized = normalize(text)
    return sorted({t for t in COMPETITOR_TERMS if t in normalized})


def keyword_terms(text):
    return text.split(",")


def indexed_tokens(fields):
    """表示名・サブタイトルから、記号・空白で区切った語を取り出す。

    形態素解析はしない(標準ライブラリだけで完結させるため)。「静かに続く習慣アプリ」
    のような助詞混じりの塊が1語になるので、この関数は補助的な検査にだけ使う。
    """
    text = normalize(fields["name.txt"] + " " + fields["subtitle.txt"])
    return [t for t in re.split(r"[^0-9a-z\u3040-\u30ff\u4e00-\u9fff]+", text) if len(t) >= 2]


def keyword_overlaps(fields):
    """キーワード欄が表示名・サブタイトルと重複している語を返す。"""
    indexed = normalize(fields["name.txt"] + fields["subtitle.txt"])
    tokens = indexed_tokens(fields)
    hits = []
    for term in keyword_terms(fields["keywords.txt"]):
        normalized = normalize(term)
        if not normalized:
            continue
        if normalized in indexed:
            hits.append((term, "表示名またはサブタイトルにそのまま含まれる"))
            continue
        for token in tokens:
            if token in normalized:
                hits.append((term, "表示名/サブタイトルの語 %r を含む" % token))
                break
    return hits


def internal_duplicates(terms):
    """キーワード同士の包含重複(「継続」と「継続力」など)を返す。"""
    hits = []
    for a in terms:
        for b in terms:
            if a != b and a and b and a in b:
                hits.append((a, b))
    return hits


def collect_errors(fields):
    """確定値の dict を検査して、エラーメッセージのリストを返す(空なら緑)。"""
    errors = []

    for name in REQUIRED_FILES:
        text = fields.get(name, "")
        if text == "":
            errors.append("%s: empty content" % name)

        limit = LIMITS[name]
        length = effective_length(text)
        if length > limit:
            errors.append("%s: length %d exceeds limit %d" % (name, length, limit))

        m = BANNED_PATTERN.search(text)
        if m is not None:
            errors.append("%s: contains banned word (罰なし原則違反): %r" % (name, m.group()))

        hits = competitor_hits(text)
        if hits:
            errors.append(
                "%s: contains competitor name(s) %s (Pairy 語は全廃: TASKPLAN §9.4)"
                % (name, ", ".join(repr(h) for h in hits))
            )

    keywords = fields.get("keywords.txt", "")
    if keywords:
        if "\n" in keywords:
            errors.append("keywords.txt: must be a single line")
        terms = keyword_terms(keywords)
        if any(t.strip() != t or t == "" for t in terms):
            errors.append(
                "keywords.txt: terms must not be empty or have leading/trailing whitespace: %r"
                % terms
            )
        if " " in keywords:
            errors.append("keywords.txt: must not contain spaces (comma-separated, no spaces)")
        if len(terms) != len(set(terms)):
            errors.append("keywords.txt: duplicate terms found: %r" % terms)
        for short, long in internal_duplicates(terms):
            errors.append(
                "keywords.txt: %r is contained in %r (索引の無駄)" % (short, long)
            )
        for term, reason in keyword_overlaps(fields):
            errors.append(
                "keywords.txt: %r duplicates the name/subtitle (%s)" % (term, reason)
            )

    return errors


def print_values(fields):
    headings = {
        "name.txt": "App 情報 > 名前",
        "subtitle.txt": "App 情報 > サブタイトル",
        "keywords.txt": "バージョン情報 > キーワード",
        "promotional_text.txt": "バージョン情報 > プロモーションテキスト",
        "description.txt": "バージョン情報 > 説明",
        "release_notes.txt": "バージョン情報 > このバージョンの新機能",
    }
    print("===== App Store Connect 貼り付け用(正本: store_metadata/ja/)=====")
    for name in REQUIRED_FILES:
        print("--- %s (%s, %d/%d) ---" % (headings[name], name, effective_length(fields[name]), LIMITS[name]))
        print(fields[name])
        print()


def main(argv):
    show_values = "--print" in argv
    errors = []

    if not os.path.isdir(JA_DIR):
        errors.append("missing directory: %s" % JA_DIR)
    for name in REQUIRED_FILES:
        path = os.path.join(JA_DIR, name)
        if not os.path.isfile(path):
            errors.append("missing required file: %s" % path)
    if not os.path.isfile(ALTERNATIVES_PATH):
        errors.append("missing required file: %s" % ALTERNATIVES_PATH)

    if errors:
        # 必須ファイルが無い状態で以降のチェックを続けると無意味な例外になるため、
        # ここで一旦打ち切って報告する。
        for e in errors:
            print("NG: %s" % e)
        return 1

    fields = load_fields(JA_DIR)
    errors = collect_errors(fields)
    if errors:
        for e in errors:
            print("NG: %s" % e)
        return 1

    print(
        "OK: store_metadata/ja/*.txt (6 files) + alternatives.md verified "
        "(limits + 罰なし原則 + keywords 重複 + Pairy 語の不在). "
        "keywords %d/%d 字"
        % (effective_length(fields["keywords.txt"]), LIMITS["keywords.txt"])
    )

    if show_values:
        print()
        print_values(fields)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
