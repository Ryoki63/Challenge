#!/usr/bin/env python3
"""check_posts.py — X 投稿案（issue #75 / MK2）の静的検査。

検査する内容:
  1. ファイル名が `YYYY-MM-DD.md` で、想定した13本（10/21〜10/31 + 公開翌日 + 1週間後）が揃っている
  2. 必須フィールド（日付 / status / 種別 / 投稿予定 / 添付画像 / 代替テキスト / 根拠 / リンク先 / 数値の根拠）
  3. 本文が 140 字以内（X の重み付きカウントに合わせた保守的な数え方）
  4. 罰・恥・煽り系の禁止語と誇大表現を含まない（アプリ本体の lint と同じ8語 + 投稿用の追加語）
  5. 競合サービス名を含まない（TASKPLAN §9.4 の Pairy 語全廃）
  6. 本文で日付・年を断定していない（公開日は審査結果に依存するため）
  7. 本文の数字がすべて `数値の根拠` に説明されている
  8. `根拠` の節（docs/*.md §N / §N.M / §N-M）が実在する
  9. `添付画像` のパスが実在する（`指定:` で始まる場合は、素材ができるまで投稿しない予約として許可）
 10. 承認が揃う前に `status: ready` にしていない（review.md の台帳と各ファイルのチェックボックスの両方を見る）
 11. `branding.md`（X アカウントのブランディング案）の表示名・bio・@handle・固定ポストも同じ原則で検査する

使い方:
  python3 tools/check_posts.py          # 失敗時 exit 1
"""

import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
X_DIR = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(X_DIR, "..", "..", "..", ".."))
REVIEW_MD = os.path.join(X_DIR, "review.md")
BRANDING_MD = os.path.join(X_DIR, "branding.md")

# 想定する13本（日付 -> 種別）。日次10本は 10/21〜10/30、10/31 は公開日告知。
EXPECTED = {
    "2026-10-21": "開発ストーリー 1/10",
    "2026-10-22": "開発ストーリー 2/10",
    "2026-10-23": "開発ストーリー 3/10",
    "2026-10-24": "開発ストーリー 4/10",
    "2026-10-25": "開発ストーリー 5/10",
    "2026-10-26": "開発ストーリー 6/10",
    "2026-10-27": "開発ストーリー 7/10",
    "2026-10-28": "開発ストーリー 8/10",
    "2026-10-29": "開発ストーリー 9/10",
    "2026-10-30": "開発ストーリー 10/10",
    "2026-10-31": "公開日",
    "2026-11-01": "公開翌日",
    "2026-11-07": "1週間後",
}

# 公開後に投稿する3本。リンク先に実際のストア URL が必要。
POST_RELEASE_TYPES = {"公開日", "公開翌日", "1週間後"}

REQUIRED_FIELDS = (
    "日付",
    "status",
    "種別",
    "投稿予定",
    "添付画像",
    "代替テキスト",
    "根拠",
    "リンク先",
    "数値の根拠",
)

BODY_LIMIT = 140

# X のプロフィール上限（表示名 50 字 / bio 160 字 / @handle 15 字）。
NAME_LIMIT = 50
BIO_LIMIT = 160
HANDLE_RE = re.compile(r"@[A-Za-z0-9_]{1,15}")

# branding.md の推奨値フィールド（`- 表示名 A（推奨）: `...`` / `- bio A（推奨）: `...``）
BRANDING_FIELD = re.compile(r"^-\s+(表示名|@handle|bio)([^:]*):\s*(.+)$", re.MULTILINE)
FIELD_VALUE = re.compile(r"`([^`]+)`")

# アプリ本体の禁止語（LienTests/StringsReviewTests.swift の PunishmentFreeLint.bannedWords と同じ8語）。
# 投稿でも同じ語を使わない（REQUIREMENTS §3.5 / DESIGN §3.8）。
APP_BANNED = re.compile(r"枯れ|サボ|罰|恥|ダメ|怒|遅い|まだやってない")

# 投稿用の追加禁止語。誇大表現・煽り・価格の断定（aso.md §4 の運用に合わせる）。
# 「最高記録」を消さないため「最高」は入れない。
MARKETING_BANNED = re.compile(
    r"失敗|逃す|急げ|今すぐ|絶対|必ず|日本一|No\.?\s?1|業界初|唯一|永久無料|完全無料|"
    r"最強|神アプリ|誰でも|限定|保証|確実"
)

