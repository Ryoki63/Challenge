# Apple Developer 承認後ランブック(2026-10-25 作成)

状況: Apple Developer Program(個人)の申込み完了、承認待ち。Xcode は Mac に導入中。
目的: 承認メールが届いたら迷わず G0 → G3(TestFlight)へ進む。正は [ios/README.md §8](README.md) と [docs/TASKPLAN.md](../../../docs/TASKPLAN.md)。本書は「今日の時点の抜け」をまとめた作業表。

## 0. 今の準備状況(点検結果)

| 項目 | 状態 | 場所 |
|---|---|---|
| アイコン 1024×1024(アルファなし) | 済(v4 空色) | `assets/icon/icon_1024.png` |
| アプリ名・サブタイトル・キーワード・説明文 | 案あり(下の注意 A 参照) | `marketing/store_metadata/ja/` |
| スクリーンショット | 旧画風・旧範囲の SVG 下絵のみ。**UI とアートの凍結後(11/8 以降)に撮影し直す計画**(`plan.md`・TASKPLAN §9.4)。今は書き出さない | `marketing/screenshots/` |
| プライバシーポリシー / 利用規約 | 事業者名・連絡先・管轄裁判所を記入済み(2026-10-25)。**残りは制定日と公開(GitHub Pages)** | `marketing/privacy-policy.md`, `terms.md`, `legal/` |
| Xcode プロジェクト | `project.yml`(XcodeGen)あり。Bundle ID `com.ryoki63.lien` | `ios/project.yml` |
| Mac のツール | 導入済み: Xcode 26.6 / Homebrew 7.0.10 / mas 7.0.0 / XcodeGen 2.46.0(CI と同じ版) | — |

注意 A: キーワード欄は日本語で 100 文字以内。現行の `keywords.txt` は全体でその範囲か `verify_metadata.py` で確認する(`python3 marketing/tools/verify_metadata.py`)。

## 1. Mac 側の準備(承認前にできる)

- [x] Xcode のインストール完了(26.6)
- [ ] Xcode → Settings → Accounts → Apple ID を追加(承認前は Personal Team)
- [x] Xcode のライセンス同意済み
- [ ] `sudo xcodebuild -license accept`
- [x] Homebrew 導入済み
  `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
  → 終了時に表示される `eval "$(/opt/homebrew/bin/brew shellenv)"` を `~/.zprofile` に追記
- [x] `brew install mas xcodegen` 済み
- [ ] `cd products/lien/ios && cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` → Supabase の URL と anon キーを記入(**service_role は入れない。コミット禁止**)
- [x] `xcodegen generate` → シミュレータ(iPhone 17)でビルド成功・テスト 1061 件 失敗 0(2026-10-25)

## 2. 公開物の準備(承認前にできる。G4 の一部)

- [x] 事業者名: 小嶋諒樹(本名)
- [x] 問い合わせメール: ryoki.kojima.dev@outlook.jp(`SupportLinks.contactEmail` にも設定済み)
- [x] 管轄裁判所: 東京地方裁判所
- [x] プレースホルダ置換(制定日を除く)。**制定日は公開日に記入**
- [ ] GitHub Pages で `privacy.html` / `terms.html` を公開し、URL を確定(`SupportLinks.privacyURL` / `termsURL` とASC に同じ URL)
- [ ] サポート URL(問い合わせ先ページ)を用意する
- [ ] スクリーンショット: 機能凍結後に撮影し直す(旧下絵は使わない)

## 3. 税務・銀行(承認後。**個人情報なので本人が入力**。AI は入力しない)

無料アプリの v1.0 だけなら不要。v1.1 の課金を出す前に必要。先に手元へ揃える:
- [ ] 銀行口座情報(銀行名・支店・口座種別・口座番号・名義のローマ字)
- [ ] マイナンバー等の税務情報(日本居住者の場合、ASC の「ビジネス」で求められる項目を確認)
- [ ] ASC → ビジネス → 契約: 「有料App」契約に同意(課金開始時)
- [ ] 日本の特商法表記(v1.1。`CHECKLIST-G4.md` §5)

## 4. 承認後の作業(順序に注意)

1. [ ] 承認メール受信 → developer.apple.com/account で Membership 有効を確認、Team ID を控える
2. [ ] Certificates, Identifiers & Profiles → Identifiers → App ID(Explicit)`com.ryoki63.lien` を登録(**先にやる**。ASC の新規アプリで選べるのは登録済みのみ)
3. [ ] App Store Connect → 新規アプリ(iOS・名前は仮でよい・Bundle ID は上記)
4. [ ] ASC → ユーザとアクセス → 統合 → API キー発行(Admin 推奨)。`.p8` は 1 回しかダウンロードできない
5. [ ] GitHub Secrets に 6 件登録(`ASC_KEY_P8` / `ASC_KEY_ID` / `ASC_ISSUER_ID` / `APPLE_TEAM_ID` / `SUPABASE_URL` / `SUPABASE_ANON_KEY`)。値は**チャットや Vault に貼らない**
6. [ ] `gh workflow run lien-release.yml --repo Ryoki63/Challenge -f dry_run=true`(緑を確認)
7. [ ] `-f dry_run=false -f internal_only=true` で内部 TestFlight へ(法務ページ公開前の最初のビルド用)
8. [ ] TestFlight で処理完了を待ち、内部テスターに追加 → 実機 2 台で G1 計測(p50 ≦ 60 秒)
9. [ ] 外部テスト審査 → 知人 5〜10 ペアへ招待(G3)
10. [ ] APNs 認証キー(.p8)発行 → Supabase 側へ(DESIGN §7)

## 5. AI に頼めること(次の依頼候補)

- プレースホルダ置換(事業者名・メール・裁判所が決まったら)
- スクリーンショット SVG → PNG の書き出しと寸法検査
- `verify_metadata.py` の実行とメタデータ調整
- `xcodegen generate` とシミュレータビルド確認(Xcode 導入後)
