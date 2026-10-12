#!/usr/bin/env python3
"""植物アセットのツール(gen_layers / build_asset_catalog / verify_assets / svg_geom)の単体テスト。

CI の plant-assets ジョブが `python3 -m unittest discover -s tools -p 'test_*.py'` で実行する。標準ライブラリだけ。

  - 生成が決定論で、三角関数・べき乗の末尾の誤差(libm / Python の版の差)でも出力が1文字も変わらない
  - verify_assets が、許可していない要素・属性、viewBox の違い、レイヤーやカタログの過不足を見逃さない
  - svg_geom の走査(左右の花の塗りの重なり)が、重なりを検出し、重ならない塗りを通す
  - 重ね順 stack() が mapping.md の規則どおり
"""

import json
import math
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import build_asset_catalog  # noqa: E402
import gen_layers  # noqa: E402
import gen_v4  # noqa: E402
import svg_geom  # noqa: E402
import verify_assets  # noqa: E402


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def snapshot_tree(root):
    """root の下の全ファイル(相対パス → バイト列)。"""
    out = {}
    for base, _, files in os.walk(root):
        for name in files:
            full = os.path.join(base, name)
            out[os.path.relpath(full, root)] = read(full)
    return out


class GeneratedAssetsTest(unittest.TestCase):
    """生成物そのものの検査(生成は1回だけ。変異させるテストはコピーを使う)。"""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="plant_tools_")
        cls.root = os.path.join(cls.tmp, "plant")
        os.makedirs(cls.root)
        gen_layers.generate(cls.root)
        build_asset_catalog.build(cls.root)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def mutable_copy(self):
        dst = os.path.join(tempfile.mkdtemp(prefix="plant_tools_mut_"), "plant")
        shutil.copytree(self.root, dst)
        self.addCleanup(shutil.rmtree, os.path.dirname(dst), True)
        return dst

    # ---- 生成物

    def test_generated_assets_pass_verification(self):
        self.assertEqual(verify_assets.verify(self.root), [])

    def test_expected_layer_list_has_34_unique_names(self):
        self.assertEqual(len(verify_assets.EXPECTED_LAYERS), 34)
        self.assertEqual(len(set(verify_assets.EXPECTED_LAYERS)), 34)
        files = sorted(n[:-4] for n in os.listdir(os.path.join(self.root, "svg")))
        self.assertEqual(files, verify_assets.EXPECTED_LAYERS)

    def test_catalog_has_one_imageset_per_layer(self):
        xc = os.path.join(self.root, "PlantAssets.xcassets")
        sets = sorted(e for e in os.listdir(xc) if e.endswith(".imageset"))
        self.assertEqual(sets, ["plant_%s.imageset" % n for n in verify_assets.EXPECTED_LAYERS])
        contents = [os.path.join(b, "Contents.json") for b, _, fs in os.walk(xc) if "Contents.json" in fs]
        self.assertEqual(len(contents), 35)  # ルート1 + imageset 34
        for layer in verify_assets.EXPECTED_LAYERS:
            data = json.loads(read(os.path.join(xc, "plant_%s.imageset" % layer, "Contents.json")))
            self.assertIs(data["properties"]["preserves-vector-representation"], True)
            self.assertNotEqual(data["properties"].get("template-rendering-intent"), "template")

    def test_generation_is_deterministic(self):
        other = tempfile.mkdtemp(prefix="plant_tools_det_")
        self.addCleanup(shutil.rmtree, other, True)
        gen_layers.generate(other)
        build_asset_catalog.build(other)
        self.assertEqual(snapshot_tree(other), snapshot_tree(self.root))

    def test_output_is_stable_under_libm_noise(self):
        """三角関数・べき乗の結果が 1ulp ずれても(プラットフォームや Python の版が違っても)出力は変わらない。"""
        import random
        expected = {k: v for k, v in snapshot_tree(self.root).items() if not k.startswith("PlantAssets.xcassets")}
        original_q = gen_v4._q
        for seed in range(3):
            rnd = random.Random(seed)

            def noisy_q(v, rnd=rnd):
                r = rnd.random()
                if r < 0.33:
                    v = math.nextafter(v, math.inf)
                elif r < 0.66:
                    v = math.nextafter(v, -math.inf)
                return round(v, 10)

            gen_v4._q = noisy_q
            other = tempfile.mkdtemp(prefix="plant_tools_noise_")
            self.addCleanup(shutil.rmtree, other, True)
            try:
                gen_layers.generate(other)
            finally:
                gen_v4._q = original_q
            with self.subTest(seed=seed):
                self.assertEqual(snapshot_tree(other), expected)

    # ---- verify_assets が見逃さないこと

    def assert_flagged(self, root, needle):
        problems = verify_assets.verify(root)
        self.assertTrue(any(needle in p for p in problems), "%r を含む問題が出ない: %s" % (needle, problems))

    def test_verify_flags_forbidden_constructs(self):
        cases = {
            "<filter": '<filter id="blur"><feGaussianBlur stdDeviation="2"/></filter>',
            "<mask": '<mask id="m"><rect width="10" height="10"/></mask>',
            "<clipPath": '<clipPath id="c"><rect width="10" height="10"/></clipPath>',
            "<text": '<text x="1" y="1">hi</text>',
            "<style": "<style>path{fill:red}</style>",
            "<use": '<use href="#x"/>',
            "<image": '<image href="a.png" width="1" height="1"/>',
            "stop-opacity": '<linearGradient id="gz"><stop offset="0" stop-color="#fff" stop-opacity="0.5"/></linearGradient>',
        }
        for needle, snippet in cases.items():
            root = self.mutable_copy()
            path = os.path.join(root, "svg", "body.svg")
            text = read(path).decode("utf-8")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text.replace("</svg>", snippet + "</svg>"))
            with self.subTest(needle=needle):
                self.assert_flagged(root, needle if needle != "stop-opacity" else "stop-opacity")

    def test_verify_flags_forbidden_attributes(self):
        for attr, needle in (('style="fill:red"', "style"), ('filter="url(#f)"', "filter"),
                             ('mask="url(#m)"', "mask"), ('clip-path="url(#c)"', "clip-path")):
            root = self.mutable_copy()
            path = os.path.join(root, "svg", "body.svg")
            text = read(path).decode("utf-8")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text.replace("</svg>", "<g %s/></svg>" % attr))
            with self.subTest(attr=attr):
                self.assert_flagged(root, "使えない属性 " + needle)

    def test_verify_flags_dangling_gradient_reference(self):
        root = self.mutable_copy()
        path = os.path.join(root, "svg", "body.svg")
        text = read(path).decode("utf-8")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text.replace("</svg>", '<rect width="1" height="1" fill="url(#nope)"/></svg>'))
        self.assert_flagged(root, "url(#nope)")

    def test_verify_flags_wrong_viewbox_and_size(self):
        root = self.mutable_copy()
        path = os.path.join(root, "svg", "pot_back.svg")
        text = read(path).decode("utf-8")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text.replace('viewBox="0 0 240 320"', 'viewBox="0 0 240 321"').replace('height="320"', 'height="321"'))
        self.assert_flagged(root, "viewBox")
        self.assert_flagged(root, "height が 320")

    def test_verify_flags_malformed_xml(self):
        root = self.mutable_copy()
        with open(os.path.join(root, "svg", "body.svg"), "w", encoding="utf-8") as fh:
            fh.write("<svg><g></svg>")
        self.assert_flagged(root, "XML として不正")

    def test_verify_flags_missing_and_extra_layers(self):
        root = self.mutable_copy()
        os.remove(os.path.join(root, "svg", "body.svg"))
        shutil.copyfile(os.path.join(root, "svg", "pot_back.svg"), os.path.join(root, "svg", "surprise.svg"))
        self.assert_flagged(root, "足りない(1点): body")
        self.assert_flagged(root, "期待していないレイヤー")

    def test_verify_flags_petal_color_and_overlap(self):
        root = self.mutable_copy()
        path = os.path.join(root, "svg", "petal_s6.svg")
        text = read(path).decode("utf-8")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text.replace("#FFB3C7", "#00FF00"))
        self.assert_flagged(root, "既定の花色")
        # 中央をまたぐ塗り(反転すると重なる)
        root = self.mutable_copy()
        with open(os.path.join(root, "svg", "petal_s7.svg"), "w", encoding="utf-8") as fh:
            fh.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 320" width="240" height="320">'
                     '<path d="M100 100 L140 100 L140 140 L100 140 Z" fill="#FFB3C7"/></svg>\n')
        self.assert_flagged(root, "左右の花の塗りが重なっている")

    def test_verify_flags_catalog_problems(self):
        # preserves-vector-representation が false
        root = self.mutable_copy()
        path = os.path.join(root, "PlantAssets.xcassets", "plant_body.imageset", "Contents.json")
        data = json.loads(read(path))
        data["properties"]["preserves-vector-representation"] = False
        with open(path, "w") as fh:
            json.dump(data, fh)
        self.assert_flagged(root, "preserves-vector-representation")
        # template にしている
        root = self.mutable_copy()
        path = os.path.join(root, "PlantAssets.xcassets", "plant_petal_s6.imageset", "Contents.json")
        data = json.loads(read(path))
        data["properties"]["template-rendering-intent"] = "template"
        with open(path, "w") as fh:
            json.dump(data, fh)
        self.assert_flagged(root, "template にしない")
        # imageset の欠落と、旧ドット絵の残り
        root = self.mutable_copy()
        shutil.rmtree(os.path.join(root, "PlantAssets.xcassets", "plant_fx_zzz.imageset"))
        os.makedirs(os.path.join(root, "PlantAssets.xcassets", "plant_stage1_normal.imageset"))
        self.assert_flagged(root, "imageset がない: plant_fx_zzz.imageset")
        self.assert_flagged(root, "期待していない imageset: plant_stage1_normal.imageset")
        # カタログ内の SVG が svg/ と違う
        root = self.mutable_copy()
        with open(os.path.join(root, "PlantAssets.xcassets", "plant_body.imageset", "plant_body.svg"), "a") as fh:
            fh.write("\n")
        self.assert_flagged(root, "svg/body.svg と違う")

    def test_verify_flags_unknown_layer_in_stacks(self):
        root = self.mutable_copy()
        path = os.path.join(root, "layer_stacks.json")
        text = read(path).decode("utf-8")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text.replace("pot_back", "pot_bakc", 1))
        self.assert_flagged(root, "存在しないレイヤー名")


