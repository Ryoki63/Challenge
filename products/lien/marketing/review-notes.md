# App Review Notes — Lien (v1.0)

- Status: **DRAFT** (T30準備 / issue #30 — prepared ahead of full backend deploy; see "状態" per section)
- Last updated: 2026-10-13
- Related issues: #30 (this task) / #8 (Supabase deploy, G0 待ち) / #23 (T23: 設定・通報・ブロック・アカウント削除。**実装済み** 2026-10-13) / #28 (T28準備は済み。内部 TestFlight は G0 の後) / #55 (W1: ソロモード・招待シート。完了) / #59 (PV: 相手の今日の写真。**実装済み**) / #61 (§1.1・§1.2 を W1 の実装に合わせた) / #65 (§1.1 の約束の編集の記述・ソロの植物の記述、§1.2 手順5の前提を実装に合わせた) / #69 (§1.1・§1.2・§1.4・§1.5 と §2.6 を PV・T23 の実装に合わせた)
- 正本の優先順位: `docs/REQUIREMENTS.md` → `docs/DESIGN.md` → `docs/CONCEPT.md`(矛盾時はこの順で優先)

> このファイルは2段構えです。**今回のコミット(T30準備)は「草案」**であり、TBDプレースホルダを含みます。T23(設定画面)・T08(G0後の本番デプロイ)・T28(TestFlightビルド)が完了した後、別コミットでTBDを実値に差し替えて完成させます(issue #30 の進め方コメントに記載された2段構え)。

---

## 1. App Review 用ノート本文(英語・App Store Connect "Notes for Review" 欄に貼る想定)

### 1.1 Solo mode works without a pair (no "must have 2 users" blocker)

Lien is a 2-person habit-tracking app, but **the app is fully usable before a pair is formed.** A new user can finish onboarding, set their own daily promise and check in without ever inviting anyone. One device is enough for everything in this section.

- New-install flow: onboarding (3 screens: concept → nickname + emoji icon → notification permission) → **promise setup (a screen of its own, shown right after onboarding)** → **Home in the "solo" state**. There is no sign-in screen (see §1.2). The nickname screen also asks the user to tick an explicit agreement to the Terms of Use and the Privacy Policy before the start button is enabled (§1.4).
- **Promise setup**: type a promise title (up to 20 characters), pick an emoji, optionally set a daily reminder time, then tap "この約束にする" (Set this promise).
- **Home in the solo state** shows the user's own promise, the check-in button "できた!" (Done!), a pot in which the small seed character ("タネの子") sleeps in the soil, with a short caption ("ペアになると、タネの子が目をさますよ", i.e. "When you pair up, the seed character wakes up"), and an invite button ("相手を招待する", i.e. "Invite your partner").
- **Checking in works in solo.** Tapping "できた!" records today's check-in; the button is replaced by the label "今日のぶんは完了" (Today's done) and an "取り消す" (Undo) button appears for same-day mis-taps. No pairing prompt blocks any of this.
- Deliberately **not available in solo** (these appear only once a pair exists): the shared streak, the partner's status, nudges, reactions and **photo attachment**. A photo is shared only with the paired partner, so in solo there is nothing to share it with and the "写真を添える" (Attach a photo) button is not shown. Once paired, the partner's photo of the day (if there is one) appears on Home as a thumbnail that opens full screen; it is read with a short-lived signed URL, kept in memory only, and v1.0 has no photo history or album (§1.2, step 6). The seed character keeps sleeping in the soil in solo (the soil glows softly after the user checks in); it wakes up and grows from the days on which both partners complete their promise.
- The "ふたりストリーク" (shared streak) starts counting from the day a pair is formed; it does not block any core action beforehand.
- Inviting is optional. The invite button on Home opens a sheet (title "ふたりをつなぐ") that can be closed at any time with "あとで" (Later).
- The promise can be edited later: Settings (the gear icon on Home) → 約束 (Promise) → 約束を変える (Change promise). Editing it does not reset the shared streak. Settings is also available in solo (profile, promise, a link to the iOS notification settings, contact / report, Terms of Use, Privacy Policy, sign out, delete account — see §1.4 and §1.5).
- Reviewer verification steps:
  1. Launch the app and tap "はじめる" (Start). Enter any nickname (up to 8 characters), pick an icon, tick the agreement check box "利用規約とプライバシーポリシーに同意します" (I agree to the Terms of Use and the Privacy Policy) and tap "同意してはじめる" (Agree and start; disabled until the box is ticked). On the notification screen, tap "通知を許可する" (Allow) or "あとで" (Later); either one continues.
  2. On the promise screen, type any title (e.g. "Walk"), pick an emoji and tap "この約束にする".
  3. You are now on Home in the solo state. Tap "できた!". Confirm that the check-in completes (the button is replaced by "今日のぶんは完了") and that nothing asks you to pair.
  4. (Optional) Tap the invite button, then "招待をつくる" (Create invite). A QR code, an 8-character invite code and a share-link button appear. Close the sheet with "あとで"; pairing is never required to keep using the app.
- Source of truth: `docs/REQUIREMENTS.md` §3.2 "招待待ちでも使える: ペア未成立でも約束設定とチェックインは可能(ソロ状態。写真はペア内の共有なので、ペア成立後に添付できる — #55)" — this was an explicit design decision made specifically to avoid an App Review rejection risk and first-day churn.

**状態: 2026-10-13 に W1(#55)の実装に合わせて書き直した(#61)。** 草案が実装とずれていた点:

| # | 草案の記述 | 実装(W1) |
|---|---|---|
| ① | Home で約束を設定する | オンボの後に**約束設定の独立画面**があり、保存すると Home に進む |
| ② | 写真を任意で添えられる(ペアなしでも) | **ソロでは写真を添えられない**(「写真を添える」は出ない。端末側で止めており、サーバーも photoPath 付きのソロの checkin を 400 `no_pair` で拒否する) |
| ③ | 植物が反応する | **ソロの鉢は、土の中で眠るタネの子**(`solo_seed`+zzz。PA #56 で描画)。自分がチェックインした日は土がほのかに光る(`fx_soil_glow`)が、葉や表情の変化(ふたりの葉・にっこり)はペア後。一言は「ペアになると、タネの子が目をさますよ」(`Strings.Widget.soloCaption` をホームと共有) |
| ④ | Settings を開いて招待を発行する | **招待は Home のボタン**から開くシート(設定画面は T23 #23 で入ったが、招待の入口は設定の中ではなく Home のボタンのまま) |

実ビルドでの最終確認は T28a の内部 TestFlight 以降(T30)。そのとき合わせるもの:
- PA(#56)は入った。ソロの鉢は「土の中で眠るタネの子」で、一言の現行の文言は「ペアになると、タネの子が目をさますよ」(旧文言「ペアになると種がまかれるよ」は#56 で置き換わった)。英文はこれに合わせて書き直した(#65)。実ビルドで、眠る絵・zzz・チェックイン後の土の光り方と一言が英文の記述どおりかを確かめる。PB(#57)が入った後も同じ記述でよいことを、コードで確かめた(2026-10-13・#69): ソロでは、ゲージの文・植物の名前・今日のひとこと・段階アップの演出・おかえりは出ない(どれもペアのときだけ。`GrowthGauge` はソロで nil、段階アップは `PlantMemory.observeStage` がソロを除く、ひとことは `homeDidAppear` がペアを条件にする)。ソロの鉢の見え方は PB の前と同じ
- 招待ボタンのラベルは、#62 で「パートナーを招待する」から「相手を招待する」に変わった(実装済み。CONCEPT §5-2: カップル限定にしない)。英文のボタン名は変更後のラベルで書いてある。実ビルドで合っているか確かめる
- **約束の編集の入口**: #65 の時点では、保存したあとに約束を編集する入口がアプリに無かった(設定画面は T23)ので、英文から「The promise can be edited later.」を外していた。**T23(#23)で入口が入った**(設定 → 約束 → 約束を変える。約束設定の画面を再利用し、リマインド時刻もここから変える。変えてもストリークは続く)ので、2026-10-13(#69)に英文へ戻した(入口の場所つき)。実ビルドで、入口の場所と文言が英文どおりかを確かめる(T30)。約束設定画面の副題(`Strings.PromiseSetup.subtitle`)の「あとからいつでも変えられます」も、入口ができたので事実と合った
- PV(#59)は 2026-10-13 に入った(相手の今日の写真をホームに出す。写真は v1.0 に残る)。写真に触れる記述は、本節の「写真を添える」・§1.2 の手順6・§1.4 の UGC。PV の機能が凍結(11/8)で外れることになった場合は、これらをそろえて外す(TASKPLAN §9.4)

### 1.2 No demo account is required — authentication is anonymous

Lien v1.0 uses **anonymous authentication only** (Supabase anonymous sign-in). There is no username/password and no email login, and the app offers no third-party or social sign-in at all. Sign in with Apple, for carrying data over to a new device, is planned for a later update and is not part of v1.0.

- The anonymous session is created automatically when the user submits the nickname screen of the onboarding; the user is never asked for credentials. A note on the same screen explains that no registration is needed and that progress may not carry over when changing devices or reinstalling the app.
- Because there is no credential-gated login, the standard "demo account username/password" field in App Store Connect does not apply in the traditional sense.
- Recommended answer for the "Sign-In Information" / demo account section: **"No login is required. The app creates an anonymous session automatically after the nickname is entered during onboarding. To try the 2-person features, pair two devices with an invite code — steps below."**
- Pairing demo procedure (two devices/simulators, or two TestFlight testers). The invite sheet opens from the Home screen, so each device first completes onboarding and promise setup (§1.1, steps 1–2).
  1. **Device A**, on Home: tap the invite button ("相手を招待する"), then "招待をつくる" (Create invite). A QR code, an 8-character alphanumeric invite code (case-sensitive, e.g. "AbCd2345") and a share-link button ("リンクをおくる") appear. An invite is valid for 72 hours and can be used once.
  2. **Device B**, on Home: tap the invite button, scroll to the "コードを入力" (Enter a code) section, type the 8-character code from Device A and tap "ペアになる" (Pair up).
     - Alternative: open the invite link on Device B. The "アプリで開く" (Open in app) button of the invite web page starts the app through `lien://invite/<code>`, and the same sheet opens with the code already filled in. The user still has to tap "ペアになる"; the app never pairs automatically.
  3. Both devices now show the paired Home screen. Device A's invite sheet closes by itself (while the sheet is open, Device A re-checks with the server at intervals that grow from 4 to 30 seconds; the app also refreshes at launch and whenever it returns to the foreground).
  4. Confirm that each device shows the other's nickname and promise (emoji + title) on Home, together with the shared streak and the plant. The icon emoji picked during onboarding is not shown to the partner in v1.0.
  5. Check in on Device A ("できた!"). Device B receives a push notification and its Home screen (and widget, if installed) update. The target is within about a minute. **This assumes that Device B is a physical iPhone and that its user allowed notifications** (tapped "通知を許可する" on the onboarding notification screen and accepted the iOS permission dialog): a device that has not allowed notifications is never registered for push, so neither the notification nor the push-driven widget update arrives. Without the permission, Device B's Home still updates when the app is opened or returns to the foreground.
  6. **Photos (optional, paired users only).** On Device A, after checking in, tap "写真を添える" (Attach a photo) and pick one photo from the photo library (taking a photo with the camera is not part of v1.0). On Device B, open Home: if A attached a photo today, a card "<A's nickname>の今日の写真" (A's photo of today) appears with a thumbnail; tap it to see the photo full screen. Only today's photo is shown. It is loaded with a short-lived signed URL and kept in memory only (nothing is saved on Device B), and v1.0 has no album of past photos. If the photo cannot be loaded (for example, the pair was dissolved), nothing is shown. Long-press the photo (or use the "…" menu at the top left of the full-screen view) to report it or to block the user — see §1.4. Access is enforced by the database's row-level security: only the current, active partner can read the file.

**状態: 2026-10-13 に W1(#55)の実装に合わせて書き直した(#61)。** 草案からの変更点:
- 招待コードは「8桁」ではなく**8文字英数**(大文字小文字を区別。紛らわしい 0/O/1/l は使わない — DESIGN §5.1)
- コードを入れる場所は、「招待コードを入力」ではなく、招待シートの「コードを入力」欄と「ペアになる」ボタン。招待の発行も受諾も、**Home のボタンから開くシート**で行う(Settings やオンボの途中ではない)。そのため、両端末とも約束設定まで済ませないとシートに着けない
- 招待リンクを開くとシートが開いてコードが入るが、**受諾は明示のタップ**(自動受諾しない — DESIGN §3.6)
- 相手の画面に出るのは**ニックネームと約束(絵文字+タイトル)**。オンボで選ぶアイコン絵文字(アバター)は出ない(snapshot に含まれず、アプリも描かない)
- Sign in with Apple は v1.0 に無い(v1.0.1 — D3)。草案の「任意の連携機能」という一文を、v1.0 の機能ではないと明記する形に直した。ガイドライン 4.8 の対象外と判断した根拠は REQUIREMENTS §3.1。残る `users.apple_sub` の行(§2.1)は T30 が直す(TASKPLAN §9.4「T30 への引き継ぎ」3)

実ビルドでの最終確認は T28a の内部 TestFlight 以降(T30)。確認点:
- 招待ページ(`web/invite`)を Pages で公開した後に、「アプリで開く」の経路を実機で通す(G3 の前までに公開する)
- オンボの注意書き(`Strings.Onboarding.anonymousStartNote`)は、PB(#57)で「登録なしですぐ始められます。機種変更やアプリの入れ直しでは、記録を引き継げない場合があります。」に直った(旧文言は「あとから Apple ID 連携(設定画面)が必要」と読めた)。英文の該当の一文("progress may not carry over when changing devices or reinstalling the app")と一致している。設定の補足(`Strings.Settings.accountFooter`)も同じ趣旨。実ビルドで確かめる(T30)
- 手順5は、受け取る側の端末が**通知を許可していることが前提**(許可しないと APNs 登録が始まらず、push もウィジェットの更新も届かない)。英文に明記した(#65)。審査員がオンボで「あとで」を選んだ場合に push が来ないのは仕様で、アプリを開く・前面に戻すと Home は追いつく。§1.1 の手順1は「許可」「あとで」のどちらでも進める書き方のままなので、2台のペアの確認をお願いするときは、先に許可してもらう案内を §1.3 に足すか(T30)
- 端末1台の審査員向けに、開発者が操作する相手役の招待コード(期限を延ばしたもの)を §1.3 に用意する(T30)。用意できたら本節の末尾に1行足す
- ペア後の写真の手順(添付 → 相手のホームに表示)は、PV(#59)の完了に合わせて手順6として足した(2026-10-13・#69)。実機 2 台で、添付 → 相手のホームの表示 → 全画面 → 長押しの通報までを確かめる(T20 の ⑧、T30)

### 1.3 Test pair accounts (2 pairs, as requested by App Review guidance)

Because authentication is anonymous, "test accounts" are provided as **two pre-paired invite demonstrations** rather than username/password credentials. Supabase project ref: `lniheehfbtpfhglinfjm`。

**前提の正確な状態(issue #38/#8のJOURNAL記録より)**: Supabaseバックエンド自体(migration適用・functions 7本デプロイ・匿名サインイン有効化)は**2026-06-11時点で完了済み**であり、技術的にはテストペアを作成できる状態にある。一方、G0(#38)の残項目は**Apple Developer Program加入のみ**(審査待ち)で、APNs(.p8キー)投入・実機G1計測はこれに連なる未完了項目。本タスク(T30準備)は文書化スコープであり、審査提出用の実データをここで本番環境に投入することはしない(「外部送信はタスク本文に明記された場合のみ」というAGENTS.md禁止事項、および issue #30 進め方手順5が「T08完了後」の別フェーズとして明示している通り)。したがって以下は**実行手順のみ準備済み・実行は次段階**という位置づけ。

| ペア | ユーザーA | ユーザーB | 招待コード/手順 | 状態 |
|---|---|---|---|---|
| テストペア1 | `TBD: 実行後に実値`(匿名UUID) | `TBD: 実行後に実値` | `TBD: 実行後に実値`(seed-pair.sh実行時に発行される8文字コードを記載) | **TBD — 審査専用ペアの作成実行待ち** |
| テストペア2 | `TBD: 実行後に実値` | `TBD: 実行後に実値` | `TBD: 実行後に実値` | **TBD — 審査専用ペアの作成実行待ち** |

**作成手順(次段コミットまたは人間が実行)**:
1. `products/lien/scripts/g1/seed-pair.sh` を実行する(`SUPABASE_URL` / `SUPABASE_ANON_KEY` 必須、`SUPABASE_SERVICE_ROLE_KEY` 推奨 — 約束のseedに必要)。このスクリプトは匿名ユーザー2人を作成し、invite-create→invite-acceptでペアを成立させる(詳細: `products/lien/scripts/g1/RUNBOOK.md`)。Supabaseバックエンド自体は稼働中のため、シークレット(`.env.keys`等)が揃えば即実行可能。
2. 本番用には**審査専用に新規のペアを2組作成**し、既存のG1計測用ペアとは分離する(使い捨て前提。シークレット・トークンはコミットしない)。
3. 発行された招待コード(8文字英数)と、各ユーザーに設定したニックネームをこの表に転記する。パスワード等は存在しない(匿名認証のため)。
4. TestFlightの外部テスト(T28/G3)でも同じペアをそのまま審査用デモとして使い回せる。

**状態: TBD(実行待ち)。ハーネス(seed-pair.sh)・バックエンド(Supabase)はいずれも実装済み・稼働確認済み。実データ投入は本タスクのスコープ外のため次段階(T30コミット②、または人間)に委ねる。**

### 1.4 Report flow and blocking (UGC — Guideline 1.2)

Lien has no public content, no feed, no search, no user directory and no chat. What one user can show another is limited to the **paired partner** (two people who exchanged an invite code): an **optional photo attached to a check-in**, the **nickname**, the **promise text** (title + emoji) and the **name given to the shared plant**. Nudges are fixed stamps (no free text).

- **Agreement to the terms**: the nickname screen of the onboarding asks the user to tick "利用規約とプライバシーポリシーに同意します" (I agree to the Terms of Use and the Privacy Policy). The start button "同意してはじめる" (Agree and start) stays disabled until it is ticked. The same screen links to both documents and says that inappropriate photos, words and nuisance behavior are prohibited and can be reported, or the pair dissolved.
- **Report** (available for every kind of content the partner can show): long-press the partner's photo on Home (the full-screen photo view has the same actions in a "…" menu at its top left), the partner's nickname / promise chip, or the plant's name, and choose 写真を通報する / ニックネームを通報する / 約束の文を通報する / 植物の名前を通報する (Report photo / nickname / promise text / plant name). VoiceOver users get the same actions as accessibility actions. A general report is also available at Settings → サポート → 不適切な内容を通報する (Report inappropriate content). After one confirmation ("この内容を通報しますか?" → "メールを開く" Open mail), the app opens an **e-mail draft addressed to the operator** — subject "【Lien】通報: <kind>", body with the pair ID, the date, the reported item (the photo's storage path, or the nickname / text) and the app version. The user reviews and sends it from the Mail app; **the app never sends anything by itself**. If the device has no mail account, an alert shows the operator's address so the report can be sent from another app. The address is the same one that is published in the Terms of Use and the Privacy Policy and behind Settings → サポート → お問い合わせ (Contact).
- **Block** = **pair dissolution**: the same long-press menu has "ブロック(ペアを解消)" (Block (dissolve the pair)), and Settings → ペア → "ペアを解消する" (Dissolve the pair) does the same. It is confirmed in two steps: an explanation screen (photos, promises and check-ins stop being visible to each other; nudges, reactions and notifications stop; the plant and streak records are archived and do not come back even if the same two people pair again; the user's own check-in history stays) and a final alert ("本当にペアを解消しますか?" → "解消する"). It takes effect at once on the server: the database's row-level security stops showing either user's photos, promises and check-ins to the other. The former partner gets no notification message; when they next open the app, it shows that the pair has ended (their Home returns to the solo state). The blocked user has no other way to reach the blocker: there is no messaging, search or directory in the app, and a new pair is formed only when the invited person accepts an invite themselves (they enter the code or open the link, then tap "ペアになる" (Pair up)).
- **Operator takedown rights**: the operator can remove violating content without prior notice (whether or not it was reported) and restrict, suspend or delete accounts, per `products/lien/marketing/terms.md` 第6条. A report carries the pair ID and the exact photo path or text, so the operator can find and remove the item (and, if needed, dissolve the pair or delete the account).
- **Terms of Service references** (audited against REQUIREMENTS §8③④, confirmed consistent):
  - 第6条(通報および運営者によるコンテンツの削除等) — `products/lien/marketing/terms.md:46-51`: 利用者からの通報導線、運営者による確認・削除、事前通知なしの削除権、違反利用者への利用制限/停止/削除の措置を規定。
  - 第7条(ブロックとペアの解消) — `products/lien/marketing/terms.md:53-56`: ペア解消=ブロック相当であることと、解消後の共有停止範囲を規定。
  - 第8条(アカウントの削除) — `products/lien/marketing/terms.md:58-61`: 設定画面からの削除導線とデータ消去を規定。
  - プライバシーポリシー §9(通報とコンテンツの削除)にも同趣旨の記載あり(`products/lien/marketing/privacy-policy.md`)。

**審査リスクの特記(issue #30の敵対検証より)**: 「ブロック=ペア解消」という解釈はApple審査で「相手を完全に遮断する手段がない(新規ペアを組まれ直す可能性?)」と誤解されるリスクがある。本アプリは1ユーザー1ペア(v1.0)で、ペア解消後は相手が自分に対して新たな共有関係を強制的に再構築する手段がないため、実質的に完全なブロックと同等である旨をレビューノート本文で明示する(上記説明文がその明示に該当)。

**状態: 2026-10-13 に T23(#23)の実装に合わせて書き直した(#69)。** 通報・ブロック(=ペア解消)・オンボの規約への明示の同意は、いずれも実装済み。サーバー側の pair-dissolve は本番にデプロイ済みで、本番の通しテスト S23〜S24(OPS §12。冪等・解消後の閲覧境界・組み直し)で確かめた。草案(T30準備)から変わった点:
- 通報の対象は写真だけではない。UGC として相手に見える文字(ニックネーム・約束の文・植物の名前)も、長押しで通報できる(英文の冒頭を「UGC は写真が1つだけ」から書き直した)。特定の対象を持たない「不適切な内容を通報する」(設定 → サポート)もある
- ブロックは設定だけでなく、長押しのメニューからもできる(どちらも同じ2段階の確認)
- 規約への明示の同意(旧 §2.6 の「未確認事項」)を実装した
- 通報の入口は「Settings → 通報」ではなく、Settings の「サポート」の中(「不適切な内容を通報する」)
- 運営が通報に対応する手順(該当の写真だけを消す / ペアを解消する / アカウントを消す)は OPS §13。ダッシュボードで auth ユーザーを直接消さない(幽霊のペアが残る)。通報の対応の期限・基準は G4(#42)で人間が決める

実ビルドでの最終確認(T30。T20 の ⑭⑮)で確かめること:
- 写真(カードと全画面の「…」)・ニックネームと約束の文・植物の名前の長押しと、設定の「不適切な内容を通報する」から、メールの下書きが開き、件名・本文(ペア ID・日付・対象・版)が英文どおりか。実機の VoiceOver でアクションが出るか
- 運営の連絡先 `SupportLinks.contactEmail` が **G4(#42)で確定して埋まっている**こと。空のままだと下書きに宛先が無い(外部テスト・審査に出す lien-release は、空だと止まる。内部 TestFlight 専用の `internal_only` を除く)。Terms・Privacy Policy の連絡先欄(`【要記入: G4: …】`)と同じアドレスにする
- 規約・プライバシーポリシーのリンク先が公開されている(Pages — TASKPLAN §9.2。HTTP 200 でないと lien-release が止まる)
- 解消すると、2 台目の画面が次の同期でソロに戻る(相手に通知が出ないこと)
- 設定のプロフィール編集の補足(`Strings.Settings.profileEditFooter`)は「ニックネームとアイコンは、ペアの相手にも表示されます」と書くが、v1.0 では**アイコン(絵文字)は相手の画面に出ない**(snapshot に含まれず、アプリも描かない — §1.2 手順4)。英文は事実のとおり(アイコンは相手に出ない)に書いてあるので、文言の側を直す(T27 または iOS の仕上げ)

### 1.5 Account deletion

Settings (the gear icon on Home) → アカウント → **"アカウントを削除する"** (Delete account). The deletion is confirmed in two steps: an explanation screen (what is deleted — the nickname, promise and check-in records, the photos the user attached, and the sharing with the partner, because the current pair is dissolved; "削除したあとは、元に戻せません。" It cannot be undone) and a final alert ("本当に削除しますか?" → "削除する").

What happens: the app calls the server function `delete-account`, which acts only on the account of the signed-in user. It (1) dissolves the user's active pair (the partner's app silently returns to the solo state), (2) deletes the user's photos from storage, (3) removes the pair data first if the user is the last remaining member (the partner had already deleted their account), then the user's pair membership, and finally (4) deletes the authentication user, which cascades to the profile, promise, check-ins, reactions, nudges and invites. The authentication user is removed last, so a failure in the middle (for example, no network) leaves the account usable: the app shows a message ("削除できませんでした。…もう一度押せば、続きから進みます") and the same button can be pressed again. On success the app erases its local data (the last snapshot and the pending queue), signs out, refreshes the widget and returns to the first onboarding screen.

The partner keeps their own records (their check-ins and the archived plant and streak of the dissolved pair); the deleted user's data is gone. Terms 第8条 / Privacy Policy §6 (保持期間とアカウントの削除) describe this to the end user.

"サインアウト" (Sign out) in the same section is a different action: it only wipes the device and keeps the server data (an anonymous account cannot be signed back into), and its confirmation says so and points to "アカウントを削除する" for users who also want the server records removed.

Reviewer verification: with any test account, open Settings → アカウント → アカウントを削除する, follow both confirmation steps, and confirm that the app returns to the welcome screen. Starting again creates a new anonymous account.

**状態: 2026-10-13 に T23(#23)の実装に合わせて書き直した(#69)。** delete-account は本番にデプロイ済みで、本番の通しテスト S25・S26(OPS §12。現役のペアあり / 最後の所属者 / ソロの 3 通りを実際に消して、DB と Storage に残らないこと・相手が無傷なことを確認)で確かめた。草案の「`auth.users` の cascade で消える」だけの記述を、実装の順序(ペアの解消 → 写真 → 本人しか居ないペア → 所属 → auth ユーザー)と、失敗してもやり直せる性質に書き直した。実ビルドでの再現は T30(T20 の ⑭)。運営が他人のアカウントを消すときは、ダッシュボードで auth ユーザーを直接消さずに OPS §13 の順序で行う(幽霊のペアが残るため)。

---

## 2. 提出前チェック(App Store Connect 提出時に必要な回答・設定の台帳)

REQUIREMENTS §8(6項目。2026-10-13 に、オンボの規約への明示の同意を独立した項目として足した)に加えて、App Store Connect 提出フローで実際に入力・判断が必要な項目をここに台帳化する。**Apple側の仕様詳細について確信が持てない記述は「要確認」と明記し、断定しない。**

### 2.1 App Store Connect「アプリのプライバシー」(データ収集の申告)草案

実装(`products/lien/supabase/migrations/0001_init.sql`)と `products/lien/marketing/privacy-policy.md` §1 の記載から、収集データを以下のように整理する。**Apple の「App Privacy」質問票のカテゴリ名・選択肢の正確な文言は要確認**(Appleの分類は "Contact Info" "User Content" "Identifiers" "Usage Data" 等のカテゴリに分かれるが、本アプリのどのフィールドがどのサブカテゴリに正確に対応するかは App Store Connect 上で実際の質問票を見ながら最終判断する必要がある)。

| データ種別 | 実装上のフィールド | 用途 | トラッキングに使うか | App Privacyカテゴリ(草案・要確認) |
|---|---|---|---|---|
| ニックネーム | `users.nickname` | アプリ機能(表示名) | しない | User Content または Identifiers(要確認) |
| アイコン絵文字 | `users.avatar_emoji` | アプリ機能(表示) | しない | User Content(要確認) |
| 約束の内容(タイトル・絵文字・リマインド時刻) | `promises.title/emoji/remind_at` | アプリ機能 | しない | User Content(要確認) |
| チェックイン記録(日付) | `checkins.date_local` | アプリ機能 | しない | User Content(要確認) |
| 写真(任意) | `checkins.photo_path`(Storage) | アプリ機能(ペア内共有) | しない | Photos or Videos |
| プッシュ通知トークン | `users.push_token` | 通知送信 | しない | Identifiers → Device ID(要確認。APNsトークン自体の分類は要確認) |
| タイムゾーン | `users.timezone` | 日付判定 | しない | Usage Data(要確認) |
| Sign in with Apple識別子(任意連携・T24未実装) | `users.apple_sub` | アカウント連携 | しない | Identifiers → User ID(要確認) |
| 利用状況の統計情報 | REQUIREMENTS §7(自前テーブル or TelemetryDeck。**どちらを採用するか未決定** — 現状コードに計測SDK実装は無し) | 品質改善 | しない | Usage Data(要確認。採用手段が確定するまで最終回答不可) |

**本アプリが収集しないと明記しているもの(privacy-policy.md冒頭)**: 位置情報・連絡先・広告識別子(IDFA)。これらは「収集なし」で回答できる想定(要確認)。

**トラッキングの有無**: 広告目的の第三者トラッキング(ATT)は実装なし → "Data Used to Track You" は該当なしと回答できる想定(要確認)。

**状態: 準備済み(草案)。最終回答は①REQUIREMENTS §7の計測手段(自前 or TelemetryDeck)の確定(CHECKLIST-G4.md 項目と同一)、②G4での事業者名/連絡先確定、③実機提出直前の再チェックが必要。確定は人間判断(G4/#42)+T28/G5担当者。**

### 2.2 年齢レーティング(Age Rating)質問票の想定回答

- 想定レーティング: **4+**(`terms.md` 第4条・`aso.md` に記載済み)。
- 想定根拠: 暴力・性的表現・ギャンブル・アルコール/薬物表現など、レーティングを上げる要素を含まない。UGC(写真)はペア内非公開共有のみで、不特定多数への公開機能はない。
- **要確認**: Apple の年齢レーティング質問票は2024年に新形式(年齢帯 4+/9+/12+/17+、カテゴリ別の頻度選択)に変更されている認識があるが、質問項目の正確な文言・選択肢・UGCの扱われ方(「ユーザー生成コンテンツの有無」を問う項目がどう4+判定に影響するか)はApp Store Connect上で実際の質問票を見て回答する必要があり、本ドラフトでは断定しない。
- **要確認**: UGCが存在する(写真共有機能がある)こと自体が年齢レーティングの質問票でどう扱われるかは、実際の質問内容を見て判断する。

**状態: 想定(4+)は準備済み。質問票の正確な回答は提出時(T28/G5)に要確認で進める。**

### 2.3 Export Compliance(暗号化の輸出コンプライアンス)

- `products/lien/ios/project.yml` の Info.plist 設定で **`ITSAppUsesNonExemptEncryption: false`** が既に設定済み(project.yml:54、T06実装時点)。
- 本アプリが使う暗号化は標準のHTTPS/TLS通信のみ(Supabase REST/Functions呼び出し、APNs)。独自暗号アルゴリズムの実装・カスタム暗号ライブラリは使用していない(コード上確認: 外部依存はsupabase-swiftのみ、DESIGN §3.1)。
- 一般的な理解として、標準OS提供の暗号化(HTTPS/TLS)のみを使うアプリは輸出コンプライアンス上の「免除」対象になることが多いという認識があるが、**この分類の正確な適用条件(免除カテゴリの文言・該当条文)はApple/米国輸出関連規則の正確な引用が必要なため要確認**とし、本ドラフトでは断定しない。
- `ITSAppUsesNonExemptEncryption: false` を設定済みであれば、通常はApp Store Connect提出時の輸出コンプライアンス質問が自動的にスキップされる(Info.plistの値が優先される)という理解があるが、これも**挙動の詳細は要確認**。

**状態: Info.plist設定は準備済み(project.yml:54、既存)。質問票が出た場合の回答根拠整理も準備済み。提出時(T28)に実際の挙動を確認し、想定外の挙動であれば本ファイルを更新する。**

### 2.4 Support URL / Privacy Policy URL の公開先

- 現状、`products/lien/marketing/legal/privacy.html` / `terms.html` は**リポジトリ内に存在するが、まだどこにもホストされていない**。
- `products/lien/marketing/legal/CHECKLIST-G4.md` 3節に「GitHub Pages の公開URLを確定する」とあるが、**具体的なURL(リポジトリ公開設定・パス構成)はまだ決定していない** — これは人間判断が必要な項目(下記「人間判断が必要な項目」参照)。
- Support URL(問い合わせ先)についても、`terms.md`/`privacy-policy.md`の連絡先メールアドレスが`【要記入: G4: 連絡先メールアドレス】`のまま未確定。Support URLとして専用ページを作るか、`mailto:`リンクのみにするかも未決定。
- 本リポジトリは `Ryoki63/Challenge` でPublicに設定済み(GitHub Pages自体は技術的に有効化可能な状態)。ただしこのリポジトリは本アプリ専用ではなく複数ドキュメントを含む構成のため、Pages公開時の対象ディレクトリ・公開範囲は要検討。

**状態: 人間ゲート(G4/#42)待ち。本タスクでは決定不可 — 下記「人間判断が必要な項目」に記載。**

### 2.5 テストペア2組の準備手順(審査用デモアカウント)

§1.3 に詳細を記載済み。要約:

1. ハーネス `products/lien/scripts/g1/seed-pair.sh`(実装済み・動作確認済み)で匿名ユーザー×2→ペア成立を自動化できる。
2. `SUPABASE_SERVICE_ROLE_KEY` があれば約束(promise)も同時にseedできる(無いと `checkin` が `409 no_promise` になるため推奨)。
3. 審査用には既存のG1計測用ペアと分離して**新規に2組作成**し、使い捨て前提で管理する。
4. Supabaseバックエンド(migration適用・functions 7本デプロイ・匿名サインイン有効化)は2026-06-11時点で既に完了・稼働済み(詳細: `products/lien/scripts/g1/RUNBOOK.md`、issue #8/#38のJOURNAL記録)。したがって本手順の実行自体に技術的な前提待ちはない。

**状態: ハーネス・バックエンドともに準備済み(稼働確認済み)。審査専用の2組作成という実データ投入そのものは、本タスク(文書化スコープ)では実施せず次段階(T30コミット②または人間)に委ねる。現時点では実行していない(§1.3のTBDはこの未実行を指す)。G0(#38)の残項目(Apple Developer Program加入)はAPNs投入・実機G1計測・TestFlight提出に必要だが、テストペア作成自体の前提ではない。**

### 2.6 UGC Guideline 1.2 適合性の総括

§1.4と内容重複するため要点のみ再掲:

| 要件 | 対応 | 状態 |
|---|---|---|
| 通報の仕組み | 長押し(写真・ニックネーム・約束の文・植物の名前)と Settings → サポート → 不適切な内容を通報する(mailto。ペア ID・日付・対象・版を入れる。自動では送らない) | **実装済み(T23 #23)**。規約(terms.md第6条)記載済み。宛先は G4 待ち |
| 不適切ユーザーの排除(block) | 長押しの「ブロック(ペアを解消)」と Settings → ペアを解消する(確認2段階)で共有を完全停止 | **実装済み(T23 #23)**。規約(terms.md第7条)記載済み |
| 利用規約への同意 | オンボのニックネーム画面で、規約・プライバシーポリシーへの同意のチェックが入るまで「同意してはじめる」を押せない(リンクと禁止事項の注意書きつき)。規約・ポリシーへのリンクは設定にもある | **実装済み(T23 #23)**。旧「未確認事項」(issue #30 の敵対検証の懸念)は解消。実ビルドでの確認は T30 |
| コンテンツの連絡先情報公開 | 運営者連絡先(メール)は`terms.md`/`privacy-policy.md`に記載欄あり、現在プレースホルダ。アプリ側も `SupportLinks.contactEmail` が空(通報・お問い合わせのメールの宛先になる)。G4 で同じアドレスに揃える | **G4(#42)待ち** |

---

## 3. 証跡(terms.md 監査結果 — issue #30 進め方手順2)

`products/lien/marketing/terms.md` を読み、§8③④の「規約記載」要件を満たすことを確認した:

- 第6条(通報および運営者によるコンテンツの削除等): `products/lien/marketing/terms.md:46-51`
- 第7条(ブロックとペアの解消): `products/lien/marketing/terms.md:53-56`
- 第8条(アカウントの削除): `products/lien/marketing/terms.md:58-61`

いずれも条文としては記載済み。アプリ側の UI/API(T23)も 2026-10-13 に実装済み(§1.4・§1.5・§2.6)。

---

## 4. 人間判断が必要な項目(まとめ)

- **Support URL / Privacy Policy URL の公開先が未確定**: GitHub Pagesのどのパスで `privacy.html` / `terms.html` を公開するか(リポジトリ公開範囲含む)。`CHECKLIST-G4.md` 3節参照。G4(#42)で決定。
- **事業者名・連絡先メールアドレス・制定日・管轄裁判所が未確定**: `terms.md` / `privacy-policy.md` の `【要記入: G4: ...】` 箇所。G4(#42)で決定。
- **利用状況計測手段(自前テーブル or TelemetryDeck)が未確定**: REQUIREMENTS §7。App Privacy回答(本ファイル§2.1)の最終確定に影響する。CHECKLIST-G4.md項目と同一。
- **年齢レーティング質問票・Export Compliance質問票の正確な回答**: Apple側の最新の質問文言はApp Store Connect上で実際に確認する必要があり、本ドラフトは想定(4+、免除想定)に留めている(要確認)。
- ~~**オンボーディングでの利用規約同意UIの要否**~~ → 2026-10-13 に T23(#23)で実装した(§1.4・§2.6)。残るのは、実ビルドでの確認(T30)と、リンク先の公開(Pages・G4 — 上の「Support URL / Privacy Policy URL の公開先」)。
