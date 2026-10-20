#!/usr/bin/env python3
"""check_posts.py の検査ロジックの単体テスト。

検査そのものを壊しても気づけるように、緑になる例だけでなく、赤になる例
（字数超過・禁止語・誇大表現・競合名・日付の断定・根拠のない数字・
承認前の ready・指定画像のままの ready・存在しない節）を固定する。

  cd products/lien/marketing/x && python3 -m unittest discover -s tools -p "test_*.py"
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check_posts as cp  # noqa: E402  (sys.path の追加後に読み込む)


def post_text(
    date="2026-10-21",
    status="draft",
    kind="開発ストーリー 1/10",
    body="テスト投稿です。\n#個人開発",
    image="`products/lien/assets/icon/icon_1024.png`",
    basis="docs/REQUIREMENTS.md §3.4",
    link="なし（公開前。ストア URL 未確定のため）",
    numbers="なし",
    lead=" ",
    review=" ",
    omit=None,
):
    """1本の投稿案を組み立てる。omit でフィールドを1つ落とせる。"""
    fields = {
        "日付": date,
        "status": status,
        "種別": kind,
        "投稿予定": "%s 08:00 JST" % date,
        "添付画像": image,
        "代替テキスト": "テスト用の代替テキスト。",
        "根拠": basis,
        "リンク先": link,
        "数値の根拠": numbers,
    }
    if omit:
        fields.pop(omit, None)
    lines = ["# %s" % date, ""]
    lines += ["- %s: %s" % (k, v) for k, v in fields.items()]
    lines += [
        "",
        "## 本文（140字以内）",
        "",
        ">" + "".join(" " + part if i == 0 else "\n> " + part for i, part in enumerate(body.split("\n"))),
        "",
        "## 承認",
        "",
        "- [%s] mkt-lead（方針整合）" % lead,
        "- [%s] mkt-review（景表法・誇大表現）" % review,
        "",
    ]
    return "\n".join(lines)


def validate(text, ledger=None):
    return cp.validate_post("2026-10-21.md", text, ledger or {})


class ValidPostTest(unittest.TestCase):
    def test_valid_post_has_no_error(self):
        self.assertEqual(validate(post_text()), [])

    def test_existing_image_via_assets_path(self):
        text = post_text(image="`products/lien/assets/icon/icon_1024.png`（1024×1024）")
        self.assertEqual(validate(text), [])

    def test_designated_image_is_allowed_for_draft(self):
        text = post_text(image="指定: 実機スクリーンショット（Frame 1）")
        self.assertEqual(validate(text), [])


class BodyRulesTest(unittest.TestCase):
    def test_body_over_140_chars(self):
        errors = validate(post_text(body="あ" * 141))
        self.assertTrue(any("140" in e for e in errors), errors)

    def test_body_at_140_chars_is_allowed(self):
        self.assertEqual(validate(post_text(body="あ" * 140)), [])

    def test_astral_emoji_counts_as_two(self):
        # 絵文字は UTF-16 で2単位。140 個で 280 単位になり、上限を超える
        errors = validate(post_text(body="🍀" * 140))
        self.assertTrue(any("140" in e for e in errors), errors)

    def test_app_banned_word(self):
        for word in ("サボ", "枯れ", "罰", "恥", "ダメ", "怒", "遅い", "まだやってない"):
            errors = validate(post_text(body="これは%sの話です。" % word))
            self.assertTrue(any("禁止語" in e for e in errors), (word, errors))

    def test_marketing_banned_word(self):
        for word in ("必ず", "絶対", "日本一", "No.1", "完全無料", "失敗"):
            errors = validate(post_text(body="%s なアプリです。" % word))
            self.assertTrue(any("誇大" in e for e in errors), (word, errors))

    def test_competitor_name(self):
        errors = validate(post_text(body="Pairy の代わりに。"))
        self.assertTrue(any("競合" in e for e in errors), errors)

    def test_date_assertion(self):
        for body in ("10月31日に公開します。", "10/31 に公開します。", "2026年に公開します。"):
            errors = validate(post_text(body=body))
            self.assertTrue(any("日付" in e for e in errors), (body, errors))

    def test_numeral_without_basis(self):
        errors = validate(post_text(body="3秒で終わります。"))
        self.assertTrue(any("数値の根拠" in e for e in errors), errors)

    def test_numeral_with_basis(self):
        text = post_text(body="3秒で終わります。", numbers="3 = 非機能要件の目標値（REQUIREMENTS §4）")
        self.assertEqual(validate(text), [])

    def test_numeral_with_thousands_separator(self):
        text = post_text(body="1,000件のテスト。", numbers="1,000 = CI のテスト件数")
        self.assertEqual(validate(text), [])


class FieldRulesTest(unittest.TestCase):
    def test_missing_required_field(self):
        errors = validate(post_text(omit="代替テキスト"))
        self.assertTrue(any("必須フィールド" in e for e in errors), errors)

    def test_type_mismatch(self):
        errors = validate(post_text(kind="開発ストーリー 2/10"))
        self.assertTrue(any("種別" in e for e in errors), errors)

    def test_date_field_mismatch(self):
        errors = validate(post_text(date="2026-10-22"))
        self.assertTrue(any("日付" in e for e in errors), errors)

    def test_posting_time_needs_jst(self):
        text = post_text().replace("08:00 JST", "08:00")
        errors = validate(text)
        self.assertTrue(any("JST" in e for e in errors), errors)

    def test_missing_image(self):
        errors = validate(post_text(image="`products/lien/assets/nope.png`"))
        self.assertTrue(any("添付画像が見つかりません" in e for e in errors), errors)

    def test_status_unknown(self):
        errors = validate(post_text(status="review"))
        self.assertTrue(any("status" in e for e in errors), errors)


class BasisRulesTest(unittest.TestCase):
    def test_missing_docs_reference(self):
        errors = validate(post_text(basis="実装を見て書いた"))
        self.assertTrue(any("参照がありません" in e for e in errors), errors)

    def test_missing_section(self):
        errors = validate(post_text(basis="docs/CONCEPT.md §99"))
        self.assertTrue(any("節がありません" in e for e in errors), errors)

    def test_missing_subsection(self):
        errors = validate(post_text(basis="docs/REQUIREMENTS.md §3.99"))
        self.assertTrue(any("小節がありません" in e for e in errors), errors)

    def test_numbered_item_shorthand(self):
        self.assertEqual(validate(post_text(basis="docs/CONCEPT.md §5-2")), [])

    def test_numbered_item_shorthand_out_of_range(self):
        errors = validate(post_text(basis="docs/CONCEPT.md §5-99"))
        self.assertTrue(any("項目がありません" in e for e in errors), errors)

    def test_following_sections_inherit_file(self):
        # 「docs/CONCEPT.md §1・§99」の §99 も CONCEPT の参照として検査する
        errors = validate(post_text(basis="docs/CONCEPT.md §1・§99"))
        self.assertTrue(any("§99" in e for e in errors), errors)

    def test_missing_implementation_path(self):
        errors = validate(post_text(basis="docs/REQUIREMENTS.md §3.4 / 実装: `products/lien/nope/`"))
        self.assertTrue(any("実装パス" in e for e in errors), errors)


class ApprovalRulesTest(unittest.TestCase):
    def test_ready_without_checks(self):
        errors = validate(post_text(status="ready"))
        self.assertTrue(any("承認のチェック" in e for e in errors), errors)

    def test_ready_with_checks_but_no_ledger(self):
        errors = validate(post_text(status="ready", lead="x", review="x"))
        self.assertTrue(any("台帳" in e for e in errors), errors)

    def test_ready_with_checks_and_ledger(self):
        ledger = {"2026-10-21": {"lead": "ok", "review": "ok"}}
        self.assertEqual(validate(post_text(status="ready", lead="x", review="x"), ledger), [])

    def test_ready_with_ledger_not_ok(self):
        ledger = {"2026-10-21": {"lead": "ok", "review": "pending"}}
        errors = validate(post_text(status="ready", lead="x", review="x"), ledger)
        self.assertTrue(any("ok/ok" in e for e in errors), errors)

    def test_ready_with_designated_image(self):
        ledger = {"2026-10-21": {"lead": "ok", "review": "ok"}}
        errors = validate(
            post_text(status="ready", lead="x", review="x", image="指定: 実機スクリーンショット"),
            ledger,
        )
        self.assertTrue(any("指定" in e for e in errors), errors)

    def test_ledger_ignores_fenced_example(self):
        # review.md の記入例（コードフェンス内）を承認済みと誤認しない
        text = (
            "## 1. 承認台帳\n\n"
            "| 日付 | mkt-lead | mkt-review | 承認日 | メモ |\n"
            "|---|---|---|---|---|\n"
            "| （まだありません） | - | - | - | - |\n\n"
            "```\n"
            "| 2026-10-21 | ok | ok | 2026-10-20 | 例 |\n"
            "```\n\n"
            "## 2. 次の節\n"
        )
        self.assertEqual(cp.ledger_of(text), {})

    def test_ledger_reads_table_row(self):
        text = (
            "## 1. 承認台帳\n\n"
            "| 日付 | mkt-lead | mkt-review | 承認日 | メモ |\n"
            "|---|---|---|---|---|\n"
            "| 2026-10-21 | ok | ok | 2026-10-20 | 承認 |\n\n"
            "## 2. 次の節\n"
        )
        self.assertEqual(cp.ledger_of(text), {"2026-10-21": {"lead": "ok", "review": "ok"}})


class ReleasePostTest(unittest.TestCase):
    def test_ready_release_post_needs_store_url(self):
        ledger = {"2026-10-31": {"lead": "ok", "review": "ok"}}
        text = post_text(
            date="2026-10-31",
            status="ready",
            kind="公開日",
            image="`products/lien/assets/icon/icon_1024.png`",
            link="<APP_STORE_URL>",
            lead="x",
            review="x",
        )
        errors = cp.validate_post("2026-10-31.md", text, ledger)
        self.assertTrue(any("ストア URL" in e for e in errors), errors)

    def test_ready_release_post_with_url(self):
        ledger = {"2026-10-31": {"lead": "ok", "review": "ok"}}
        text = post_text(
            date="2026-10-31",
            status="ready",
            kind="公開日",
            image="`products/lien/assets/icon/icon_1024.png`",
            link="https://apps.apple.com/jp/app/id000000000",
            lead="x",
            review="x",
        )
        self.assertEqual(cp.validate_post("2026-10-31.md", text, ledger), [])


def branding_text(
    name="`Lien(リアン)｜約束はひとつだけ`",
    name2="`リアン｜ふたりの約束`",
    handle="`@lien_app`",
    handle2="`@lien_futari`",
    bio="`約束は、ひとつだけ。毎日1タップ。近日公開。`",
    bio2="`約束は、ひとつだけ。ふたりで使う習慣アプリ。2人で続ける。近日公開。`",
    status="draft",
    thread=("できることは3つだけ。1タップで終わる。", "広告も、解析もありません。"),
    basis="docs/CONCEPT.md §2",
    numbers="1 = 1日1タップ / 2 = 2人 / 3 = 3つ",
    lead=" ",
    review=" ",
):
    """branding.md の検査用テキストを組み立てる。"""
    lines = [
        "# X アカウントのブランディング案",
        "",
        "- status: %s" % status,
        "- 根拠: %s" % basis,
        "- 数値の根拠: %s" % numbers,
        "- 表示名 A（推奨）: %s" % name,
        "- 表示名 B: %s" % name2,
        "- @handle A（推奨）: %s" % handle,
        "- @handle B: %s" % handle2,
        "- bio A（推奨）: %s" % bio,
        "- bio B: %s" % bio2,
        "",
        "## 6. 固定ポスト（スレッド）",
        "",
    ]
    for i, body in enumerate(thread, 1):
        lines.append("### リプライ%d" % i)
        lines.append("")
        for part in body.split("\n"):
            lines.append("> " + part)
        lines.append("")
    lines += [
        "## 承認",
        "",
        "- [%s] mkt-lead（方針整合）" % lead,
        "- [%s] mkt-review（景表法）" % review,
        "",
    ]
    return "\n".join(lines)


class BrandingTest(unittest.TestCase):
    def test_valid_branding(self):
        self.assertEqual(cp.validate_branding(branding_text()), [])

    def test_display_name_over_limit(self):
        errors = cp.validate_branding(branding_text(name="`Lien(リアン)｜%s`" % ("あ" * 50)))
        self.assertTrue(any("50" in e for e in errors), errors)

    def test_display_name_fullwidth_parens(self):
        errors = cp.validate_branding(branding_text(name="`Lien（リアン）｜約束はひとつだけ`"))
        self.assertTrue(any("全角" in e for e in errors), errors)

    def test_recommended_name_must_match_store(self):
        errors = cp.validate_branding(branding_text(name="`リアン｜約束はひとつだけ`"))
        self.assertTrue(any("Lien(リアン)" in e for e in errors), errors)

    def test_handle_too_long(self):
        errors = cp.validate_branding(branding_text(handle="`@lien_app_japan12`"))
        self.assertTrue(any("@handle" in e for e in errors), errors)

    def test_handle_invalid_char(self):
        errors = cp.validate_branding(branding_text(handle="`@lien-app`"))
        self.assertTrue(any("@handle" in e for e in errors), errors)

    def test_bio_over_limit(self):
        errors = cp.validate_branding(branding_text(bio="`ひとつだけ。近日公開。%s`" % ("あ" * 160)))
        self.assertTrue(any("160" in e for e in errors), errors)

    def test_bio_needs_tagline(self):
        errors = cp.validate_branding(branding_text(bio="`毎日1タップの習慣アプリ。近日公開。`"))
        self.assertTrue(any("ひとつだけ" in e for e in errors), errors)

    def test_bio_needs_release_state(self):
        errors = cp.validate_branding(branding_text(bio="`約束は、ひとつだけ。毎日1タップ。`"))
        self.assertTrue(any("近日公開" in e for e in errors), errors)

    def test_bio_banned_word(self):
        errors = cp.validate_branding(branding_text(bio="`約束は、ひとつだけ。必ず続く。近日公開。`"))
        self.assertTrue(any("誇大" in e for e in errors), errors)

    def test_bio_date_assertion(self):
        errors = cp.validate_branding(branding_text(bio="`約束は、ひとつだけ。10月31日に公開。`"))
        self.assertTrue(any("日付" in e for e in errors), errors)

    def test_bio_numeral_without_basis(self):
        errors = cp.validate_branding(
            branding_text(bio="`約束は、ひとつだけ。3秒で終わる。近日公開。`", numbers="1 = 1日1タップ")
        )
        self.assertTrue(any("数値の根拠" in e for e in errors), errors)

    def test_thread_body_over_140(self):
        errors = cp.validate_branding(branding_text(thread=("あ" * 141, "広告はありません。")))
        self.assertTrue(any("140" in e for e in errors), errors)

    def test_thread_needs_two_bodies(self):
        errors = cp.validate_branding(branding_text(thread=("3つだけ。",)))
        self.assertTrue(any("2本未満" in e for e in errors), errors)

    def test_missing_basis_ref(self):
        errors = cp.validate_branding(branding_text(basis="なんとなく"))
        self.assertTrue(any("参照がありません" in e for e in errors), errors)

    def test_ready_without_approvals(self):
        errors = cp.validate_branding(branding_text(status="ready"))
        self.assertTrue(any("承認のチェック" in e for e in errors), errors)

    def test_ready_with_approvals(self):
        text = branding_text(status="ready", lead="x", review="x")
        self.assertEqual(cp.validate_branding(text), [])


if __name__ == "__main__":
    unittest.main()