class SvgGeomTest(unittest.TestCase):
    def test_transform_order_and_rotation_about_a_point(self):
        m = svg_geom.parse_transform("translate(10 20) scale(2)")
        self.assertEqual(svg_geom.apply_matrix(m, (1, 1)), (12.0, 22.0))
        m = svg_geom.parse_transform("rotate(90 10 10)")
        x, y = svg_geom.apply_matrix(m, (20, 10))
        self.assertAlmostEqual(x, 10.0)
        self.assertAlmostEqual(y, 20.0)
        m = svg_geom.parse_transform("translate(240 0) scale(-1 1)")
        self.assertEqual(svg_geom.apply_matrix(m, (100, 5)), (140.0, 5.0))

    def test_unsupported_syntax_is_rejected(self):
        with self.assertRaises(ValueError):
            svg_geom.parse_transform("skewX(10)")
        with self.assertRaises(ValueError):
            svg_geom.flatten_path("M0 0 H10 V10 Z")
        with self.assertRaises(ValueError):
            svg_geom.flatten_path("M0 0 l10 10 z")

    def test_mirror_overlap_detects_and_clears(self):
        template = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 320"><path d="%s" fill="#FFB3C7"/></svg>')
        crossing = template % "M100 10 L140 10 L140 50 L100 50 Z"
        area, widest, _ = svg_geom.mirror_overlap(crossing)
        self.assertAlmostEqual(area, 40 * 40, delta=1.0)    # 100..140 は x=120 で反転しても同じ範囲に重なる
        self.assertAlmostEqual(widest, 40.0, delta=0.01)
        apart = template % "M20 10 L60 10 L60 50 L20 50 Z"
        area, widest, gap = svg_geom.mirror_overlap(apart)
        self.assertEqual(area, 0.0)
        self.assertAlmostEqual(gap, 240 - 60 - 60, delta=0.01)  # 20..60 と 180..220 のすき間

    def test_curves_and_nested_transforms(self):
        svg = ('<svg xmlns="http://www.w3.org/2000/svg"><g transform="translate(60 100)"><g transform="scale(2)">'
               '<path d="M0 0 C10 -10 30 -10 40 0 Q20 20 0 0 Z" fill="red"/></g></g></svg>')
        polys = svg_geom.fill_polygons(svg)
        self.assertEqual(len(polys), 1)
        xs = [p[0] for p in polys[0]]
        self.assertAlmostEqual(min(xs), 60.0, places=3)
        self.assertAlmostEqual(max(xs), 140.0, places=3)

    def test_fill_none_is_not_a_fill(self):
        svg = '<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0 L10 0 L10 10 Z" fill="none" stroke="red"/></svg>'
        self.assertEqual(svg_geom.fill_polygons(svg), [])