# 競合サービス名（TASKPLAN §9.4 T32「Pairy 語は全廃」）。表記ゆれは NFKC + casefold で吸収する。
COMPETITOR_TERMS = ("pairy", "ぺあり", "ペアリー")

# 本文での日付断定（月日・スラッシュ表記・年）
DATE_ASSERTION = re.compile(r"\d{1,2}\s*月\s*\d{1,2}\s*日|\d{1,2}/\d{1,2}|\d{4}\s*年")

NUMERAL = re.compile(r"[0-9]+(?:[.,][0-9]+)*")

DOC_PATHS = {
    "CONCEPT": "docs/CONCEPT.md",
    "REQUIREMENTS": "docs/REQUIREMENTS.md",
    "GROWTH": "docs/GROWTH.md",
}

DOC_TOKEN = re.compile(r"(docs/(?:CONCEPT|REQUIREMENTS|GROWTH)\.md)")
SECTION_REF = re.compile(r"§\s*([0-9]+(?:[.\-][0-9]+)?)")


def doc_refs(text):
    """「docs/X.md §1（…）・§3 / docs/Y.md §0」から (path, ref) をすべて取り出す。

    節の参照は、直前のファイル名を引き継ぐ（`docs/CONCEPT.md §1・§3` の §3 も
    CONCEPT の参照として扱う）。1フィールドに複数の節を書けるようにするため。
    """
    refs = []
    parts = DOC_TOKEN.split(text)
    current = None
    for part in parts:
        if DOC_TOKEN.fullmatch(part):
            current = part
            continue
        if current is None:
            continue
        refs.extend((current, ref) for ref in SECTION_REF.findall(part))
    return refs

PLACEHOLDER = "<APP_STORE_URL>"


def normalize(text):
    return unicodedata.normalize("NFKC", text).casefold()


