// steps_setup.ts — S01〜S08: ユーザー作成からペア成立まで(匿名ユーザー・エラーの基本形・プロフィール・snapshot・約束・ソロの確認・招待)
//
// 手順の流れ・守ること・登場人物は scenario.ts。共有の型と道具は scenario_lib.ts。

import { decodeJwtPayload } from "./client.ts";
import { Abort } from "./report.ts";
import {
  addDays,
  arr,
  brief,
  type Ctx,
  expectError,
  expectFields,
  INVITE_TOKEN_RE,
  ISO_RE,
  obj,
  PROMISES,
  UUID_RE,
  type World,
} from "./scenario_lib.ts";

export async function stepsSetup(c: Ctx, w: World): Promise<void> {
  const { api, rep, fx, today } = c;
  const { users, labels, need, d } = w;

  // ------------------------------------------------------------------
  await rep.run(
    "S01",
    "匿名ユーザーを作る(A=招待する側 / B=受ける側 / C=ペア外)",
    async () => {
      for (const label of labels) {
        const r = await api.signup();
        if (
          !rep.check(
            `${label}: POST /auth/v1/signup → 200`,
            r.status === 200,
            brief(r),
          )
        ) {
          throw new Abort(
            "匿名サインアップに失敗(Anonymous sign-ins の無効・レート制限(1時間30回)・プロジェクト停止のいずれか)",
          );
        }
        const j = obj(r.json);
        const user = obj(j.user);
        const jwt = String(j.access_token ?? "");
        const id = String(user.id ?? "");
        const payload = decodeJwtPayload(jwt);
        rep.check(
          `${label}: user.id が UUID で is_anonymous = true`,
          UUID_RE.test(id) && user.is_anonymous === true,
          `id=${id} is_anonymous=${user.is_anonymous}`,
        );
        rep.check(
          `${label}: JWT の role = authenticated・sub = user.id・is_anonymous = true`,
          payload?.role === "authenticated" && payload?.sub === id &&
            payload?.is_anonymous === true,
          `role=${payload?.role} anon=${payload?.is_anonymous}`,
        );
        rep.check(
          `${label}: refresh_token あり・expires_in ≒ 3600 秒`,
          typeof j.refresh_token === "string" && j.refresh_token !== "" &&
            typeof j.expires_in === "number" && j.expires_in >= 3000 &&
            j.expires_in <= 3700,
          `expires_in=${j.expires_in}`,
        );
        if (!UUID_RE.test(id) || jwt === "") {
          throw new Abort(
            "サインアップの応答にユーザー ID / access_token が無い",
          );
        }
        users[label] = {
          label,
          id,
          jwt,
          refresh: String(j.refresh_token ?? ""),
          nickname: `E2E-${label}`,
          promise: { ...PROMISES[label] },
        };
        await c.state.addUser(label, id);
      }
      // セッションの更新(アプリは匿名ユーザーを同じ ID のまま使い続ける。再インストールでしか作り直さない)
      const first = need("A");
      const rf = await api.refresh(first.refresh);
      const rfj = obj(rf.json);
      const rfPayload = decodeJwtPayload(String(rfj.access_token ?? ""));
      rep.check(
        "A: refresh_token で access_token を更新できる(同じユーザー ID・匿名のまま)",
        rf.status === 200 && rfPayload?.sub === first.id &&
          rfPayload?.is_anonymous === true &&
          obj(rfj.user).id === first.id,
        brief(rf),
      );
      if (rf.status === 200 && typeof rfj.access_token === "string") {
        const viaNew = await api.fn(
          String(rfj.access_token),
          "snapshot",
          "GET",
        );
        rep.check(
          "A: 更新した access_token で GET /snapshot → 200",
          viaNew.status === 200,
          brief(viaNew),
        );
      }
      // handle_new_user トリガーが users の骨組み行を作る(クライアントは INSERT しない)
      for (const label of labels) {
        const u = need(label);
        const r = await api.rest(
          u.jwt,
          "GET",
          `users?id=eq.${u.id}&select=id,nickname,avatar_emoji,timezone,remind_at,push_token,push_env,premium_until`,
        );
        const row = obj(arr(r.json)[0]);
        rep.check(
          `${label}: トリガーが users の骨組み行を作った(nickname 空・Asia/Tokyo・20:00・push 登録なし・premium なし)`,
          r.status === 200 && arr(r.json).length === 1 && row.id === u.id &&
            row.nickname === "" && row.timezone === "Asia/Tokyo" &&
            row.remind_at === "20:00:00" && row.push_token === null &&
            row.push_env === null && row.premium_until === null,
          brief(r),
        );
      }
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S02",
    "エラー応答の基本形(認証なし・メソッド違い・壊れた JSON)",
    async () => {
      const a = need("A");
      expectError(
        c,
        "認証なしの GET /snapshot → 401 unauthorized",
        await api.fn(null, "snapshot", "GET"),
        "snapshot",
        "unauthorized",
      );
      expectError(
        c,
        "JWT でない Bearer の GET /snapshot → 401 unauthorized",
        await api.fn("not-a-jwt", "snapshot", "GET"),
        "snapshot",
        "unauthorized",
      );
      expectError(
        c,
        "GET /checkin → 405 method_not_allowed",
        await api.fn(a.jwt, "checkin", "GET"),
        "checkin",
        "method_not_allowed",
      );
      expectError(
        c,
        "壊れた JSON の POST /checkin → 400 invalid_json",
        await api.fn(a.jwt, "checkin", "POST", { raw: "{not json" }),
        "checkin",
        "invalid_json",
      );
      expectError(
        c,
        "本文が null の POST /checkin → 400 invalid_json",
        await api.fn(a.jwt, "checkin", "POST", { raw: "null" }),
        "checkin",
        "invalid_json",
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S03",
    "プロフィール(users の PATCH。アプリの updateProfile と同じ本文)",
    async () => {
      for (const label of labels) {
        const u = need(label);
        const r = await api.rest(u.jwt, "PATCH", `users?id=eq.${u.id}`, {
          json: {
            nickname: u.nickname,
            avatar_emoji: "🧪",
            timezone: "Asia/Tokyo",
          },
          prefer: "return=representation",
        });
        const row = obj(arr(r.json)[0]);
        rep.check(
          `${label}: nickname / avatar_emoji / timezone を更新できる(自分の行・1 行)`,
          r.status === 200 && arr(r.json).length === 1 &&
            row.nickname === u.nickname && row.avatar_emoji === "🧪" &&
            row.timezone === "Asia/Tokyo",
          brief(r),
        );
      }
    },
  );

  // ------------------------------------------------------------------
  await rep.run("S04", "snapshot(約束もペアも無い新規ユーザー)", async () => {
    const a = need("A");
    const r = await api.fn(a.jwt, "snapshot", "GET");
    rep.check("A: GET /snapshot → 200", r.status === 200, brief(r));
    rep.shape("A: 応答の形が契約フィクスチャと一致", r.json, fx.snapshotGet);
    rep.values(
      "A: 値が snapshot.empty.json と一致(updatedAt 以外)",
      r.json,
      fx.raw["snapshot.empty.json"],
      ["$.snapshot.updatedAt"],
    );
    const snap = obj(obj(r.json).snapshot);
    const t = Date.parse(String(snap.updatedAt));
    rep.check(
      "A: updatedAt が ISO 8601 で、サーバー時刻が手元の時計と 5 分以内",
      ISO_RE.test(String(snap.updatedAt)) &&
        Math.abs(Date.now() - t) < 5 * 60_000,
      `updatedAt=${snap.updatedAt}`,
    );
  });

  // ------------------------------------------------------------------
  await rep.run("S05", "約束(promise-set)", async () => {
    const a = need("A");
    const b = need("B");
    // 約束が無いうちのチェックインは 409 no_promise(副作用なし)
    expectError(
      c,
      "B: 約束の前の POST /checkin → 409 no_promise",
      await api.fn(b.jwt, "checkin", "POST", { json: { dateLocal: today } }),
      "checkin",
      "no_promise",
    );

    for (const label of labels) {
      const u = need(label);
      const r = await api.fn(u.jwt, "promise-set", "POST", {
        json: {
          title: u.promise.title,
          emoji: u.promise.emoji,
          remindAt: "20:00",
        },
      });
      rep.check(
        `${label}: POST /promise-set → 200`,
        r.status === 200,
        brief(r),
      );
      rep.shape(
        `${label}: 応答の形が promise-set.ok.json と一致`,
        r.json,
        fx.promiseSet,
      );
      const p = obj(obj(r.json).promise);
      rep.check(
        `${label}: created = true・id は UUID・title / emoji / remindAt が送ったとおり`,
        obj(r.json).created === true && UUID_RE.test(String(p.id)) &&
          p.title === u.promise.title && p.emoji === u.promise.emoji &&
          p.remindAt === "20:00",
        JSON.stringify(r.json),
      );
      u.promiseId = String(p.id);
    }

    // 編集 = 同じ promise_id への UPDATE(created: false)。remindAt は null にできる
    const firstId = a.promiseId;
    a.promise = { title: "E2E 散歩(更新)", emoji: "🚶" };
    const edit = await api.fn(a.jwt, "promise-set", "POST", {
      json: { title: a.promise.title, emoji: a.promise.emoji, remindAt: null },
    });
    rep.check("A: 約束の編集 → 200", edit.status === 200, brief(edit));
    rep.shape(
      "A: 編集の応答の形(remindAt は null も可)",
      edit.json,
      fx.promiseSet,
      ["$.promise.remindAt"],
    );
    rep.check(
      "A: 編集は同じ promise_id への UPDATE(created = false・id 不変・remindAt = null)",
      obj(edit.json).created === false &&
        obj(obj(edit.json).promise).id === firstId &&
        obj(obj(edit.json).promise).remindAt === null &&
        obj(obj(edit.json).promise).title === a.promise.title,
      JSON.stringify(edit.json),
    );

    // 不正な入力は 400(DB を変えない)
    const bad = async (
      name: string,
      payload: { json?: unknown; raw?: string },
      code: string,
    ) =>
      expectError(
        c,
        name,
        await api.fn(a.jwt, "promise-set", "POST", payload),
        "promise-set",
        code,
      );
    await bad("A: title が空 → 400 invalid_title", {
      json: { title: "", emoji: "🚶" },
    }, "invalid_title");
    await bad("A: title が 21 字 → 400 invalid_title", {
      json: { title: "あ".repeat(21), emoji: "🚶" },
    }, "invalid_title");
    await bad("A: emoji が空 → 400 invalid_emoji", {
      json: { title: "E2E", emoji: "" },
    }, "invalid_emoji");
    await bad("A: remindAt が 25:00 → 400 invalid_remind_at", {
      json: { title: "E2E", emoji: "🚶", remindAt: "25:00" },
    }, "invalid_remind_at");
    await bad(
      "A: 壊れた JSON → 400 invalid_json",
      { raw: "{" },
      "invalid_json",
    );
  });

  // ------------------------------------------------------------------
  await rep.run("S06", "snapshot(約束あり・ペアなし = ソロ)", async () => {
    const a = need("A");
    const r = await api.fn(a.jwt, "snapshot", "GET");
    rep.check("A: GET /snapshot → 200", r.status === 200, brief(r));
    rep.shape("A: 応答の形が契約フィクスチャと一致", r.json, fx.snapshotGet);
    rep.values(
      "A: 値が snapshot.solo.json と一致(updatedAt・約束の文言以外)",
      r.json,
      fx.raw["snapshot.solo.json"],
      [
        "$.snapshot.updatedAt",
        "$.snapshot.myPromiseTitle",
        "$.snapshot.myPromiseEmoji",
      ],
    );
    expectFields(c, "A: 自分の約束が編集後の文言", obj(obj(r.json).snapshot), {
      myPromiseTitle: a.promise.title,
      myPromiseEmoji: a.promise.emoji,
    });
  });

  // ------------------------------------------------------------------
  await rep.run(
    "S07",
    "ソロの確認(ペア前のチェックイン・日付・入力の検査)",
    async () => {
      const a = need("A");
      // A はまだペアではない: 写真の置き場所(ペア)が無い
      expectError(
        c,
        "A(ソロ): requestPhotoUpload → 400 no_pair",
        await api.fn(a.jwt, "checkin", "POST", {
          json: { dateLocal: today, requestPhotoUpload: true },
        }),
        "checkin",
        "no_pair",
      );
      expectError(
        c,
        "A(ソロ): photoPath 付き → 400 invalid_photo_path",
        await api.fn(a.jwt, "checkin", "POST", {
          json: { dateLocal: today, photoPath: "pairs/x/y/z/photo.jpg" },
        }),
        "checkin",
        "invalid_photo_path",
      );
      // 日付・型の検査(副作用なし)
      expectError(
        c,
        "A: 3 日先の dateLocal → 400 date_local_out_of_range",
        await api.fn(a.jwt, "checkin", "POST", {
          json: { dateLocal: addDays(today, 3) },
        }),
        "checkin",
        "date_local_out_of_range",
      );
      expectError(
        c,
        "A: 3 日前の dateLocal → 400 date_local_out_of_range",
        await api.fn(a.jwt, "checkin", "POST", {
          json: { dateLocal: addDays(today, -3) },
        }),
        "checkin",
        "date_local_out_of_range",
      );
      expectError(
        c,
        "A: dateLocal が日付でない → 400 invalid_date_local",
        await api.fn(a.jwt, "checkin", "POST", { json: { dateLocal: "abc" } }),
        "checkin",
        "invalid_date_local",
      );
      expectError(
        c,
        "A: dateLocal が数値 → 400 invalid_date_local",
        await api.fn(a.jwt, "checkin", "POST", { json: { dateLocal: 123 } }),
        "checkin",
        "invalid_date_local",
      );
      expectError(
        c,
        "A: requestPhotoUpload が真偽値でない → 400 invalid_request_photo_upload",
        await api.fn(a.jwt, "checkin", "POST", {
          json: { dateLocal: today, requestPhotoUpload: "yes" },
        }),
        "checkin",
        "invalid_request_photo_upload",
      );

      const cu = users.C;
      if (!cu) {
        rep.skip("C: ソロのチェックイン", "--no-outsider のため省略");
        return;
      }
      const pr = await api.fn(cu.jwt, "promise-set", "POST", {
        json: {
          title: cu.promise.title,
          emoji: cu.promise.emoji,
          remindAt: "20:00",
        },
      });
      rep.check("C: 約束を設定 → 200", pr.status === 200, brief(pr));
      const r = await api.fn(cu.jwt, "checkin", "POST", {
        json: { dateLocal: today },
      });
      rep.check("C(ソロ): POST /checkin → 200", r.status === 200, brief(r));
      rep.shape(
        "C(ソロ): 応答の形が契約フィクスチャと一致",
        r.json,
        fx.checkin,
      );
      rep.values(
        "C(ソロ): 値が checkin.solo.json と一致(updatedAt・約束の文言以外)",
        r.json,
        fx.raw["checkin.solo.json"],
        [
          "$.snapshot.updatedAt",
          "$.snapshot.myPromiseTitle",
          "$.snapshot.myPromiseEmoji",
        ],
      );
      const again = await api.fn(cu.jwt, "checkin", "POST", {
        json: { dateLocal: today },
      });
      rep.check(
        "C(ソロ): 同じ日にもう一度 → 200・alreadyCheckedIn = true(冪等)",
        again.status === 200 && obj(again.json).alreadyCheckedIn === true,
        brief(again),
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S08",
    "招待 → ペア成立(invite-create / invite-accept)",
    async () => {
      const a = need("A");
      const b = need("B");
      const created = await api.fn(a.jwt, "invite-create", "POST");
      if (
        !rep.check(
          "A: POST /invite-create → 200",
          created.status === 200,
          brief(created),
        )
      ) {
        throw new Abort("招待を作れない");
      }
      rep.shape(
        "A: 応答の形が invite-create.ok.json と一致",
        created.json,
        fx.inviteCreate,
      );
      const inv = obj(created.json);
      const token = String(inv.token);
      const webBase =
        String(obj(fx.raw["invite-create.ok.json"]).webUrl).split("?")[0];
      rep.check(
        "A: token は 8 文字英数(0/O/1/l なし)・appUrl = lien://invite/<token>・webUrl はフィクスチャと同じページ",
        INVITE_TOKEN_RE.test(token) &&
          inv.appUrl === `lien://invite/${token}` &&
          inv.webUrl === `${webBase}?t=${token}`,
        JSON.stringify(inv),
      );
      const ttlMin = (Date.parse(String(inv.expiresAt)) - Date.now()) / 60_000;
      rep.check(
        "A: expiresAt が発行の約 72 時間後(ISO 8601)",
        ISO_RE.test(String(inv.expiresAt)) && Math.abs(ttlMin - 72 * 60) < 15,
        `expiresAt=${inv.expiresAt}`,
      );

      // 受諾の失敗系(いずれもペアを作らない)
      const acc = (jwt: string, payload: { json?: unknown; raw?: string }) =>
        api.fn(jwt, "invite-accept", "POST", payload);
      expectError(
        c,
        "B: 形式が違う token → 400 invalid_token",
        await acc(b.jwt, { json: { token: "abc" } }),
        "invite-accept",
        "invalid_token",
      );
      expectError(
        c,
        "B: token が文字列でない → 400 invalid_token",
        await acc(b.jwt, { json: { token: 123 } }),
        "invite-accept",
        "invalid_token",
      );
      expectError(
        c,
        "B: 存在しない token → 404 invite_not_found",
        await acc(b.jwt, { json: { token: "ZZZZzzzz" } }),
        "invite-accept",
        "invite_not_found",
      );
      expectError(
        c,
        "B: 壊れた JSON → 400 invalid_json",
        await acc(b.jwt, { raw: "[" }),
        "invite-accept",
        "invalid_json",
      );
      expectError(
        c,
        "A: 自分の招待は受けられない → 400 cannot_accept_own_invite",
        await acc(a.jwt, { json: { token } }),
        "invite-accept",
        "cannot_accept_own_invite",
      );

      const r = await acc(b.jwt, { json: { token } });
      if (
        !rep.check("B: POST /invite-accept → 200", r.status === 200, brief(r))
      ) {
        throw new Abort("ペアを作れない(以降の手順は意味を持たない)");
      }
      rep.shape(
        "B: 応答の形が invite-accept.ok.json と一致",
        r.json,
        fx.inviteAccept,
      );
      const j = obj(r.json);
      const snap = obj(j.snapshot);
      d.pairId = String(j.pairId);
      await c.state.setPair(d.pairId);
      rep.check(
        "B: pairId が UUID で、snapshot.pairId と同じ",
        UUID_RE.test(d.pairId) && snap.pairId === d.pairId,
        `pairId=${j.pairId} snapshot.pairId=${snap.pairId}`,
      );
      rep.values(
        "B: 成立直後の値が invite-accept.ok.json と一致(ID・時刻・名前・約束の文言以外)",
        r.json,
        fx.raw["invite-accept.ok.json"],
        [
          "$.pairId",
          "$.snapshot.pairId",
          "$.snapshot.updatedAt",
          "$.snapshot.partnerName",
          "$.snapshot.myPromiseTitle",
          "$.snapshot.myPromiseEmoji",
          "$.snapshot.partnerPromiseTitle",
          "$.snapshot.partnerPromiseEmoji",
        ],
      );
      expectFields(c, "B: 相手(A)の名前と約束が見える", snap, {
        partnerName: a.nickname,
        partnerPromiseTitle: a.promise.title,
        partnerPromiseEmoji: a.promise.emoji,
        myPromiseTitle: b.promise.title,
        myPromiseEmoji: b.promise.emoji,
      });

      // 1 回限り・1 ユーザー 1 ペア
      expectError(
        c,
        "B: 同じ招待をもう一度 → 410 invite_already_used",
        await acc(b.jwt, { json: { token } }),
        "invite-accept",
        "invite_already_used",
      );
      const cu = users.C;
      if (cu) {
        expectError(
          c,
          "C: 使用済みの招待 → 410 invite_already_used(ペア外は参加できない)",
          await acc(cu.jwt, { json: { token } }),
          "invite-accept",
          "invite_already_used",
        );
      }
      expectError(
        c,
        "A: ペア成立後の invite-create → 409 already_paired",
        await api.fn(a.jwt, "invite-create", "POST"),
        "invite-create",
        "already_paired",
      );
      expectError(
        c,
        "B: ペア成立後の invite-create → 409 already_paired",
        await api.fn(b.jwt, "invite-create", "POST"),
        "invite-create",
        "already_paired",
      );
    },
  );
}
