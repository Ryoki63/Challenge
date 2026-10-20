#!/usr/bin/env python3
"""verify_metadata.py の検査ロジックの単体テスト。

CI(`store-metadata` ジョブ)とローカルの両方で実行する:
  cd products/lien/marketing && python3 -m unittest discover -s tools -p "test_*.py"

検査そのものを壊しても気づけるように、緑になる例だけでなく、赤になる例
(文字数超過・禁止語・キーワードの重複・表示名との重複・Pairy 語)を固定する。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import verify_metadata as vm  # noqa: E402  (sys.path の追加後に読み込む)


def valid_fields(**overrides):
    """全検査を通過する最小の確定値。個別の検査だけを壊して赤を確認する。"""
    fields = {
        "name.txt": "Lien(リアン)- ふたりの約束",
        "subtitle.txt": "約束はひとつだけ。静かに続く習慣アプリ",
        "keywords.txt": "カップル,夫婦,恋人,友達,2人,二人,ペア,遠距離",
        "promotional_text.txt": "ふたりで約束をひとつだけ決めて、毎日チェックイン。",
        "description.txt": "約束は、ひとつだけ。ふたりで決めて、毎日つづける。",
        "release_notes.txt": "Lien(リアン)v1.0 を公開しました。",
    }
    fields.update(overrides)
    return fields


class EffectiveLengthTest(unittest.TestCase):
    def test_bmp_char_counts_as_one(self):
        self.assertEqual(vm.effective_length("あいうえお"), 5)

    def test_astral_char_counts_as_two(self):
        # 絵文字は UTF-16 でサロゲートペア=2。保守的に大きい方を採る
        self.assertEqual(vm.effective_length("🍀"), 2)

    def test_empty_is_zero(self):
        self.assertEqual(vm.effective_length(""), 0)


class CollectErrorsTest(unittest.TestCase):
    def test_valid_fixture_has_no_error(self):
        self.assertEqual(vm.collect_errors(valid_fields()), [])

    def test_name_over_limit(self):
        errors = vm.collect_errors(valid_fields(**{"name.txt": "あ" * 31}))
        self.assertTrue(any("name.txt: length 31 exceeds limit 30" in e for e in errors), errors)

    def test_name_at_limit_is_ok(self):
        self.assertEqual(vm.collect_errors(valid_fields(**{"name.txt": "あ" * 30})), [])

    def test_empty_field(self):
        errors = vm.collect_errors(valid_fields(**{"subtitle.txt": ""}))
        self.assertTrue(any("subtitle.txt: empty content" in e for e in errors), errors)

    def test_banned_word_in_promotional_text(self):
        errors = vm.collect_errors(valid_fields(**{"promotional_text.txt": "サボらず続けよう"}))
        self.assertTrue(
            any("罰なし原則違反" in e and "サボ" in e for e in errors), errors
        )

    def test_banned_word_in_description(self):
        errors = vm.collect_errors(valid_fields(**{"description.txt": "植物は枯れません。"}))
        self.assertTrue(any("description.txt" in e and "枯れ" in e for e in errors), errors)

    def test_keyword_with_space(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "カップル, 夫婦"}))
        self.assertTrue(any("must not contain spaces" in e for e in errors), errors)

    def test_keyword_duplicate(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "カップル,夫婦,カップル"}))
        self.assertTrue(any("duplicate terms" in e for e in errors), errors)

    def test_keyword_substring_duplicate(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "継続,継続力"}))
        self.assertTrue(any("索引の無駄" in e for e in errors), errors)

    def test_keyword_repeats_name(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "約束,カップル"}))
        self.assertTrue(any("duplicates the name/subtitle" in e for e in errors), errors)

    def test_keyword_repeats_name_kana(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "リアン,カップル"}))
        self.assertTrue(any("リアン" in e for e in errors), errors)

    def test_keyword_repeats_subtitle(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "静かに続く習慣アプリ"}))
        self.assertTrue(any("duplicates the name/subtitle" in e for e in errors), errors)

    def test_competitor_name_ascii(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "pairy,カップル"}))
        self.assertTrue(any("competitor name" in e for e in errors), errors)

    def test_competitor_name_uppercase(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "PAIRY,カップル"}))
        self.assertTrue(any("competitor name" in e for e in errors), errors)

    def test_competitor_name_fullwidth(self):
        # NFKC 正規化で全角英字も拾う
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "ＰＡＩＲＹ"}))
        self.assertTrue(any("competitor name" in e for e in errors), errors)

    def test_competitor_name_hiragana(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "ぺありー,カップル"}))
        self.assertTrue(any("competitor name" in e for e in errors), errors)

    def test_competitor_name_katakana(self):
        errors = vm.collect_errors(valid_fields(**{"keywords.txt": "ペアリー,カップル"}))
        self.assertTrue(any("competitor name" in e for e in errors), errors)

    def test_competitor_name_in_description(self):
        errors = vm.collect_errors(valid_fields(**{"description.txt": "Pairy からの乗り換えに。"}))
        self.assertTrue(any("description.txt" in e and "competitor name" in e for e in errors), errors)

    def test_pairing_general_word_is_not_flagged(self):
        # 「ペアリング」は一般的な技術用語なので競合名として誤検知しない
        self.assertEqual(
            vm.collect_errors(valid_fields(**{"description.txt": "ペアリングの手順です。"})), []
        )


class RepositoryMetadataTest(unittest.TestCase):
    """リポジトリに置いてある確定値そのものが緑であることを固定する。"""

    def test_repository_metadata_is_valid(self):
        fields = vm.load_fields(vm.JA_DIR)
        self.assertEqual(vm.collect_errors(fields), [])

    def test_keywords_use_most_of_the_budget(self):
        # 100字の枠を大きく余らせたまま提出しない(使わない枠は0円で捨てるのと同じ)
        fields = vm.load_fields(vm.JA_DIR)
        used = vm.effective_length(fields["keywords.txt"])
        self.assertGreaterEqual(used, 90, "keywords が %d/100 字しかない" % used)


if __name__ == "__main__":
    unittest.main()
