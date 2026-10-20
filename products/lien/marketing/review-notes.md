# App Review Notes — Lien (v1.0)

- Status: **FINAL DRAFT — 文書側は 2026-10-20 に確定。実ビルド(内部 TestFlight)での確認だけが残り**(G0 #38 の Apple 承認後。TASKPLAN §9.2)
- Last updated: 2026-10-20
- Related issues: #30 (this task) / #8 (Supabase deploy, G0 待ち) / #23 (T23: 設定・通報・ブロック・アカウント削除。**実装済み** 2026-10-13) / #28 (T28準備は済み。内部 TestFlight は G0 の後) / #55 (W1: ソロモード・招待シート。完了) / #58 (レビューで見つかった文書の食い違い。**T30 で 2026-10-20 に反映**) / #59 (PV: 相手の今日の写真。**実装済み**) / #61 (§1.1・§1.2 を W1 の実装に合わせた) / #65 (§1.1 の約束の編集の記述・ソロの植物の記述、§1.2 手順5の前提を実装に合わせた) / #69 (§1.1・§1.2・§1.4・§1.5 と §2.6 を PV・T23 の実装に合わせた) / #81 (公開目標 10/31・機能凍結 10/24 への前倒し)
- 正本の優先順位: `docs/REQUIREMENTS.md` → `docs/DESIGN.md` → `docs/CONCEPT.md`(矛盾時はこの順で優先)

> 2026-10-20 の更新で、依存ゼロの文書側を確定しました: §1.3 の審査用デモ運用(相手役の操作スクリプト+提出日に発行する招待コード)、§2.1 の App Privacy 草案(D6 と `PrivacyInfo.xcprivacy` に一致)、§2.2 の年齢レーティング(UGC 設問)、§2.7 のプライバシーマニフェスト、#58 の引き継ぎ(D6・D3)の反映です。**残るのは、G0 後の内部 TestFlight での実ビルド確認(§1.1・§1.4・§1.5)と、審査提出日(10/27)に App Store Connect の Notes for Review へ招待コードを記入する運用だけ**です。コードは 72 時間で失効する使い捨てなので、リポジトリには書きません(§1.3)。

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
- The promise can be edited later: Settings (the gear icon on Home) → 約束 (Promise) → 約束を変える (Change promise). Editing it does not reset the shared streak. Settings is also available in solo (profile, promise, in-app notification settings — reminder on/off and time, streak-risk on/off, plus a link to the iOS notification settings — contact / report, Terms of Use, Privacy Policy, sign out, delete account — see §1.4 and §1.5).
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

**2026-10-20 にコードで確かめたこと(T30。実ビルドの前の突き合わせ)**: 英文が出す画面・文言・分岐は、次の実装と一致している。
- オンボは3画面(コンセプト → ニックネーム+アイコン → 通知)。ニックネーム画面の同意チェック `Strings.Onboarding.consentLabel`(「利用規約とプライバシーポリシーに同意します」)が入るまで `profileSubmit`(「同意してはじめる」)は押せない(`OnboardingView.swift`)。通知は「通知を許可する」「あとで」のどちらでも進む。
- 約束設定は独立画面(`Strings.PromiseSetup`)。保存すると Home へ。ソロの Home は `Strings.Home.soloCaption`(「ペアになると、タネの子が目をさますよ」)・`inviteButton`(「相手を招待する」)・`attachPhotoButton` を出さない(写真はペア成立後のみ。サーバーも photoPath 付きのソロの checkin を 400 `no_pair` で拒否する — `checkin/core.ts`)。
- ソロでは、ゲージの文・植物の名前・今日のひとこと・段階アップの演出・おかえりは出ない(`GrowthGauge` はソロで nil、`PlantMemory.observeStage` がソロを除く、ひとことは `homeDidAppear` がペアを条件にする)。ソロの鉢は `solo_seed`+zzz で、チェックインした日は土がほのかに光る(`fx_soil_glow`)。
- 招待は Home のボタンから開くシート(`Strings.Pairing.title` =「ふたりをつなぐ」、閉じる `closeButton` =「あとで」)。発行は「招待をつくる」、受諾は「コードを入力」+「ペアになる」。コードは8文字英数(大文字小文字を区別)・72時間・1回きり(`invite-create/core.ts` の `INVITE_TTL_HOURS = 72`)。
- 設定は 約束(「約束を変える」)・通知・ペア(「ペアを解消する」)・サポート(「不適切な内容を通報する」)・アカウント(「アカウントを削除する」)の順で、英文の入口の場所と一致する(`SettingsView.swift`・`Strings.Settings`)。

実ビルドでの最終確認は T28a の内部 TestFlight 以降(T30)。**コードで一致を確認済みなので、実ビルドで見るのは「見た目・操作・通知の実配送」だけ**。そのとき合わせるもの:
- PA(#56)は入った。ソロの鉢は「土の中で眠るタネの子」で、一言の現行の文言は「ペアになると、タネの子が目をさますよ」(旧文言「ペアになると種がまかれるよ」は#56 で置き換わった)。英文はこれに合わせて書き直した(#65)。実ビルドで、眠る絵・zzz・チェックイン後の土の光り方と一言が英文の記述どおりかを確かめる。PB(#57)が入った後も同じ記述でよいことを、コードで確かめた(2026-10-13・#69): ソロでは、ゲージの文・植物の名前・今日のひとこと・段階アップの演出・おかえりは出ない(どれもペアのときだけ。`GrowthGauge` はソロで nil、段階アップは `PlantMemory.observeStage` がソロを除く、ひとことは `homeDidAppear` がペアを条件にする)。ソロの鉢の見え方は PB の前と同じ
- 招待ボタンのラベルは、#62 で「パートナーを招待する」から「相手を招待する」に変わった(実装済み。CONCEPT §5-2: カップル限定にしない)。英文のボタン名は変更後のラベルで書いてある。実ビルドで合っているか確かめる
- **約束の編集の入口**: #65 の時点では、保存したあとに約束を編集する入口がアプリに無かった(設定画面は T23)ので、英文から「The promise can be edited later.」を外していた。**T23(#23)で入口が入った**(設定 → 約束 → 約束を変える。約束設定の画面を再利用し、リマインド時刻もここから変える。変えてもストリークは続く)ので、2026-10-13(#69)に英文へ戻した(入口の場所つき)。実ビルドで、入口の場所と文言が英文どおりかを確かめる(T30)。約束設定画面の副題(`Strings.PromiseSetup.subtitle`)の「あとからいつでも変えられます」も、入口ができたので事実と合った
- PV(#59)は 2026-10-13 に入った(相手の今日の写真をホームに出す。写真は v1.0 に残る)。写真に触れる記述は、本節の「写真を添える」・§1.2 の手順6・§1.4 の UGC。PV の機能が凍結(10/24)で外れることになった場合は、これらをそろえて外す(TASKPLAN §9.4)

### 1.2 No demo account is required — authentication is anonymous

Lien v1.0 uses **anonymous authentication only** (Supabase anonymous sign-in). There is no username/password and no email login, and the app offers no third-party or social sign-in at all. Sign in with Apple, for carrying data over to a new device, is planned for a later update and is not part of v1.0.

- The anonymous session is created automatically when the user submits the nickname screen of the onboarding; the user is never asked for credentials. A note on the same screen explains that no registration is needed and that progress may not carry over when changing devices or reinstalling the app.
- Because there is no credential-gated login, the standard "demo account username/password" field in App Store Connect does not apply in the traditional sense.
- Recommended answer for the "Sign-In Information" / demo account section: **"No login is required. The app creates an anonymous session automatically after the nickname is entered during onboarding. To try the 2-person features on one device, enter the invite code in the Notes below to pair with our partner account (§1.3), or pair two devices with an invite code (§1.2)."**
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
- Sign in with Apple は v1.0 に無い(v1.0.1 — D3)。草案の「任意の連携機能」という一文を、v1.0 の機能ではないと明記する形に直した。ガイドライン 4.8 の対象外と判断した根拠は REQUIREMENTS §3.1。**§2.1 の `users.apple_sub` の行は 2026-10-20 に T30 で外した**(v1.0 では取得しない。v1.0.1 で追加するときに戻す)

実ビルドでの最終確認は T28a の内部 TestFlight 以降(T30)。確認点:
- 招待ページ(`web/invite`)を Pages で公開した後に、「アプリで開く」の経路を実機で通す(G3 の前までに公開する)
- オンボの注意書き(`Strings.Onboarding.anonymousStartNote`)は、PB(#57)で「登録なしですぐ始められます。機種変更やアプリの入れ直しでは、記録を引き継げない場合があります。」に直った(旧文言は「あとから Apple ID 連携(設定画面)が必要」と読めた)。英文の該当の一文("progress may not carry over when changing devices or reinstalling the app")と一致している。設定の補足(`Strings.Settings.accountFooter`)も同じ趣旨。実ビルドで確かめる(T30)
- 手順5は、受け取る側の端末が**通知を許可していることが前提**(許可しないと APNs 登録が始まらず、push もウィジェットの更新も届かない)。英文に明記した(#65)。審査員がオンボで「あとで」を選んだ場合に push が来ないのは仕様で、アプリを開く・前面に戻すと Home は追いつく。§1.1 の手順1は「許可」「あとで」のどちらでも進める書き方のままなので、§1.3 の Notes for Review には「先に通知を許可してください」という一文も入れる(2026-10-20 に運用へ反映)
- 端末1台の審査員向けの相手役は、**§1.3 のデモ運用に確定した(2026-10-20)**。招待コードは提出日に発行して App Store Connect の Notes for Review に記入し、リポジトリには置かない(72時間で失効する使い捨てのため)。
- ペア後の写真の手順(添付 → 相手のホームに表示)は、PV(#59)の完了に合わせて手順6として足した(2026-10-13・#69)。実機 2 台で、添付 → 相手のホームの表示 → 全画面 → 長押しの通報までを確かめる(T20 の ⑧、T30)
- **2026-10-20 時点の外部リンク**: `SupportLinks.webBaseURL` の下(規約・プライバシーポリシー・招待ページ)はまだ公開されておらず、HTTP 404 を確認した。`SupportLinks.contactEmail` も空のまま。どちらも G4(#42)で、埋まるまで外部テスト・審査に出す lien-release は止まる(`internal_only` を除く)。リンク先の値は `SupportLinks.swift` の2行に集約してあり、公開後に実機で開くのを確かめる(T30 の残り)

### 1.3 Test pair accounts (2 pairs, as requested by App Review guidance)

Lien v1.0 uses **anonymous authentication** (see §1.2): there are **no usernames, passwords or demo credentials to hand over**. For App Review, a "test pair" is therefore provided as **an invite code plus a partner account that we operate**, not as an account/password pair.

Two demonstrations are prepared. **Demo B needs only one device and is the recommended path for App Review**; Demo A (two devices) is in §1.2.

| Demonstration | What the reviewer does | What we provide | Where the value lives |
|---|---|---|---|
| **A. Two devices (self-service)** | Complete onboarding and promise setup on two devices, then pair them with an invite code (§1.2, steps 1–3) | Nothing account-specific | — |
| **B. One device + our partner (2 pairs)** | Complete onboarding and promise setup, open the invite sheet from Home, enter the 8-character code under "コードを入力", and tap "ペアになる" | Two partner accounts ("レビュー相手1" / "レビュー相手2") and **fresh invite codes** | App Store Connect → App Review Information → Notes for Review (entered on the submission day; **never committed to this repository**) |

**Why the codes are not in this file:** an invite is valid for **72 hours and can be used once** (`INVITE_TTL_HOURS = 72` in `supabase/functions/invite-create/core.ts` / REQUIREMENTS §3.2). A code written here would be expired by the time a reviewer reads it, and a live code in a public repository would let anyone pair with the demo partner. The operator issues the codes on the submission day and, if review is delayed past 72 hours, issues new ones and updates the Notes for Review. **No app update and no new build are needed for that** — only the ASC text changes.

**Operator procedure (the partner side).** The tool is `products/lien/scripts/review-demo/partner.sh` (a thin wrapper around `partner.ts`); usage and the security notes are in `products/lien/scripts/review-demo/README.md`. It uses only the public anon key (no service-role key), keeps the anonymous session in a local file outside the repository (default `~/.lien-review-demo/partner-<slot>.json`, mode 0600), and never prints tokens.

1. On the submission day, run `partner.sh create --slot 1` and `partner.sh create --slot 2` (env: `SUPABASE_URL`, `SUPABASE_ANON_KEY`). Each run creates the anonymous partner ("レビュー相手1" / "レビュー相手2"), sets a promise, creates an invite, and prints the 8-character code and its expiry (JST).
2. Paste both codes and the instruction into Notes for Review: "To try the 2-person features on one device, open Home → 相手を招待する → コードを入力, enter `<code>`, and tap ペアになる. Please allow notifications first (通知を許可する) so the partner's check-in notification arrives." Keep the session files; they are the only way to act as the partner later (anonymous accounts cannot be signed into again).
3. When the reviewer pairs, run `partner.sh status --slot 1` to confirm the pair, then `partner.sh checkin --slot 1` (optionally `--photo <file.jpg>`) so the reviewer sees the partner's check-in and (if a photo is attached) the photo card on Home. `partner.sh nudge --slot 1` sends a fixed-stamp nudge (no free text).
4. If the pair is dissolved or the code expires, run `partner.sh new-invite --slot 1` and update the Notes.
5. After review, run `partner.sh delete --slot 1` (and `--slot 2`) to remove the demo account and its data (the same `delete-account` function the app uses).

**Data separation:** the demo partners are new anonymous users with the nicknames "レビュー相手1" / "レビュー相手2", separate from the G1 measurement pairs. They hold no personal data. The script refuses to run without `SUPABASE_ANON_KEY`; no service-role key, APNs key or other secret is used or stored.

**Status: 手順・スクリプトは準備済み(2026-10-20)。残るのは提出日(10/27)のコード発行と Notes への記入、および実ビルドでのペア成立の確認(T30)。** The 2026-10-12 version of this section listed two placeholder rows for account UUIDs; that was based on the mistaken idea that credentials were needed. Anonymous auth has no credentials, so the rows are replaced by this operational procedure.

### 1.4 Report flow and blocking (UGC — Guideline 1.2)

Lien has no public content, no feed, no search, no user directory and no chat. What one user can show another is limited to the **paired partner** (two people who exchanged an invite code): an **optional photo attached to a check-in**, the **nickname**, the **promise text** (title + emoji) and the **name given to the shared plant**. Nudges are fixed stamps (no free text).

- **Agreement to the terms**: the nickname screen of the onboarding asks the user to tick "利用規約とプライバシーポリシーに同意します" (I agree to the Terms of Use and the Privacy Policy). The start button "同意してはじめる" (Agree and start) stays disabled until it is ticked. The same screen links to both documents and says that inappropriate photos, words and nuisance behavior are prohibited and can be reported, or the pair dissolved.
- **Report** (available for every kind of content the partner can show): long-press the partner's photo on Home (the full-screen photo view has the same actions in a "…" menu at its top left), the partner's nickname / promise chip, or the plant's name, and choose 写真を通報する / ニックネームを通報する / 約束の文を通報する / 植物の名前を通報する (Report photo / nickname / promise text / plant name). VoiceOver users get the same actions as accessibility actions. A general report is also available at Settings → サポート → 不適切な内容を通報する (Report inappropriate content). After one confirmation ("この内容を通報しますか?" → "メールを開く" Open mail), the app opens an **e-mail draft addressed to the operator** — subject "【Lien】通報: <kind>", body with the pair ID, the date, the reported item (the photo's storage path, or the nickname / text) and the app version. The user reviews and sends it from the Mail app; **the app never sends anything by itself**. If the device has no mail account, an alert shows the operator's address so the report can be sent from another app. The address is the same one that is published in the Terms of Use and the Privacy Policy and behind Settings → サポート → お問い合わせ (Contact).
- **Block** = **pair dissolution**: the same long-press menu has "ブロック(ペアを解消)" (Block (dissolve the pair)), and Settings → ペア → "ペアを解消する" (Dissolve the pair) does the same. It is confirmed in two steps: an explanation screen (photos, promises and check-ins stop being visible to each other; nudges, reactions and notifications stop; the plant and streak records are archived and do not come back even if the same two people pair again; the user's own check-in history stays) and a final alert ("本当にペアを解消しますか?" → "解消する"). It takes effect at once on the server: the database's row-level security stops showing either user's photos, promises and check-ins to the other. The former partner gets no notification message; when they next open the app, it shows that the pair has ended (their Home returns to the solo state). One exception is a local notification already scheduled on the former partner's device: the 9pm streak-risk notification may still be delivered **once**, with the former partner's name, because local notifications cannot be cancelled by the server and a silent push does not wake a force-quit app. It is at most one notification, it reveals no content, and the streak record itself is unaffected (the app removes it on the next launch). The blocked user has no other way to reach the blocker: there is no messaging, search or directory in the app, and a new pair is formed only when the invited person accepts an invite themselves (they enter the code or open the link, then tap "ペアになる" (Pair up)).
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

**2026-10-20 にコードで確かめた(T30)**: 通報の対象4種(写真・ニックネーム・約束の文・植物の名前)と設定の「不適切な内容を通報する」、2段階の確認、メール下書きの件名「【Lien】通報: <種別>」と本文(ペア ID・日付・対象・版)、宛先が空のときの案内は、`Strings.Report`・`ReportComposer.swift`・`ModerationViewModel.swift` のとおり。ブロックは長押しと設定の両方から同じ2段階で、`pair-dissolve` を呼ぶ。**コードで一致を確認済みなので、実ビルドで見るのは実機のメール下書き(VoiceOver のアクションを含む)だけ**。

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

**状態: 2026-10-13 に T23(#23)の実装に合わせて書き直した(#69)。** delete-account は本番にデプロイ済みで、本番の通しテスト S25・S26(OPS §12。現役のペアあり / 最後の所属者 / ソロの 3 通りを実際に消して、DB と Storage に残らないこと・相手が無傷なことを確認)で確かめた。**2026-10-20 にコードでも確かめた(T30)**: 削除の順序(ペアの解消 → 写真 → 本人しか居ないペア → 所属 → auth ユーザー)は `delete-account/core.ts`、失敗時に同じボタンで続きから進める文言と成功時の端末消去・サインアウト・オンボ復帰は `Strings.DeleteAccount`・`SettingsViewModel` の `DestructiveFlow`・`AppModel` のとおり。実ビルドで見るのは画面遷移だけ。草案の「`auth.users` の cascade で消える」だけの記述を、実装の順序(ペアの解消 → 写真 → 本人しか居ないペア → 所属 → auth ユーザー)と、失敗してもやり直せる性質に書き直した。実ビルドでの再現は T30(T20 の ⑭)。運営が他人のアカウントを消すときは、ダッシュボードで auth ユーザーを直接消さずに OPS §13 の順序で行う(幽霊のペアが残るため)。

---

## 2. 提出前チェック(App Store Connect 提出時に必要な回答・設定の台帳)

REQUIREMENTS §8(6項目。2026-10-13 に、オンボの規約への明示の同意を独立した項目として足した)に加えて、App Store Connect 提出フローで実際に入力・判断が必要な項目をここに台帳化する。**Apple側の仕様詳細について確信が持てない記述は「要確認」と明記し、断定しない。**

### 2.1 App Store Connect「アプリのプライバシー」(データ収集の申告)草案

実装(`products/lien/supabase/migrations/0001_init.sql` ほか)・`products/lien/ios/Lien/PrivacyInfo.xcprivacy`・`privacy-policy.md` §1 の3つを突き合わせた草案。**Apple の質問票のカテゴリ名・選択肢の正確な文言は App Store Connect 上で最終確認する**(提出時に質問票を見ながら確定する。ここは「何を・どの用途で・トラッキングするか」の判断を固定するための台帳)。

| App Privacy のデータ種別(草案) | `PrivacyInfo.xcprivacy` の型 | 実装上のフィールド | 用途 | 本人に紐づくか | トラッキング |
|---|---|---|---|---|---|
| 名前 | `NSPrivacyCollectedDataTypeName` | `users.nickname` | アプリ機能(相手への表示) | する | しない |
| 写真 | `NSPrivacyCollectedDataTypePhotosorVideos` | `checkins.photo_path`(Storage の `photos` バケット) | アプリ機能(ペア内の共有) | する | しない |
| その他のユーザーコンテンツ | `NSPrivacyCollectedDataTypeOtherUserContent` | `users.avatar_emoji` / `promises.title`・`emoji`・`remind_at` / `checkins.date_local`・時刻 / `plants.name` | アプリ機能(表示・記録・植物) | する | しない |
| ユーザー ID | `NSPrivacyCollectedDataTypeUserID` | auth の匿名ユーザー ID(`users.id`) | アプリ機能(アカウント・ペア・RLS) | する | しない |
| デバイス ID | `NSPrivacyCollectedDataTypeDeviceID` | `users.push_token`(APNs のデバイストークン) | アプリ機能(通知の送信) | する | しない |

- **タイムゾーン**(`users.timezone`): 位置情報ではなく、その日のチェックインを判定するためだけに使う。App Privacy に独立したカテゴリが無いため、提出時に「その他のユーザーコンテンツ」への包含でよいか、申告が要るかを質問票で確認する(マニフェストは `OtherUserContent` で包含している)。
- **収集しないもの**: 位置情報・連絡先・カレンダー・HealthKit・金融情報・購入(v1.0 は課金なし)・検索履歴・ブラウジング履歴・**利用状況(Usage Data)**・診断・広告データ。**v1.0 は分析 SDK も計測専用テーブルも入れず、アプリは計測のために何も送らない**(D6 / REQUIREMENTS §7)。クラッシュ収集 SDK も無い(Apple が利用者の同意で集めるクラッシュレポートは、アプリが送るものではない)。
- **トラッキング**: なし。ATT の対象になる第三者トラッキング・広告 SDK は無く、外部依存は `supabase-swift` だけ。`NSPrivacyTracking` は app / NSE / widget の3マニフェストとも `false`、`NSPrivacyTrackingDomains` は空。
- **Sign in with Apple**: v1.0 は提供しない(D3。§1.2)。したがって v1.0 の申告に SIWA の識別子(`users.apple_sub`)は含めない。v1.0.1 で追加するときは、`User ID` として申告し、`privacy-policy.md` §8 と本表を同時に更新する。
- **App Privacy の回答とマニフェストの一致**: 上の5型が `Lien/PrivacyInfo.xcprivacy` の `NSPrivacyCollectedDataTypes` と一致する。NSE と widget のマニフェストは収集データ・必須理由 API とも空(ペイロードを App Group に書く/読むだけ)。この一致は `products/lien/scripts/ops/marketing_docs_static_test.ts` が検査する(2026-10-20 追加)。

**状態: 草案を確定(2026-10-20)。D6(計測しない)と D3(SIWA は v1.0.1)を反映し、マニフェストと一致させた。** 残るのは、App Store Connect の質問票での最終確認(G4/G5。カテゴリ名・「Analytics 用途」の要否)と、G4 の連絡先・Pages 公開。機能のために保存する記録を品質改善に集計する場合の「用途」の申告は、提出時に質問票で決める。

### 2.2 年齢レーティング(Age Rating)質問票の想定回答

Apple は 2025-07-24 に年齢レーティングを改定し、**4+ / 9+ / 13+ / 16+ / 18+ の5段階**と、新しい必須質問(in-app controls / capabilities / medical or wellness / violent themes)を導入した(2026-01-31 までに全アプリが回答。以降の更新提出で未回答だと止まる)。**質問票の文言・選択肢は App Store Connect で最終確認する**(ここは回答の根拠を固定するための台帳)。

#### 想定回答(草案)

| セクション | 質問(要約) | 回答(草案) | 根拠 |
|---|---|---|---|
| In-app controls | 保護者による制限・年齢確認の仕組みがあるか | いいえ | 保護者向けの機能は無い。通報・ブロックは UGC の安全機能で、保護者による制限ではない |
| Capabilities | 無制限の Web アクセス(アプリ内ブラウザ)があるか | いいえ | アプリ内ブラウザは無い。規約・ポリシー・招待ページは Safari で開き、招待ページは `lien://` でアプリに戻るだけ |
| Capabilities | ユーザー生成コンテンツ(UGC)があるか | **はい** | ペアの相手にだけ見える写真(任意)・ニックネーム・約束の文・植物の名前。公開フィード・検索・ユーザー一覧は無い |
| Capabilities | ソーシャルメディアか | いいえ | フィード・フォロー・公開プロフィール・拡散が無い。1ユーザー1ペアの閉じた共有だけ |
| Capabilities | メッセージ・チャットがあるか | いいえ | 自由文の送受信が無い。つつきとリアクションは定型スタンプのみ |
| Capabilities | 広告があるか | いいえ | 広告 SDK なし(§2.1) |
| Medical or wellness | 健康・ウェルネスの話題があるか | **いいえ(要確認)** | アプリは習慣の記録であって、健康・運動・食事の助言やコンテンツを提供しない。利用者が自分で決めた約束(例: 散歩)を記録するだけ。**Apple が習慣アプリを wellness と見なす場合は「はい」= 9+** になるので、提出時に質問票の説明を確認して決める(推奨: いいえ。根拠をこのノートに書く) |
| Medical or wellness | 医療・治療の情報があるか | いいえ | 無い |
| Violence | 暴力(漫画的・現実的・残虐) | なし | 無い |
| Mature themes | 暴言・恐怖・アルコール/薬物・性的表現 | なし | 無い |
| Chance-based | ギャンブル・コンテスト | なし | 無い(植物の成長はふたり達成日の累計で、乱数の賭け事ではない) |

#### 想定結果

- 上の草案どおりなら **4+**(Capabilities の UGC = 4+、Messaging / Advertising = 4+)。**「健康・ウェルネス」を「はい」にすると 9+**。
- 4+ は `terms.md` 第4条(すべての年齢の方が利用できる内容)・`aso.md` の記載と一致する。9+ にする場合は、規約第4条の「4+」の文言も同時に直す(現在は 4+ と書いてある)。
- 自動計算より**高い**レーティングへの上書きはできるが、**低い**レーティングへの上書きはできない。迷う場合は高く申告するのが安全だが、本アプリは UGC をペア内だけに閉じ、通報・ブロック・規約同意・運営の連絡先(§1.4)を備えるので、4+ の根拠は説明できる。

#### UGC(Guideline 1.2)との関係

UGC の申告は、レーティングだけでなく Guideline 1.2 の4要件(不適切な内容への対策・通報・ブロック・公開された連絡先)を満たす必要がある。本アプリの対応は §1.4・§2.6 のとおり(通報・ブロック・規約同意は実装済み。連絡先だけ G4 待ち)。

**状態: 草案を確定(2026-10-20)。** 残るのは App Store Connect の質問票での最終確認(特に「健康・ウェルネス」の回答)と、G4 の連絡先。**質問票の正確な文言は提出時に確認する**(要確認)。

参照: [Updated age ratings in App Store Connect(Apple Developer News, 2025-07-24)](https://developer.apple.com/news/?id=ks775ehf) / [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions)

### 2.3 Export Compliance(暗号化の輸出コンプライアンス)

- `products/lien/ios/project.yml` の Info.plist 設定で **`ITSAppUsesNonExemptEncryption: false`** が既に設定済み(project.yml:54、T06実装時点)。
- 本アプリが使う暗号化は標準のHTTPS/TLS通信のみ(Supabase REST/Functions呼び出し、APNs)。独自暗号アルゴリズムの実装・カスタム暗号ライブラリは使用していない(コード上確認: 外部依存はsupabase-swiftのみ、DESIGN §3.1)。
- 一般的な理解として、標準OS提供の暗号化(HTTPS/TLS)のみを使うアプリは輸出コンプライアンス上の「免除」対象になることが多いという認識があるが、**この分類の正確な適用条件(免除カテゴリの文言・該当条文)はApple/米国輸出関連規則の正確な引用が必要なため要確認**とし、本ドラフトでは断定しない。
- `ITSAppUsesNonExemptEncryption: false` を設定済みであれば、通常はApp Store Connect提出時の輸出コンプライアンス質問が自動的にスキップされる(Info.plistの値が優先される)という理解があるが、これも**挙動の詳細は要確認**。

**状態: Info.plist設定は準備済み(project.yml:54、既存)。質問票が出た場合の回答根拠整理も準備済み。提出時(T28)に実際の挙動を確認し、想定外の挙動であれば本ファイルを更新する。**

### 2.4 Support URL / Privacy Policy URL の公開先

- 現状、`products/lien/marketing/legal/privacy.html` / `terms.html` は**リポジトリ内に存在するが、まだどこにもホストされていない**。**2026-10-20 に実際に開いて HTTP 404 を確認した**(`https://ryoki63.github.io/Challenge/lien/legal/privacy.html` と `.../lien/i/`)。
- `products/lien/marketing/legal/CHECKLIST-G4.md` 3節に「GitHub Pages の公開URLを確定する」とあるが、**具体的なURL(リポジトリ公開設定・パス構成)はまだ決定していない** — これは人間判断が必要な項目(下記「人間判断が必要な項目」参照)。
- Support URL(問い合わせ先)についても、`terms.md`/`privacy-policy.md`の連絡先メールアドレスが`【要記入: G4: 連絡先メールアドレス】`のまま未確定。Support URLとして専用ページを作るか、`mailto:`リンクのみにするかも未決定。
- 本リポジトリは `Ryoki63/Challenge` でPublicに設定済み(GitHub Pages自体は技術的に有効化可能な状態)。ただしこのリポジトリは本アプリ専用ではなく複数ドキュメントを含む構成のため、Pages公開時の対象ディレクトリ・公開範囲は要検討。
- アプリ側のリンク先は `SupportLinks.swift` の `webBaseURL` + `/lien/legal/{terms,privacy}.html` に集約してあり、公開後にこの2行(と `contactEmail`)を確定すれば全画面に反映される。**公開されるまで、外部テスト・審査に出す lien-release は HTTP 200 を確認できず止まる**(`internal_only` を除く)。

**状態: 人間ゲート(G4/#42)待ち。本タスクでは決定不可 — 下記「人間判断が必要な項目」に記載。** 2026-10-20 時点の公開状況(404)を確認済み。

### 2.5 テストペア2組の準備手順(審査用デモアカウント)

§1.3 に詳細を記載済み。要約:

1. **アカウント情報は存在しない**(匿名認証)。「テストペア」は、**招待コード+開発者が操作する相手役**として提供する(§1.3)。
2. 相手役は `products/lien/scripts/review-demo/partner.sh` で作る。`create --slot 1` / `--slot 2` で匿名ユーザー・約束・招待コードを用意し、`checkin`・`nudge`・`status`・`delete` で相手側の操作を再現する。公開の anon キーだけを使い、service-role キーは使わない。
3. 招待コードは **72時間・1回きり**なので、提出日(10/27)に発行して App Store Connect の Notes for Review に記入する。リポジトリには書かない。レビューが遅れて失効したら `new-invite` で再発行し、Notes を差し替える(アプリの再提出は不要)。
4. 既存のG1計測用ペアとは分離した新しい匿名ユーザーで、使い捨て前提。レビュー後に `delete` で消す。
5. Supabaseバックエンド(migration適用・functions デプロイ・匿名サインイン有効化)は2026-06-11時点で完了・稼働済み(詳細: `products/lien/scripts/g1/RUNBOOK.md`、issue #8/#38のJOURNAL記録)。G0(#38)の残項目(Apple Developer Program加入)はAPNs投入・実機G1計測・TestFlight提出に必要だが、デモ用の相手役を作ること自体の前提ではない。

**状態: 手順・スクリプトとも準備済み(2026-10-20)。** 残るのは提出日のコード発行と Notes への記入、実ビルドでのペア成立の確認。レビュー用の実データ投入は、コードを発行する時点(提出日)に行う。

### 2.6 UGC Guideline 1.2 適合性の総括

§1.4と内容重複するため要点のみ再掲:

| 要件 | 対応 | 状態 |
|---|---|---|
| 通報の仕組み | 長押し(写真・ニックネーム・約束の文・植物の名前)と Settings → サポート → 不適切な内容を通報する(mailto。ペア ID・日付・対象・版を入れる。自動では送らない) | **実装済み(T23 #23)**。規約(terms.md第6条)記載済み。宛先は G4 待ち |
| 不適切ユーザーの排除(block) | 長押しの「ブロック(ペアを解消)」と Settings → ペアを解消する(確認2段階)で共有を完全停止 | **実装済み(T23 #23)**。規約(terms.md第7条)記載済み |
| 利用規約への同意 | オンボのニックネーム画面で、規約・プライバシーポリシーへの同意のチェックが入るまで「同意してはじめる」を押せない(リンクと禁止事項の注意書きつき)。規約・ポリシーへのリンクは設定にもある | **実装済み(T23 #23)**。旧「未確認事項」(issue #30 の敵対検証の懸念)は解消。実ビルドでの確認は T30。**2026-10-20 にコードで確認済み**(§1.1) |
| コンテンツの連絡先情報公開 | 運営者連絡先(メール)は`terms.md`/`privacy-policy.md`に記載欄あり、現在プレースホルダ。アプリ側も `SupportLinks.contactEmail` が空(通報・お問い合わせのメールの宛先になる)。G4 で同じアドレスに揃える | **G4(#42)待ち** |

### 2.7 プライバシーマニフェスト(PrivacyInfo.xcprivacy)

T28準備(#28)で追加した3つのマニフェストを、提出前の最終確認として台帳化する。

| ターゲット | ファイル | 収集データ | 必須理由 API |
|---|---|---|---|
| Lien(本体) | `products/lien/ios/Lien/PrivacyInfo.xcprivacy` | Name / Photos or Videos / Other User Content / User ID / Device ID(すべて App Functionality・本人に紐づく・トラッキングなし) | `UserDefaults`(CA92.1: PushTokenSync の送信記録・PlantMemory の「もう見せたか」) / `FileTimestamp`(C617.1: supabase-swift 2.55.3 が `FileManager.attributesOfItem` を参照するため。アプリ自身はファイルのタイムスタンプを読まない) |
| 通知サービス拡張(LienNSE) | `products/lien/ios/LienNSE/PrivacyInfo.xcprivacy` | なし | なし(ペイロードを App Group のファイルへ書くだけ) |
| ウィジェット(LienWidget) | `products/lien/ios/LienWidget/PrivacyInfo.xcprivacy` | なし | なし(App Group の `pair_snapshot.json` を読むだけ) |

- `NSPrivacyTracking` は3つとも `false`、`NSPrivacyTrackingDomains` は空。
- 本体の5型は §2.1 の表と一致する。**`products/lien/scripts/ops/marketing_docs_static_test.ts` が、マニフェストの型が §2.1 の表にすべて載っていること・§2.1 の表に v1.0 で収集しないもの(SIWA の識別子・利用状況)の行が無いことを検査する**(2026-10-20 追加。CI の ops-tests で回る)。
- `ios/LienTests/PrivacyManifestTests` が Swift ソースを走査し、使っているのに宣言が無い必須理由 API を検出する。依存パッケージ分は `lien-release` の dry-run が archive の中身から棚卸しする(シンボルは宣言が無いと失敗する)。
- **v1.0.1 で Sign in with Apple を足すとき**: `users.apple_sub` を `User ID` として申告し、`NSPrivacyCollectedDataTypes` に追加する(既に `UserID` があるため、用途の追記で足りるかは Apple の質問票で確認)。`privacy-policy.md` §8 と §2.1 を同時に更新する。

**状態: 準備済み(2026-10-20 に §2.1 と一致を確認)。** 残るのは、提出時の App Store Connect の回答との最終突き合わせ(G4/G5)と、`lien-release` の dry-run での必須理由 API の棚卸し(CI で実施済み)。

---

## 3. 証跡(terms.md 監査結果 — issue #30 進め方手順2)

`products/lien/marketing/terms.md` を読み、§8③④の「規約記載」要件を満たすことを確認した(2026-10-12 初回、**2026-10-20 に再確認**。行番号は 2026-10-20 時点):

- 第6条(通報および運営者によるコンテンツの削除等): `products/lien/marketing/terms.md:46-51`
- 第7条(ブロックとペアの解消): `products/lien/marketing/terms.md:53-56`
- 第8条(アカウントの削除): `products/lien/marketing/terms.md:58-61`

いずれも条文としては記載済み。アプリ側の UI/API(T23)も 2026-10-13 に実装済み(§1.4・§1.5・§2.6)。**2026-10-20 の再確認でも、条文と実装の間に食い違いは無かった**(通報=第6条、ブロック=ペア解消=第7条、削除=第8条。プライバシーポリシー §6・§7・§9 も同趣旨)。

---

## 4. 人間判断が必要な項目(まとめ)

- **Support URL / Privacy Policy URL の公開先が未確定**: GitHub Pagesのどのパスで `privacy.html` / `terms.html` を公開するか(リポジトリ公開範囲含む)。`CHECKLIST-G4.md` 3節参照。G4(#42)で決定。**2026-10-20 時点では 404**(§2.4)。
- **事業者名・連絡先メールアドレス・制定日・管轄裁判所が未確定**: `terms.md` / `privacy-policy.md` の `【要記入: G4: ...】` 箇所。G4(#42)で決定。アプリ側の `SupportLinks.contactEmail` も同じ値にする。
- **年齢レーティング質問票の最終回答**: 草案は 4+(§2.2)。**「健康・ウェルネス」を「はい」にすると 9+** になるため、App Store Connect の質問票の説明を見て決める(G4/G5)。9+ にする場合は `terms.md` 第4条の「4+」も直す。
- **Export Compliance 質問票の正確な回答**: `ITSAppUsesNonExemptEncryption: false` は設定済み(§2.3)。Apple の最新の質問文言は提出時に確認する(要確認)。
- **提出日(10/27)の招待コード発行と Notes for Review への記入**: §1.3 の運用。コードは 72 時間で失効するため、リポジトリではなく App Store Connect に書く。失効時は `partner.sh new-invite` で再発行する(人間の操作)。
- ~~**利用状況計測手段(自前テーブル or TelemetryDeck)が未確定**~~ → **D6(2026-10-12)で確定**。v1.0 は分析 SDK も計測専用テーブルも入れず、アプリは計測のために何も送らない(REQUIREMENTS §7)。§2.1 と `privacy-policy.md` 第1条をその方針に直した(2026-10-20)。残るのは App Store Connect の「用途」の申告の確認だけ。
- ~~**Sign in with Apple の扱い**~~ → **D3 で v1.0.1 に移動済み**。v1.0 のプライバシーポリシー・App Privacy・マニフェストから SIWA の識別子を外した(2026-10-20)。v1.0.1 で追加するときに、§2.1・§2.7・ポリシー §8 を同時に更新する。
- ~~**オンボーディングでの利用規約同意UIの要否**~~ → 2026-10-13 に T23(#23)で実装した(§1.4・§2.6)。残るのは、実ビルドでの確認(T30)と、リンク先の公開(Pages・G4 — 上の「Support URL / Privacy Policy URL の公開先」)。