class StackTest(unittest.TestCase):
    """mapping.md の重ね順・状態対応(README 由来)。"""

    def names(self, entries):
        return [(e.name, e.mirror, e.tint) for e in entries]

    def test_morning_default_stage3(self):
        got = self.names(gen_layers.stack(3, "folded", "folded", "face_normal"))
        self.assertEqual(got, [
            ("pot_back", False, None), ("leaf_folded", False, None), ("leaf_folded", True, None),
            ("head_s3", False, None), ("body", False, None), ("face_normal", False, None),
            ("pot_front", False, None), ("hands_rim", False, None)])

    def test_both_done_stage8_has_arms_petals_and_sparkle(self):
        got = self.names(gen_layers.stack(8, "open", "open", "face_happy", ("fx_sparkle",)))
        self.assertEqual(got, [
            ("pot_back", False, None), ("leaf_open", False, None), ("leaf_open", True, None),
            ("petal_s8", False, "me"), ("petal_s8", True, "partner"), ("head_s8", False, None),
            ("arms_up", False, None), ("body", False, None), ("face_happy", False, None),
            ("pot_front", False, None), ("fx_sparkle", False, None)])

    def test_stage0_uses_nubs_and_no_head(self):
        got = [e.name for e in gen_layers.stack(0, "open", "folded", "face_look_l")]
        self.assertEqual(got[:3], ["pot_back", "nub_lit", "nub_closed"])
        self.assertFalse(any(n.startswith("head_") or n.startswith("petal_") or n.startswith("leaf_") for n in got))

    def test_stage1_has_leaves_but_no_head(self):
        got = [e.name for e in gen_layers.stack(1, "folded", "open", "face_look_r")]
        self.assertEqual(got[1:3], ["leaf_folded", "leaf_open"])
        self.assertFalse(any(n.startswith("head_") for n in got))

    def test_solo_dark_and_soil_glow(self):
        got = [e.name for e in gen_layers.stack(0, solo=True, soil_glow=True, dark=True)]
        self.assertEqual(got, ["bg_plate", "pot_back", "fx_soil_glow", "solo_seed", "pot_front", "fx_zzz"])
        got = [e.name for e in gen_layers.stack(5, solo=True)]
        self.assertEqual(got, ["pot_back", "solo_seed", "pot_front", "fx_zzz"])

    def test_peek_is_translated_only_where_defined(self):
        peek = [e for e in gen_layers.stack(3, peek=True) if e.name == "fx_peek"]
        self.assertEqual([(e.dx, e.dy) for e in peek], [(0.0, -84.0)])
        self.assertEqual([e for e in gen_layers.stack(9, peek=True) if e.name == "fx_peek"], [])
        self.assertEqual([e for e in gen_layers.stack(2, peek=True) if e.name == "fx_peek"], [])
        # のぞきは効果(fx_*)より下
        names = [e.name for e in gen_layers.stack(4, "open", "open", "face_happy", ("fx_sparkle",), peek=True)]
        self.assertLess(names.index("fx_peek"), names.index("fx_sparkle"))

    def test_hands_and_arms_follow_the_face(self):
        for face in gen_layers.FACE_NAMES:
            names = [e.name for e in gen_layers.stack(2, face=face)]
            raised = face in ("face_happy", "face_wow")
            self.assertEqual("arms_up" in names, raised, face)
            self.assertEqual("hands_rim" in names, not raised, face)

    def test_every_case_uses_known_layers(self):
        known = set(verify_assets.EXPECTED_LAYERS)
        for case in gen_layers.stack_cases():
            for token in case["layers"].split():
                self.assertIn(token.split("|")[0], known)


if __name__ == "__main__":
    unittest.main()
