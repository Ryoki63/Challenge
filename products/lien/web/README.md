# Lien の公開ページ(GitHub Pages)

ストア審査で必要な URL(プライバシーポリシー・利用規約・サポート)と、公開前のティザーを
1つの静的サイトにまとめたもの。issue #76(MK3)。

**配信するのは `site/` だけ**。リポジトリ全体は配信しない。

| パス | 中身 |
|---|---|
| `site/index.html` | 公開前ティザー(1行説明・スクリーンショット3枚・近日公開・法務リンク) |
| `site/lien/legal/privacy.html` | プライバシーポリシー(`marketing/privacy-policy.md` から生成) |
| `site/lien/legal/terms.html` | 利用規約(`marketing/terms.md` から生成) |
| `site/lien/i/index.html` | 招待ページ(T11 の `web/invite/index.html` の複製) |
| `site/assets/` | CSS・アイコン・スクリーンショット3枚(SVG) |
| `site.json` | 公開先と未確定の値(`null` は「未確定」) |
| `tools/build_site.py` | 生成器(標準ライブラリだけ。Markdown パーサも自前) |
| `tools/test_build_site.py` | 検査(47 件) |

## 公開先

**2026-10-20 オーナー承認済み**: #76 の返信
https://github.com/Ryoki63/Challenge/issues/76#issuecomment-6287900053 で推奨案を採用。
公開先の再承認は不要。承認は未提供の法務情報や X ハンドルを補うものではない。
再開時点の受入確認と未達項目は [PUBLISH-STATUS.md](PUBLISH-STATUS.md) を参照。

アプリの `ios/Lien/Core/SupportLinks.swift` の `webBaseURL` と同じ土台にする(審査で開く URL の正本)。

- ティザー: https://ryoki63.github.io/Challenge/
- プライバシーポリシー: https://ryoki63.github.io/Challenge/lien/legal/privacy.html
- 利用規約: https://ryoki63.github.io/Challenge/lien/legal/terms.html
- 招待: https://ryoki63.github.io/Challenge/lien/i/?t=XXXXXXXX

`site.json` の `baseUrl` を変えると、`og:url` と法務ページの戻りリンクが変わる。
`SupportLinks.swift` と食い違うとテストが落ちる(`test_base_url_matches_the_app_support_links`)。

## 生成する

```bash
cd products/lien/web
python3 tools/build_site.py            # 生成(marketing/legal/*.html と site/ を書き換える)
python3 tools/build_site.py --check    # コミット済みの生成物と一致するか(CI と同じ)
python3 tools/build_site.py --check-publishable  # 公開してよい状態か
python3 -m unittest discover -s tools -p "test_*.py" -v
```

**Markdown が正本。HTML を手で編集しない。** `marketing/privacy-policy.md` / `terms.md` を直したら
必ず再生成してコミットする(忘れると `lien-ci` の `pages-site` が落ちる)。

生成されるもの:

- `marketing/legal/privacy.html` / `terms.html` … 既存の公開先(チェックリストが参照する正本)
- `web/site/` … 配信物。法務ページは上と同じ中身を置く

## 公開の前に(人間の作業)

公開前に次を揃える。`--check-publishable` は1・2を検査するが、Pages の有効化や
文言レビュー完了を検査するものではない。生成成功・検査成功と公開成功を区別する。

1. **G4(#42)のプレースホルダを埋める** — `marketing/privacy-policy.md` / `terms.md` の
   `【要記入: G4: …】` 4項目(制定日・事業者名・連絡先メール・管轄裁判所)。
   `marketing/legal/CHECKLIST-G4.md` §1 の表のとおりに置換して再生成する
2. **X の @ハンドルを決める** — `site.json` の `xUrl`(例 `https://x.com/<handle>`)。
   未設定のあいだ、ティザーに X のリンクは出ない(実在しないアカウントを指さないため)
3. **GitHub Pages を有効にする** — リポジトリの Settings > Pages > Build and deployment >
   Source を **「GitHub Actions」** にする(初回だけ)
4. **mkt-review の文言レビュー** — 対象と判定を記録する。マージや制作者の自己点検を
   レビュー済みの証拠にしない。公開を妨げる未解決指摘があれば配信しない

そのうえで Actions の `lien-pages` を手で実行する(`workflow_dispatch`)。
G4 が済んだら `.github/workflows/lien-pages.yml` の `on:` に push のパス条件を足せば自動配信になる。

`appStoreUrl` を入れると、ティザーの「近日公開」が App Store リンクに変わる(公開後に差し替える)。
`contactEmail` を入れると、サポート欄に問い合わせ先が出る(入れるまでは「アプリ内のお問い合わせ」だけ)。

## 決めごと

- **入力フォームを置かない**。メールアドレスを集めない(issue #76 の完了条件)。
  置いてあるのはリンクと文章だけ
- **外部スクリプト・外部フォント・CDN を読み込まない**。依存ゼロの静的ページ(計測 SDK も無し)
- **v1.0 に無い機能を書かない**。訴求の根拠は `docs/CONCEPT.md` §7 と `docs/REQUIREMENTS.md`
- **数値・順位・受賞を書かない**。デモの「23日」は `marketing/screenshots/plan.md` §2 の
  デモデータで、実績ではない
- 文言は `marketing/store_metadata/ja/`(ストア確定値)から取る。ティザー用に新しいコピーを作らない
- スクリーンショットは v4 の立ち絵(`assets/plant/v4_drafts/composed/`)を埋め込んだ SVG。
  実機キャプチャへの差し替えは #80(MK7)で行う