def effective_length(text):
    """保守的な文字数（コードポイント数と UTF-16 コードユニット数の大きい方）。"""
    return max(len(text), len(text.encode("utf-16-le")) // 2)


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def parse_fields(text):
    fields = {}
    for line in text.splitlines():
        m = re.match(r"^-\s+([^:]+):\s*(.+)$", line)
        if m:
            key = m.group(1).strip()
            if key in REQUIRED_FIELDS:
                fields[key] = m.group(2).strip()
    return fields


def body_of(text):
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("## 本文"):
            start = i + 1
            break
    if start is None:
        return None
    out = []
    for line in lines[start:]:
        if line.startswith("## "):
            break
        if line.startswith(">"):
            content = line[1:]
            if content.startswith(" "):
                content = content[1:]
            out.append(content.rstrip())
    return "\n".join(out)


def approvals_of(text):
    """`- [x] mkt-lead` / `- [x] mkt-review` のチェック状態。"""
    lead = re.search(r"^-\s*\[( |x|X)\]\s*mkt-lead", text, re.MULTILINE)
    review = re.search(r"^-\s*\[( |x|X)\]\s*mkt-review", text, re.MULTILINE)
    return {
        "mkt-lead": bool(lead and lead.group(1).lower() == "x"),
        "mkt-review": bool(review and review.group(1).lower() == "x"),
    }


def ledger_of(text):
    """review.md §1 の承認台帳を読む（日付 -> {lead, review}）。

    コードフェンス（```）の中は記入例なので読まない。ここを読んでしまうと、
    例の行を「承認済み」と誤認して status: ready を素通りさせてしまう。
    """
    start = text.find("## 1. 承認台帳")
    if start < 0:
        raise ValueError("review.md に「## 1. 承認台帳」がありません")
    end = text.find("\n## ", start + 1)
    section = text[start:] if end < 0 else text[start:end]
    ledger = {}
    in_fence = False
    for line in section.splitlines():
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or not line.startswith("| 2026-"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        ledger[cells[0]] = {"lead": cells[1], "review": cells[2]}
    return ledger


def section_of_doc(doc_text, major):
    """`## <major>.` の節を切り出す（次の `## ` まで）。"""
    pattern = re.compile(r"^##\s+%s\." % re.escape(major), re.MULTILINE)
    m = pattern.search(doc_text)
    if not m:
        return None
    nxt = re.search(r"^##\s+", doc_text[m.end():], re.MULTILINE)
    return doc_text[m.start():] if not nxt else doc_text[m.start():m.end() + nxt.start()]


def resolve_doc_ref(ref_path, ref):
    """`§5` / `§3.9` / `§5-2` が実在するか。戻り値は None（OK）かエラー文。"""
    full = os.path.join(REPO, ref_path)
    if not os.path.exists(full):
        return "根拠のファイルがありません: %s" % ref_path
    doc_text = read_text(full)
    if "-" in ref:
        major, minor = ref.split("-", 1)
        separator = "-"
    elif "." in ref:
        major, minor = ref.split(".", 1)
        separator = "."
    else:
        major, minor, separator = ref, None, None

    section = section_of_doc(doc_text, major)
    if section is None:
        return "根拠の節がありません: %s §%s" % (ref_path, major)
    if minor is None:
        return None
    if separator == ".":
        if not re.search(r"^###\s+%s\.%s\b" % (re.escape(major), re.escape(minor)), doc_text, re.MULTILINE):
            return "根拠の小節がありません: %s §%s.%s" % (ref_path, major, minor)
        return None
    # §5-2 は「§5 の箇条書き2番目」を指す
    if not re.search(r"^\s*%s\.\s" % re.escape(minor), section, re.MULTILINE):
        return "根拠の項目がありません: %s §%s-%s" % (ref_path, major, minor)
    return None


def validate_post(path, text, ledger):
    """1本の投稿案を検査して、エラーのリストを返す（空なら OK）。"""
    name = os.path.basename(path)
    errors = []

    def err(msg):
        errors.append("%s: %s" % (name, msg))

    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}\.md", name):
        err("ファイル名が YYYY-MM-DD.md ではありません")
    date = name[:-3]
    if date not in EXPECTED:
        err("想定していない日付です（13本のどれでもない）")

    fields = parse_fields(text)
    for key in REQUIRED_FIELDS:
        if not fields.get(key):
            err("必須フィールドがありません: %s" % key)

    if fields.get("日付") and fields["日付"] != date:
        err("日付フィールド (%s) がファイル名と一致しません" % fields["日付"])
    if fields.get("種別") and date in EXPECTED and fields["種別"] != EXPECTED[date]:
        err("種別 (%s) が想定 (%s) と違います" % (fields["種別"], EXPECTED[date]))
    if fields.get("投稿予定"):
        if date not in fields["投稿予定"]:
            err("投稿予定に日付が入っていません: %s" % fields["投稿予定"])
        if "JST" not in fields["投稿予定"]:
            err("投稿予定の時刻に JST が付いていません: %s" % fields["投稿予定"])

    status = fields.get("status")
    if status not in ("draft", "ready"):
        err("status は draft / ready のどちらかにしてください: %r" % status)

    body = body_of(text)
    if body is None:
        err("「## 本文」の節がありません")
        body = ""
    elif not body.strip():
        err("本文が空です")
    if body:
        length = effective_length(body)
        if length > BODY_LIMIT:
            err("本文が %d 字（上限 %d 字）" % (length, BODY_LIMIT))
        for pattern, label in ((APP_BANNED, "罰・恥系の禁止語"), (MARKETING_BANNED, "誇大・煽り表現")):
            m = pattern.search(body)
            if m:
                err("%sを含みます: %r" % (label, m.group(0)))
        hits = [t for t in COMPETITOR_TERMS if t in normalize(body)]
        if hits:
            err("競合サービス名を含みます: %s" % ", ".join(hits))
        m = DATE_ASSERTION.search(body)
        if m:
            err("本文で日付・年を断定しています: %r（公開日は未確定のため「近日公開」を使う）" % m.group(0))
        basis = normalize(fields.get("数値の根拠", ""))
        for token in sorted(set(NUMERAL.findall(normalize(body)))):
            if token not in basis:
                err("本文の数字 %r が「数値の根拠」にありません" % token)

    image = fields.get("添付画像", "")
    if image and not image.startswith("指定:"):
        m = re.search(r"`([^`]+)`", image)
        if not m:
            err("添付画像はパスを `...` で書くか、「指定:」で始めてください")
        elif not os.path.exists(os.path.join(REPO, m.group(1))):
            err("添付画像が見つかりません: %s" % m.group(1))
    if image.startswith("指定:") and status == "ready":
        err("添付画像が「指定:」のまま ready にできません（素材を用意してパスに差し替える）")

    basis_text = fields.get("根拠", "")
    refs = doc_refs(basis_text)
    if not refs:
        err("根拠に docs/*.md §N の参照がありません")
    for ref_path, ref in refs:
        problem = resolve_doc_ref(ref_path, ref)
        if problem:
            err(problem)
    for path in re.findall(r"`([^`]+)`", basis_text):
        if "/" in path and not os.path.exists(os.path.join(REPO, path)):
            err("根拠の実装パスが見つかりません: %s" % path)

    link = fields.get("リンク先", "")
    if link:
        typ = fields.get("種別", "")
        if typ in POST_RELEASE_TYPES and PLACEHOLDER not in link and not link.startswith("https://"):
            err("公開後の投稿には実際の URL（https://）か %s が必要です" % PLACEHOLDER)
        if status == "ready" and typ in POST_RELEASE_TYPES:
            if PLACEHOLDER in link or not link.startswith("https://"):
                err("ストア URL が未確定のまま ready にできません")

    if status == "ready":
        marks = approvals_of(text)
        missing = [k for k, v in marks.items() if not v]
        if missing:
            err("status: ready ですが承認のチェックがありません: %s" % ", ".join(missing))
        row = ledger.get(date)
        if not row:
            err("status: ready ですが review.md の承認台帳に行がありません")
        elif row.get("lead") != "ok" or row.get("review") != "ok":
            err("status: ready ですが台帳が ok/ok ではありません: %r" % (row,))

    return errors


def copy_problems(text, limit, basis, require=()):
    """言い回しの共通ルール（字数・禁止語・競合名・日付・数字の根拠・必須語）。"""
    problems = []
    if limit is not None and effective_length(text) > limit:
        problems.append("%d 字（上限 %d 字）" % (effective_length(text), limit))
    for pattern, label in ((APP_BANNED, "罰・恥系の禁止語"), (MARKETING_BANNED, "誇大・煽り表現")):
        m = pattern.search(text)
        if m:
            problems.append("%sを含みます: %r" % (label, m.group(0)))
    hits = [t for t in COMPETITOR_TERMS if t in normalize(text)]
    if hits:
        problems.append("競合サービス名を含みます: %s" % ", ".join(hits))
    m = DATE_ASSERTION.search(text)
    if m:
        problems.append("日付・年を断定しています: %r（公開日は未確定のため「近日公開」を使う）" % m.group(0))
    for token in sorted(set(NUMERAL.findall(normalize(text)))):
        if token not in basis:
            problems.append("数字 %r が「数値の根拠」にありません" % token)
    for word in require:
        if word not in text:
            problems.append("「%s」が入っていません" % word)
    return problems


def field_of(text, key):
    """`- key: value` の1行フィールドを読む。"""
    m = re.search(r"^-\s*%s:\s*(.+)$" % re.escape(key), text, re.MULTILINE)
    return m.group(1).strip() if m else ""


def thread_section(text):
    """`## 固定ポスト` の節（次の `## ` まで）。無ければ None。"""
    m = re.search(r"^##\s+(?:[0-9]+\.\s*)?固定ポスト.*$", text, re.MULTILINE)
    if not m:
        return None
    rest = text[m.end():]
    nxt = re.search(r"^##\s+", rest, re.MULTILINE)
    return rest[:nxt.start()] if nxt else rest


def thread_bodies(section):
    """`### ...` ごとの `>` 引用を本文として取り出す。"""
    bodies = []
    for chunk in re.split(r"^###\s+", section, flags=re.MULTILINE)[1:]:
        lines = []
        for line in chunk.splitlines()[1:]:
            if line.startswith("## "):
                break
            if line.startswith(">"):
                content = line[1:]
                if content.startswith(" "):
                    content = content[1:]
                lines.append(content.rstrip())
        bodies.append("\n".join(lines).strip())
    return bodies


def validate_branding(text):
    """branding.md（X アカウントのブランディング案）を検査する。"""
    errors = []

    def err(msg):
        errors.append("branding.md: %s" % msg)

    basis = normalize(field_of(text, "数値の根拠"))
    status = field_of(text, "status")
    if status not in ("draft", "ready"):
        err("status は draft / ready のどちらかにしてください: %r" % status)

    basis_refs = doc_refs(field_of(text, "根拠"))
    if not basis_refs:
        err("「根拠」に docs/*.md §N の参照がありません")
    for ref_path, ref in basis_refs:
        problem = resolve_doc_ref(ref_path, ref)
        if problem:
            err(problem)

    counts = {"表示名": 0, "@handle": 0, "bio": 0}
    recommended = {}
    for key, suffix, raw in BRANDING_FIELD.findall(text):
        m = FIELD_VALUE.search(raw)
        if not m:
            err("%s%s は値を `...` で囲んでください" % (key, suffix))
            continue
        candidate = m.group(1).strip()
        counts[key] += 1
        label = "%s%s" % (key, suffix)
        if "推奨" in suffix:
            recommended[key] = candidate

        if key == "表示名":
            if effective_length(candidate) > NAME_LIMIT:
                err("%s が %d 字（上限 %d 字）" % (label, effective_length(candidate), NAME_LIMIT))
            if "（リアン）" in candidate:
                err("%s の括弧が全角です（ストア名に合わせて半角の (リアン)）" % label)
            for problem in copy_problems(candidate, None, basis):
                err("%s: %s" % (label, problem))
        elif key == "@handle":
            if not HANDLE_RE.fullmatch(candidate):
                err("%s が @ + 英数字/アンダースコア 15 字以内ではありません: %r" % (label, candidate))
        else:  # bio
            for problem in copy_problems(candidate, BIO_LIMIT, basis, require=("ひとつだけ", "近日公開")):
                err("%s: %s" % (label, problem))

    for key in counts:
        if counts[key] < 2:
            err("%s の候補が2つ未満です（推奨 + 代替を並べる）" % key)
    if "表示名" in recommended and "Lien(リアン)" not in recommended["表示名"]:
        err("推奨の表示名に、ストア名と同じ「Lien(リアン)」が入っていません")

    section = thread_section(text)
    if section is None:
        err("「## 固定ポスト」の節がありません")
    else:
        bodies = thread_bodies(section)
        if len(bodies) < 2:
            err("固定ポストのスレッド本文（`>`）が2本未満です")
        for i, body in enumerate(bodies, 1):
            if not body:
                err("固定ポスト %d 本目の本文が空です" % i)
                continue
            for problem in copy_problems(body, BODY_LIMIT, basis):
                err("固定ポスト %d 本目: %s" % (i, problem))

    if status == "ready":
        missing = [k for k, v in approvals_of(text).items() if not v]
        if missing:
            err("status: ready ですが承認のチェックがありません: %s" % ", ".join(missing))

    return errors


def check_all(x_dir=X_DIR):
    errors = []
    if not os.path.exists(REVIEW_MD):
        return ["review.md がありません"]
    ledger = ledger_of(read_text(REVIEW_MD))

    present = set()
    for name in sorted(os.listdir(x_dir)):
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}\.md", name):
            continue
        present.add(name[:-3])
        errors.extend(validate_post(os.path.join(x_dir, name), read_text(os.path.join(x_dir, name)), ledger))

    for date in sorted(EXPECTED):
        if date not in present:
            errors.append("%s.md: 投稿案がありません（13本そろえる）" % date)

    if not os.path.exists(BRANDING_MD):
        errors.append("branding.md がありません（X アカウントのブランディング案）")
    else:
        errors.extend(validate_branding(read_text(BRANDING_MD)))
    return errors


def main():
    errors = check_all()
    if errors:
        print("NG: %d 件" % len(errors))
        for e in errors:
            print("  - " + e)
        return 1
    print("OK: %d 本の投稿案とブランディング案（140字以内・禁止語なし・根拠あり・承認前 ready なし）" % len(EXPECTED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
