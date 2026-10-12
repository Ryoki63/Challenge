// steps_after.ts — S17〜S21: 植物の名前・取消とやり直し・push 登録の経路(PushTokenSync)・書き込み権限の境界・DB の中身
//
// 手順の流れ・守ること・登場人物は scenario.ts。共有の型と道具は scenario_lib.ts。

import { Abort, redact } from "./report.ts";
import { jsonEqual } from "./shape.ts";
import {
  addDays,
  arr,
  brief,
  type Ctx,
  expectError,
  expectFields,
  fakePushToken,
  getSnapshot,
  type J,
  type Label,
  obj,
  partnerRowsQuery,
  UUID_RE,
  viaSignedUrl,
  type World,
} from "./scenario_lib.ts";

export async function stepsAfter(c: Ctx, w: World): Promise<void> {
  const { api, rep, fx, today } = c;
  const { users, labels, need, d } = w;

  // ------------------------------------------------------------------
  await rep.run(
    "S17",
    "植物の名前(plant-name: first は先着、rename は上書き)",
    async () => {
      const a = need("A");
      const b = need("B");
      const cu = users.C;
      const pn = (jwt: string, payload: { json?: unknown; raw?: string }) =>
        api.fn(jwt, "plant-name", "POST", payload);

      expectError(
        c,
        "A: 空の名前 → 400 invalid_name",
        await pn(a.jwt, { json: { name: "", mode: "first" } }),
        "plant-name",
        "invalid_name",
      );
      expectError(
        c,
        "A: 9 字の名前 → 400 invalid_name",
        await pn(a.jwt, {
          json: { name: "あいうえおかきくけ", mode: "first" },
        }),
        "plant-name",
        "invalid_name",
      );
      expectError(
        c,
        "A: ゼロ幅スペースだけの名前 → 400 invalid_name",
        await pn(a.jwt, { json: { name: "​​", mode: "first" } }),
        "plant-name",
        "invalid_name",
      );
      expectError(
        c,
        "A: 改行を含む名前 → 400 invalid_name",
        await pn(a.jwt, { json: { name: "あ\nい", mode: "first" } }),
        "plant-name",
        "invalid_name",
      );
      expectError(
        c,
        "A: 名前が文字列でない → 400 invalid_name",
        await pn(a.jwt, { json: { name: 5, mode: "first" } }),
        "plant-name",
        "invalid_name",
      );
      expectError(
        c,
        "A: mode が first / rename 以外 → 400 invalid_mode",
        await pn(a.jwt, { json: { name: "あお", mode: "x" } }),
        "plant-name",
        "invalid_mode",
      );
      expectError(
        c,
        "A: 壊れた JSON → 400 invalid_json",
        await pn(a.jwt, { raw: "{" }),
        "plant-name",
        "invalid_json",
      );
      if (cu) {
        expectError(
          c,
          "C(ペアなし): → 409 no_pair",
          await pn(cu.jwt, { json: { name: "あお", mode: "first" } }),
          "plant-name",
          "no_pair",
        );
      }

      const first = await pn(a.jwt, {
        json: { name: "テスト苗", mode: "first" },
      });
      rep.check(
        "A: first「テスト苗」→ 200",
        first.status === 200,
        brief(first),
      );
      rep.shape(
        "A: 応答の形が plant-name.ok.json と一致",
        first.json,
        fx.plantName,
      );
      rep.check(
        "A: name と snapshot.plantName が保存された名前",
        obj(first.json).name === "テスト苗" &&
          obj(obj(first.json).snapshot).plantName === "テスト苗",
        JSON.stringify(obj(first.json).name),
      );
      const lost = await pn(b.jwt, { json: { name: "あおい", mode: "first" } });
      rep.check(
        "B: first(先に A が付けた)→ 409 already_named・今の名前を返す",
        lost.status === 409 &&
          jsonEqual(lost.json, { error: "already_named", name: "テスト苗" }),
        brief(lost),
      );
      rep.shape(
        "B: 409 の応答の形が plant-name.already-named.json と一致",
        lost.json,
        fx.plantNameAlreadyNamed,
      );
      if (!fx.errors["plant-name"]?.already_named?.includes(409)) {
        rep.deviation(
          "plant-name の already_named が errors.json の 409 と食い違う",
        );
      }

      const ren = await pn(b.jwt, { json: { name: "あおい", mode: "rename" } });
      rep.check(
        "B: rename「あおい」→ 200",
        ren.status === 200 && obj(ren.json).name === "あおい",
        brief(ren),
      );
      rep.shape(
        "B: rename の応答の形が plant-name.ok.json と一致",
        ren.json,
        fx.plantName,
      );
      const same = await pn(b.jwt, {
        json: { name: "あおい", mode: "rename" },
      });
      rep.check(
        "B: 同じ名前への rename → 200(何も起きない)",
        same.status === 200 && obj(same.json).name === "あおい",
        brief(same),
      );
      const sa = await getSnapshot(c, a, "A");
      d.plantName = "あおい";
      expectFields(
        c,
        "A: GET /snapshot の plantName が「あおい」(相手の rename が見える)",
        sa,
        { plantName: "あおい" },
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S18",
    "チェックイン取消 → やり直し(checkin-cancel)",
    async () => {
      const a = need("A");
      const b = need("B");
      const cu = users.C;
      const photoPath = d.photoPath as string;

      const cancel = await api.fn(a.jwt, "checkin-cancel", "POST", {
        json: { dateLocal: today },
      });
      rep.check(
        "A: POST /checkin-cancel → 200",
        cancel.status === 200,
        brief(cancel),
      );
      rep.shape(
        "A: 応答の形が checkin-cancel.ok.json と一致",
        cancel.json,
        fx.checkinCancel,
      );
      rep.check(
        "A: alreadyCanceled = false",
        obj(cancel.json).alreadyCanceled === false,
        JSON.stringify(obj(cancel.json).alreadyCanceled),
      );
      expectFields(
        c,
        "A: 取消後の snapshot(成長は 1 → 0 に戻り、B だけ完了で fidget)",
        obj(cancel.json).snapshot,
        {
          todayMeDone: false,
          todayPartnerDone: true,
          plantGrownDays: 0,
          plantStage: 0,
          streakCurrent: 0,
          plantMood: "fidget",
        },
      );
      const sb = await getSnapshot(c, b, "B");
      expectFields(
        c,
        "B: 相手の取消が見える(todayPartnerDone = false・写真なし)",
        sb,
        {
          todayMeDone: true,
          todayPartnerDone: false,
          hasPartnerPhotoToday: false,
          plantGrownDays: 0,
          plantMood: "fidget",
        },
      );
      const gone = await api.rest(
        b.jwt,
        "GET",
        partnerRowsQuery(b.id, today),
      );
      rep.check(
        "B: A の行は消えた(PV の問い合わせが [] = partner-checkin.none.json)",
        gone.status === 200 &&
          jsonEqual(gone.json, fx.optional["partner-checkin.none.json"] ?? []),
        brief(gone),
      );

      const cancelAgain = await api.fn(a.jwt, "checkin-cancel", "POST", {
        json: { dateLocal: today },
      });
      rep.check(
        "A: もう一度 → 200・alreadyCanceled = true(冪等)",
        cancelAgain.status === 200 &&
          obj(cancelAgain.json).alreadyCanceled === true,
        brief(cancelAgain),
      );
      expectError(
        c,
        "A: 昨日の取消 → 400 date_local_not_today",
        await api.fn(a.jwt, "checkin-cancel", "POST", {
          json: { dateLocal: addDays(today, -1) },
        }),
        "checkin-cancel",
        "date_local_not_today",
      );
      expectError(
        c,
        "A: 日付でない取消 → 400 invalid_date_local",
        await api.fn(a.jwt, "checkin-cancel", "POST", {
          json: { dateLocal: "abc" },
        }),
        "checkin-cancel",
        "invalid_date_local",
      );

      // 観測: 取消しても、アップロード済みの写真の実体は Storage に残る(DESIGN §5.7-3・migration 0002 の想定)。
      // #59 はクライアントが署名付き URL を作る方式なので、相手は決定的なパスから取消後の写真も取れてしまう
      const after = await viaSignedUrl(c, b.jwt, photoPath);
      if (after.sign.status === 200 && after.get?.status === 200) {
        rep.note(
          "取消後も写真の実体は Storage に残り、相手(B)は決まったパスから署名付き URL を作って取れる",
          "DESIGN §5.2 の「署名付きURLで配布」の前提(Function が発行しない限り見えない)は、#59 の方式では成り立たない。通常のアプリの画面からは行が消えるので見えない(改造クライアントだけ)。取消時にサーバーが写真の実体も消す案は issue #68",
        );
      } else {
        rep.pass(
          "取消後は相手も署名付き URL を作れない(写真の実体は見えない)",
          brief(after.sign),
        );
      }

      // やり直し(誤タップ対応): 新しい行ができ、ふたり達成に戻る。写真は付いていない
      const redo = await api.fn(a.jwt, "checkin", "POST", {
        json: { dateLocal: today },
      });
      rep.check(
        "A: 取消のあと、もう一度チェックイン → 200・alreadyCheckedIn = false",
        redo.status === 200 && obj(redo.json).alreadyCheckedIn === false,
        brief(redo),
      );
      expectFields(
        c,
        "A: 「ふたり達成」に戻る(成長 1 回・段階 1・happy)",
        obj(redo.json).snapshot,
        {
          todayMeDone: true,
          todayPartnerDone: true,
          plantGrownDays: 1,
          plantStage: 1,
          plantMood: "happy",
        },
      );

      // やり直した行には写真が無い: PV の問い合わせは photo_path = null の 1 行(partner-checkin.no-photo.json)
      const noPhoto = await api.rest(
        b.jwt,
        "GET",
        partnerRowsQuery(b.id, today),
      );
      const noPhotoRow = obj(arr(noPhoto.json)[0]);
      rep.check(
        "B: 写真なしで取り直した行は photo_path = null(PV の問い合わせが 1 行)",
        noPhoto.status === 200 && arr(noPhoto.json).length === 1 &&
          UUID_RE.test(String(noPhotoRow.id)) && noPhotoRow.photo_path === null,
        brief(noPhoto),
      );
      if (fx.partnerCheckin) {
        rep.shape(
          "B: 行の形が partner-checkin.no-photo.json と一致(photo_path は null)",
          noPhoto.json,
          fx.partnerCheckin,
        );
      }

      // ソロの取消(C)
      if (cu) {
        const cc = await api.fn(cu.jwt, "checkin-cancel", "POST", {
          json: { dateLocal: today },
        });
        rep.check(
          "C(ソロ): checkin-cancel → 200・alreadyCanceled = false",
          cc.status === 200 && obj(cc.json).alreadyCanceled === false,
          brief(cc),
        );
        rep.shape(
          "C(ソロ): 応答の形が checkin-cancel.ok.json と一致",
          cc.json,
          fx.checkinCancel,
        );
        expectFields(c, "C(ソロ): 取消後の snapshot", obj(cc.json).snapshot, {
          pairId: null,
          todayMeDone: false,
        });
      }
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S19",
    "push 登録の経路(PushTokenSync): users.push_token / push_env の書き込みと読み戻し",
    async () => {
      const a = need("A");
      const b = need("B");
      const tokens: Partial<Record<Label, string>> = {};

      for (const u of [a, b]) {
        const sel = `users?id=eq.${u.id}&select=push_token,push_env`;
        // fetchPushRegistration: 登録前は両方 null
        const before = await api.rest(u.jwt, "GET", sel);
        rep.eq(
          `${u.label}: 登録前は push_token / push_env とも null(自分の行を読める)`,
          before.json,
          [{ push_token: null, push_env: null }],
        );

        // updatePushRegistration: push_token と push_env を同時に PATCH(supabase-swift の既定 = return=minimal)
        const tok = fakePushToken();
        tokens[u.label] = tok;
        const set = await api.rest(u.jwt, "PATCH", `users?id=eq.${u.id}`, {
          json: { push_token: tok, push_env: "sandbox" },
          prefer: "return=minimal",
        });
        rep.check(
          `${u.label}: PATCH users {push_token, push_env: sandbox} → 成功(204)`,
          set.status === 204 || set.status === 200,
          brief(set),
        );
        const after = await api.rest(u.jwt, "GET", sel);
        rep.eq(
          `${u.label}: 読み戻すと書いた値(fetchPushRegistration の結果)`,
          after.json,
          [{ push_token: tok, push_env: "sandbox" }],
        );

        // 環境の切り替え(TestFlight = production)
        const prod = await api.rest(u.jwt, "PATCH", `users?id=eq.${u.id}`, {
          json: { push_token: tok, push_env: "production" },
          prefer: "return=minimal",
        });
        rep.check(
          `${u.label}: push_env を production に更新 → 成功`,
          prod.status === 204 || prod.status === 200,
          brief(prod),
        );
        const after2 = await api.rest(u.jwt, "GET", sel);
        rep.eq(`${u.label}: 読み戻すと production`, after2.json, [{
          push_token: tok,
          push_env: "production",
        }]);

        // 不正な環境は DB の CHECK で断られ、値は変わらない
        const badEnv = await api.rest(u.jwt, "PATCH", `users?id=eq.${u.id}`, {
          json: { push_env: "staging" },
          prefer: "return=minimal",
        });
        rep.check(
          `${u.label}: push_env = staging は断られる(CHECK 制約 → 400)`,
          badEnv.status === 400,
          brief(badEnv),
          `HTTP ${badEnv.status}`,
        );
        const after3 = await api.rest(u.jwt, "GET", sel);
        rep.eq(`${u.label}: 断られたあとも production のまま`, after3.json, [{
          push_token: tok,
          push_env: "production",
        }]);
      }

      // 相手の登録は読めない・書けない(トークンの漏えい・上書きの防止)
      const peek = await api.rest(
        b.jwt,
        "GET",
        `users?id=eq.${a.id}&select=id,push_token,push_env`,
      );
      rep.eq("B: 相手(A)の users 行は読めない(0 件)", peek.json, []);
      const poke = await api.rest(b.jwt, "PATCH", `users?id=eq.${a.id}`, {
        json: { push_token: "overwritten" },
        prefer: "return=representation",
      });
      rep.check(
        "B: 相手(A)の push_token は書き換えられない(0 行)",
        (poke.status === 200 && arr(poke.json).length === 0) ||
          poke.status === 403,
        brief(poke),
        `HTTP ${poke.status} ${arr(poke.json).length} 行`,
      );
      const aAfter = await api.rest(
        a.jwt,
        "GET",
        `users?id=eq.${a.id}&select=push_token,push_env`,
      );
      rep.eq("A: 自分の登録は無事", aAfter.json, [{
        push_token: tokens.A,
        push_env: "production",
      }]);
      const cu = users.C;
      if (cu) {
        const cpeek = await api.rest(
          cu.jwt,
          "GET",
          `users?id=in.(${a.id},${b.id})&select=id`,
        );
        rep.eq("C(ペア外): A / B の users 行は読めない(0 件)", cpeek.json, []);
      }

      // push を送る操作(A の plant-name rename → B へサイレント push)をしても、本処理は成功する
      const trigger = await api.fn(a.jwt, "plant-name", "POST", {
        json: { name: "みどり", mode: "rename" },
      });
      rep.check(
        "A: B に push 登録がある状態で plant-name rename → 200(push の成否は本処理に影響しない)",
        trigger.status === 200 && obj(trigger.json).name === "みどり",
        brief(trigger),
      );
      d.plantName = "みどり";
      const bAfter = await api.rest(
        b.jwt,
        "GET",
        `users?id=eq.${b.id}&select=push_token,push_env`,
      );
      const row = obj(arr(bAfter.json)[0]);
      // APNs の 5 変数がそろっているか(名前だけ。値は見ない)。1 つでも欠ければ push は送られない(pusher.ts)
      let apns = "Function secrets の確認は省略(SUPABASE_ACCESS_TOKEN なし)";
      if (c.mgmt) {
        const names = await c.mgmt.functionSecretNames();
        const required = [
          "APNS_AUTH_KEY",
          "APNS_KEY_ID",
          "APPLE_TEAM_ID",
          "APNS_ENV",
          "APNS_TOPIC",
        ];
        const missing = required.filter((n) => !names.includes(n));
        apns = missing.length === 0
          ? "APNs の secrets は 5 変数ともある(push は有効)"
          : `APNs の secrets のうち未設定: ${
            missing.join(", ")
          }(push は無効 = 送信をスキップする)`;
      }
      if (row.push_token === tokens.B) {
        rep.note(
          "B の push_token は残った(サーバーは APNs に拒否されていない)",
          `${apns}。G0 で APNs が設定されると、偽のトークンは 400 BadDeviceToken で掃除される(DESIGN §4.1)ので、この観測は変わる`,
        );
      } else if (row.push_token === null) {
        rep.note(
          "B の push_token が null になった(APNs が無効なトークンとして拒否し、サーバーが掃除した)",
          `${apns}。DESIGN §4.1 の無効トークンの掃除が本番で動いた`,
        );
      } else {
        rep.fail("B の push_token が想定外の値になった", JSON.stringify(row));
      }

      // 後片付け: 偽のトークンを残さない(後で APNs が設定されたとき、close-day などが偽トークンへ送らないように)
      for (const u of [a, b]) {
        const clr = await api.rest(u.jwt, "PATCH", `users?id=eq.${u.id}`, {
          json: { push_token: null, push_env: null },
          prefer: "return=minimal",
        });
        const chk = await api.rest(
          u.jwt,
          "GET",
          `users?id=eq.${u.id}&select=push_token,push_env`,
        );
        rep.check(
          `${u.label}: 偽の push 登録を消した(null に戻せる)`,
          (clr.status === 204 || clr.status === 200) &&
            jsonEqual(chk.json, [{ push_token: null, push_env: null }]),
          brief(clr),
        );
      }
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S20",
    "クライアントの書き込み権限の境界(認可されていない書き込みは通らない)",
    async () => {
      const b = need("B");
      const photoPath = d.photoPath as string;

      const prem = await api.rest(b.jwt, "PATCH", `users?id=eq.${b.id}`, {
        json: { premium_until: "2099-01-01T00:00:00Z" },
        prefer: "return=minimal",
      });
      const premAfter = await api.rest(
        b.jwt,
        "GET",
        `users?id=eq.${b.id}&select=premium_until`,
      );
      rep.check(
        "B: premium_until は自分の行でも書けない(列の GRANT)・値は null のまま",
        prem.status >= 400 &&
          jsonEqual(premAfter.json, [{ premium_until: null }]),
        `PATCH ${brief(prem)} / 読み戻し ${redact(premAfter.text)}`,
        `PATCH → HTTP ${prem.status}`,
      );

      const ins = await api.rest(b.jwt, "POST", "checkins", {
        json: {
          user_id: b.id,
          promise_id: "00000000-0000-4000-8000-000000000000",
          date_local: addDays(today, -1),
        },
        prefer: "return=minimal",
      });
      rep.check(
        "B: checkins へ直接 INSERT できない(書き込みは Function 経由)",
        ins.status === 401 || ins.status === 403,
        brief(ins),
        `HTTP ${ins.status}`,
      );

      const del = await api.rest(
        b.jwt,
        "DELETE",
        `checkins?user_id=eq.${b.id}`,
        { prefer: "return=representation" },
      );
      const delAfter = await api.rest(
        b.jwt,
        "GET",
        `checkins?select=id&user_id=eq.${b.id}&date_local=eq.${today}`,
      );
      rep.check(
        "B: 自分の checkins も直接 DELETE できない(取消は checkin-cancel 経由)・行は残る",
        (del.status === 401 || del.status === 403) &&
          arr(delAfter.json).length === 1,
        `DELETE ${brief(del)} / 残り ${arr(delAfter.json).length} 行`,
        `DELETE → HTTP ${del.status}`,
      );

      const plant = await api.rest(
        b.jwt,
        "PATCH",
        `plants?pair_id=eq.${d.pairId}`,
        {
          json: { name: "hack" },
          prefer: "return=representation",
        },
      );
      rep.check(
        "B: plants を直接 PATCH できない(名前は plant-name 経由)",
        plant.status === 401 || plant.status === 403,
        brief(plant),
        `HTTP ${plant.status}`,
      );

      // 写真の削除はクライアントに許されない(delete ポリシーなし)。試したあとも署名付き URL で取れる
      const rm = await api.storageRemove(b.jwt, [photoPath]);
      const still = await viaSignedUrl(c, b.jwt, photoPath);
      rep.check(
        "B: Storage の写真を JWT で削除しても消えない(delete は許可されていない)",
        still.sign.status === 200 && still.get?.status === 200,
        `HTTP ${still.sign.status}/${still.get?.status}`,
        `DELETE → HTTP ${rm.status} ${redact(rm.text).slice(0, 60)}`,
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S21",
    "DB の中身(Management API で SELECT。通した API の結果が DB に残っているか)",
    async () => {
      if (!c.options.dbChecks || !c.mgmt) {
        rep.skip(
          "DB の確認",
          c.options.dbChecks
            ? "SUPABASE_ACCESS_TOKEN が無い"
            : "--no-db-checks",
        );
        return;
      }
      const ids = labels.map((l) => need(l).id);
      const idArr = `array[${ids.map((i) => `'${i}'`).join(",")}]::uuid[]`;
      const pid = d.pairId as string;
      if (!UUID_RE.test(pid)) throw new Abort("pairId が UUID でない");
      const rows = await c.mgmt.sql<J>(`
      select
        (select status from public.pairs where id = '${pid}') as pair_status,
        (select started_on::text from public.pairs where id = '${pid}') as started_on,
        (select ticket_balance from public.pairs where id = '${pid}') as ticket_balance,
        (select count(*) from public.pair_members where pair_id = '${pid}') as members,
        (select count(*) from public.ticket_ledger where pair_id = '${pid}' and reason = 'monthly' and delta = 2) as initial_grants,
        (select count(*) from public.ticket_grant_runs where pair_id = '${pid}') as grant_runs,
        (select count(*) from public.streak_days where pair_id = '${pid}') as streak_days,
        (select species from public.plants where pair_id = '${pid}') as species,
        (select name from public.plants where pair_id = '${pid}') as plant_name,
        (select grown_days from public.plants where pair_id = '${pid}') as grown_days,
        (select stage from public.plants where pair_id = '${pid}') as stage,
        (select count(*) from public.nudges where pair_id = '${pid}') as nudges,
        (select count(*) from public.checkins where user_id = any(${idArr})) as checkins,
        (select count(*) from public.reactions where from_user = any(${idArr})) as reactions,
        (select count(*) from public.invites where from_user = any(${idArr}) and used_at is not null) as invites_used,
        (select count(*) from public.promises where user_id = any(${idArr}) and archived_at is null) as promises,
        (select count(*) from storage.objects where bucket_id = 'photos' and name like 'pairs/${pid}/%') as photo_objects,
        (select count(*) from auth.users where id = any(${idArr}) and is_anonymous) as anon_users
    `);
      const r = rows[0] ?? {};
      const n = (k: string) => Number(r[k]);
      rep.check(
        "ペアは active・started_on = 今日・メンバー 2 人",
        r.pair_status === "active" && r.started_on === today &&
          n("members") === 2,
        JSON.stringify(r),
      );
      rep.check(
        "初期のお休みチケット: 残数 2・ledger に monthly +2 が 1 行・月次付与の実行記録なし(grant-tickets は呼んでいない)",
        n("ticket_balance") === 2 && n("initial_grants") === 1 &&
          n("grant_runs") === 0,
        `balance=${r.ticket_balance} grants=${r.initial_grants} runs=${r.grant_runs}`,
      );
      rep.check(
        "close-day は走っていない: streak_days 0 行・plants.grown_days = 0・stage = 0(stage は書かない設計)",
        n("streak_days") === 0 && n("grown_days") === 0 && n("stage") === 0,
        `streak=${r.streak_days} grown=${r.grown_days} stage=${r.stage}`,
      );
      rep.check(
        `植物: species = basic・名前 = 最後に付けた「${d.plantName}」(B の直接 PATCH は効いていない)`,
        r.species === "basic" && r.plant_name === d.plantName,
        `species=${r.species} name=${r.plant_name}`,
      );
      rep.check(
        "nudges 3 行(4 回目は 429 で記録されない)",
        n("nudges") === 3,
        `nudges=${r.nudges}`,
      );
      rep.check(
        "checkins は A(やり直し)と B の 2 行(C のソロは取消済み・A の最初の行は取消で消えた)",
        n("checkins") === 2,
        `checkins=${r.checkins}`,
      );
      rep.check(
        "reactions は 0 行(リアクション先のチェックインを A が取り消したので、外部キーの CASCADE で消えた)",
        n("reactions") === 0,
        `reactions=${r.reactions}`,
      );
      rep.check(
        "招待は使用済み 1 件・現役の約束は人数分",
        n("invites_used") === 1 && n("promises") === ids.length,
        `invites=${r.invites_used} promises=${r.promises}`,
      );
      rep.check(
        "Storage: photos に A の原寸とサムネの 2 オブジェクト(取消後も残る = S18 の NOTE)",
        n("photo_objects") === 2,
        `objects=${r.photo_objects}`,
      );
      rep.check(
        "作ったユーザーはすべて匿名ユーザー",
        n("anon_users") === ids.length,
        `anon=${r.anon_users}`,
      );
    },
  );
}
