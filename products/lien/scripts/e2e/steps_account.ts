// steps_account.ts — S23〜S26: ペアの解消(pair-dissolve)・組み直し・アカウントの削除(delete-account)
//
// T23 #23(審査対応一式。App Store ガイドライン 1.2 の「ブロック = ペア解消」と 5.1.1(v) の「アプリ内からのアカウント削除」)の
// 本番での通し確認。S01〜S22 が作った A–B ペアを使い、最後に**テストユーザー自身を delete-account で消す**
// (後片付けの予行ではなく、アカウント削除そのものの確認)。
//
//   S23 pair-dissolve  A が解消 → 冪等(A の再送・B からの解消も dissolved:false)・B 視点のソロ・解消後は相手の写真(署名付き URL)・
//                      チェックイン・約束が読めない・自分の履歴は残る・行は消えずアーカイブとして残る
//   S24 組み直し       A が新しく招待 → B が受諾。新しいペアの植物・ストリークは 0 から(解消したペアの記録は復活しない)
//   S25 delete-account A(現役のペアあり)。ペアの解消 → 写真 → 所属 → auth ユーザーの順。A の JWT は 401・認証サーバーも
//                      「ユーザーが居ない」(アプリの GoTrueSessionVerifier が .rejected と見る応答)・B は無傷でソロ・A の分が DB と Storage から消える
//   S26 delete-account B = 最後の所属者(誰も残らないペアの行・植物・台帳が連鎖して消える)と、ペア外の C(ソロ)
//
// 手順の流れ・守ること・登場人物は scenario.ts。共有の型と道具は scenario_lib.ts。
// 終わると A / B / C は存在しない(--cleanup の後片付けは「記録にあるが、もう DB に無い」として扱う — cleanup.ts)。
// 途中で失敗したときは、残ったユーザー・ペア・写真を cleanup が消す(状態ファイルのペアと、残ったメンバーが属するペア)。

import { Abort } from "./report.ts";
import {
  arr,
  brief,
  type Ctx,
  expectError,
  expectFields,
  getSnapshot,
  type J,
  obj,
  partnerRowsQuery,
  SIGN_FAILURE_STATUS,
  UUID_RE,
  viaSignedUrl,
  type World,
} from "./scenario_lib.ts";

/** SQL に入れる UUID を検査して返す(想定外の文字列を SQL に入れない) */
function uuid(value: string, what: string): string {
  if (!UUID_RE.test(value)) throw new Abort(`${what} が UUID でない`);
  return value;
}

export async function stepsAccount(c: Ctx, w: World): Promise<void> {
  const { api, rep, fx, today } = c;
  const { users, labels, need, d } = w;
  const dbOn = c.options.dbChecks && c.mgmt !== null;

  // ------------------------------------------------------------------
  await rep.run(
    "S23",
    "ペアの解消(pair-dissolve。ブロック = ペア解消。冪等・解消後の閲覧境界)",
    async () => {
      const a = need("A");
      const b = need("B");
      const pid = uuid(d.pairId ?? "", "pairId");
      const photoPath = d.photoPath;
      if (!photoPath) throw new Abort("A の写真のパスが無い(S10 の失敗)");
      const dissolve = (jwt: string | null) =>
        api.fn(jwt, "pair-dissolve", "POST");

      expectError(
        c,
        "未ログイン: POST /pair-dissolve → 401 unauthorized",
        await dissolve(null),
        "pair-dissolve",
        "unauthorized",
      );
      expectError(
        c,
        "A: GET /pair-dissolve → 405 method_not_allowed(POST だけ)",
        await api.fn(a.jwt, "pair-dissolve", "GET"),
        "pair-dissolve",
        "method_not_allowed",
      );

      // 対照: 解消の前は、相手 B が A の写真の署名付き URL を作れて取れる(S12)。解消後の「読めない」が意味を持つ
      const before = await viaSignedUrl(c, b.jwt, photoPath);
      rep.check(
        "解消の前(対照): B は A の写真の署名付き URL を作れて、取れる",
        before.sign.status === 200 && before.get?.status === 200,
        `HTTP ${before.sign.status}/${before.get?.status}`,
      );
      const aBefore = await getSnapshot(c, a, "A(解消の前)");

      // 解消
      const r = await dissolve(a.jwt);
      if (
        !rep.check("A: POST /pair-dissolve → 200", r.status === 200, brief(r))
      ) {
        throw new Abort("ペアを解消できない(以降の手順は意味を持たない)");
      }
      rep.shape(
        "A: 応答の形が pair-dissolve.ok.json と一致",
        r.json,
        fx.pairDissolve,
      );
      const snap = obj(obj(r.json).snapshot);
      expectFields(c, "A: 解消した(dissolved = true)", r.json, {
        dissolved: true,
      });
      expectFields(
        c,
        "A: 解消後のソロの形(ペア・相手・ストリーク・植物の名前は無くなり、自分の約束と今日の完了は残る)",
        snap,
        {
          pairId: null,
          partnerName: null,
          partnerPromiseTitle: null,
          partnerPromiseEmoji: null,
          streakCurrent: 0,
          plantName: null,
          myPromiseTitle: a.promise.title,
          myPromiseEmoji: a.promise.emoji,
          todayMeDone: aBefore.todayMeDone,
        },
      );

      // 冪等: 同じ人の再送も、相手が先に解消したあとの解消も 200 dissolved:false(DB は書き換わらない)
      const again = await dissolve(a.jwt);
      rep.check(
        "A: もう一度 → 200 dissolved:false(冪等)",
        again.status === 200 && obj(again.json).dissolved === false,
        brief(again),
      );
      rep.shape(
        "A: 冪等の応答の形が pair-dissolve.already.json と一致",
        again.json,
        fx.pairDissolve,
      );
      const fromB = await dissolve(b.jwt);
      rep.check(
        "B: 相手が先に解消したあとの解消 → 200 dissolved:false(同時・再送でも安全)",
        fromB.status === 200 && obj(fromB.json).dissolved === false &&
          obj(obj(fromB.json).snapshot).pairId === null,
        brief(fromB),
      );

      // B の視点: ソロに戻る。自分の約束は残る
      expectFields(
        c,
        "B(解消後): ソロに戻る(ペア・相手の名前・相手の約束は見えない)",
        await getSnapshot(c, b, "B(解消後)"),
        {
          pairId: null,
          partnerName: null,
          partnerPromiseTitle: null,
          partnerPromiseEmoji: null,
          streakCurrent: 0,
          hasPartnerPhotoToday: false,
          ticketBalance: null, // ペア共有の在庫なので、ソロには持ち主がいない
          myPromiseTitle: b.promise.title,
          myPromiseEmoji: b.promise.emoji,
        },
      );

      // 解消後の閲覧境界(RLS が現役のペアだけを相互に読ませる)
      const after = await viaSignedUrl(c, b.jwt, photoPath);
      rep.check(
        `解消の後: B は A の写真の署名付き URL を作れない(HTTP ${SIGN_FAILURE_STATUS})`,
        after.sign.status === SIGN_FAILURE_STATUS && after.get === null,
        brief(after.sign),
        `HTTP ${after.sign.status}`,
      );
      const rows = await api.rest(b.jwt, "GET", partnerRowsQuery(b.id, today));
      rep.check(
        "解消の後: B から A の今日の checkins 行が読めない(0 件)",
        rows.status === 200 && arr(rows.json).length === 0,
        brief(rows),
      );
      const promises = await api.rest(
        b.jwt,
        "GET",
        `promises?select=id&user_id=eq.${a.id}`,
      );
      rep.check(
        "解消の後: B から A の約束が読めない(0 件)",
        promises.status === 200 && arr(promises.json).length === 0,
        brief(promises),
      );
      const own = await api.rest(
        a.jwt,
        "GET",
        `checkins?select=id&user_id=eq.${a.id}`,
      );
      rep.check(
        "解消の後: A は自分のチェックインの履歴を読める(履歴は残る)",
        own.status === 200 && arr(own.json).length >= 1,
        brief(own),
        `${arr(own.json).length} 行`,
      );
      expectError(
        c,
        "解消の後: B の nudge → 409 no_pair(相手とのあいだで届かなくなる)",
        await api.fn(b.jwt, "nudge", "POST", {
          json: { stamp: fx.stamps.nudge[0] },
        }),
        "nudge",
        "no_pair",
      );

      // DB: 行は消えずアーカイブとして残る
      if (!dbOn || !c.mgmt) {
        rep.skip(
          "DB の確認",
          c.options.dbChecks
            ? "SUPABASE_ACCESS_TOKEN が無い"
            : "--no-db-checks",
        );
        return;
      }
      const dbRows = await c.mgmt.sql<J>(`
      select
        (select status from public.pairs where id = '${pid}') as pair_status,
        (select dissolved_at is not null from public.pairs where id = '${pid}') as has_dissolved_at,
        (select count(*) from public.pair_members where pair_id = '${pid}') as members,
        (select name from public.plants where pair_id = '${pid}') as plant_name
    `);
      const row = dbRows[0] ?? {};
      rep.check(
        "DB: ペアは status = dissolved・dissolved_at あり・行は消えない(メンバー 2 人・植物の名前も残る = アーカイブ)",
        row.pair_status === "dissolved" && row.has_dissolved_at === true &&
          Number(row.members) === 2 && row.plant_name === d.plantName,
        JSON.stringify(row),
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S24",
    "組み直し(解消のあと、同じ 2 人が新しく招待 → 受諾。新しいペアは名前・残数を引き継がない)",
    async () => {
      const a = need("A");
      const b = need("B");
      const created = await api.fn(a.jwt, "invite-create", "POST");
      if (
        !rep.check(
          "A: 解消のあとは招待を作れる(POST /invite-create → 200)",
          created.status === 200,
          brief(created),
        )
      ) {
        throw new Abort("組み直せない(以降の手順は意味を持たない)");
      }
      const token = String(obj(created.json).token);
      const r = await api.fn(b.jwt, "invite-accept", "POST", {
        json: { token },
      });
      if (
        !rep.check(
          "B: 受諾 → 200(解消済みのペアの相手とも組み直せる)",
          r.status === 200,
          brief(r),
        )
      ) {
        throw new Abort("組み直せない(以降の手順は意味を持たない)");
      }
      rep.shape(
        "B: 応答の形が invite-accept.ok.json と一致",
        r.json,
        fx.inviteAccept,
      );
      const pair2 = String(obj(r.json).pairId);
      d.pairId2 = pair2;
      rep.check(
        "新しいペアの ID は UUID で、解消したペアとは別",
        UUID_RE.test(pair2) && pair2 !== d.pairId,
        `pairId=${pair2}`,
      );
      // 新しいペアには、解消したペアの植物の名前も残数も引き継がれない。close-day は呼んでいないので streak_days の行は無く、
      // 数えられるのは「今日のふたりのチェックイン」だけ: S15(B)と S18(A のやり直し)で、今日は 2 人ともチェックイン済み
      // なので、新しいペアも今日は「ふたり達成」(ストリーク 1・成長 1 回・段階 1)。チェックインの行はペアに属さない
      expectFields(
        c,
        "B: 新しいペアは植物の名前なし・お休みチケット 2 枚から(解消したペアの名前・残数は引き継がない)。今日のふたりのチェックインだけが数えられる(ストリーク 1・成長 1 回)",
        obj(obj(r.json).snapshot),
        {
          pairId: pair2,
          partnerName: a.nickname,
          plantName: null,
          todayMeDone: true,
          todayPartnerDone: true,
          streakCurrent: 1,
          plantGrownDays: 1,
          plantStage: 1,
          ticketBalance: 2, // 新しいペアも初期付与の 2 枚から(解消したペアの残数は引き継がない)
        },
      );
      expectFields(
        c,
        "A: 新しいペアが現役(相手は B・植物の名前なし)",
        await getSnapshot(c, a, "A(組み直し後)"),
        {
          pairId: pair2,
          partnerName: b.nickname,
          streakCurrent: 1,
          plantName: null,
          ticketBalance: 2,
        },
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S25",
    "アカウントの削除(delete-account: A。現役のペアあり)",
    async () => {
      const a = need("A");
      const b = need("B");
      const aId = uuid(a.id, "A の ID");
      const p1 = uuid(d.pairId ?? "", "pairId");
      const p2 = uuid(d.pairId2 ?? "", "pairId2");
      const del = (jwt: string | null) => api.fn(jwt, "delete-account", "POST");

      expectError(
        c,
        "未ログイン: POST /delete-account → 401 unauthorized",
        await del(null),
        "delete-account",
        "unauthorized",
      );
      expectError(
        c,
        "A: GET /delete-account → 405 method_not_allowed(POST だけ)",
        await api.fn(a.jwt, "delete-account", "GET"),
        "delete-account",
        "method_not_allowed",
      );

      if (dbOn && c.mgmt) {
        const rows = await c.mgmt.sql<J>(
          `select count(*) as n from storage.objects where bucket_id = 'photos' and name like 'pairs/%/${aId}/%'`,
        );
        rep.check(
          "削除の前(対照): A の写真が Storage にある(原寸とサムネの 2 オブジェクト)",
          Number(rows[0]?.n) === 2,
          `objects=${rows[0]?.n}`,
        );
      }

      const r = await del(a.jwt);
      if (
        !rep.check("A: POST /delete-account → 200", r.status === 200, brief(r))
      ) {
        throw new Abort("A を削除できない(以降の手順は意味を持たない)");
      }
      rep.shape(
        "A: 応答の形が delete-account.ok.json と一致",
        r.json,
        fx.deleteAccount,
      );
      rep.values(
        "A: 応答の値が delete-account.ok.json と一致(deleted = true)",
        r.json,
        fx.raw["delete-account.ok.json"],
        [],
      );

      // 削除のあと: A のトークンは使えない
      expectError(
        c,
        "A の JWT: GET /snapshot → 401 unauthorized(認証サーバーの確定した拒否。503 auth_unavailable ではない)",
        await api.fn(a.jwt, "snapshot", "GET"),
        "snapshot",
        "unauthorized",
      );
      expectError(
        c,
        "A の JWT: もう一度 delete-account → 401 unauthorized(2 回目は成功にならない)",
        await del(a.jwt),
        "delete-account",
        "unauthorized",
      );
      const gotrue = await api.authUser(a.jwt);
      const code = obj(gotrue.json).error_code;
      rep.check(
        "認証サーバーに直接たしかめても「ユーザーが居ない」(403 + user_not_found / session_not_found)— アプリの GoTrueSessionVerifier が .rejected と見る応答",
        gotrue.status === 403 &&
          (code === "user_not_found" || code === "session_not_found"),
        `HTTP ${gotrue.status} error_code=${String(code)}`,
        `HTTP ${gotrue.status} ${String(code)}`,
      );
      const refreshed = await api.refresh(a.refresh);
      rep.check(
        "A の refresh token も使えない(4xx)— アプリの認証 SDK はこの拒否でセッションを破棄する",
        refreshed.status >= 400 && refreshed.status < 500,
        brief(refreshed),
        `HTTP ${refreshed.status}`,
      );

      // B は無傷: ソロに戻り、自分のアカウントも約束もそのまま
      expectFields(
        c,
        "B(A の削除後): ソロに戻る・自分の約束は残る",
        await getSnapshot(c, b, "B(A の削除後)"),
        {
          pairId: null,
          partnerName: null,
          myPromiseTitle: b.promise.title,
        },
      );
      const bUser = await api.rest(
        b.jwt,
        "GET",
        `users?select=id&id=eq.${b.id}`,
      );
      rep.check(
        "B: 自分の users 行は無傷",
        bUser.status === 200 && arr(bUser.json).length === 1,
        brief(bUser),
      );

      if (!dbOn || !c.mgmt) {
        rep.skip(
          "DB の確認",
          c.options.dbChecks
            ? "SUPABASE_ACCESS_TOKEN が無い"
            : "--no-db-checks",
        );
        return;
      }
      const bId = uuid(b.id, "B の ID");
      const rows = await c.mgmt.sql<J>(`
      select
        (select count(*) from auth.users where id = '${aId}') as a_auth,
        (select count(*) from public.users where id = '${aId}') as a_users,
        (select count(*) from public.promises where user_id = '${aId}') as a_promises,
        (select count(*) from public.checkins where user_id = '${aId}') as a_checkins,
        (select count(*) from public.pair_members where user_id = '${aId}') as a_members,
        (select count(*) from storage.objects where bucket_id = 'photos' and name like 'pairs/%/${aId}/%') as a_photos,
        (select count(*) from auth.users where id = '${bId}') as b_auth,
        (select count(*) from public.pair_members where user_id = '${bId}' and pair_id in ('${p1}', '${p2}')) as b_members,
        (select count(*) from public.pairs where id in ('${p1}', '${p2}') and status = 'dissolved') as dissolved_pairs,
        (select count(*) from public.plants where pair_id = '${p1}') as archived_plants
    `);
      const row = rows[0] ?? {};
      const n = (k: string) => Number(row[k]);
      rep.check(
        "DB: A の auth ユーザー・users・約束・チェックイン・ペアの所属が消えた",
        n("a_auth") === 0 && n("a_users") === 0 && n("a_promises") === 0 &&
          n("a_checkins") === 0 && n("a_members") === 0,
        JSON.stringify(row),
      );
      rep.check(
        "Storage: A の写真(原寸・サムネ)が消えた",
        n("a_photos") === 0,
        `objects=${row.a_photos}`,
      );
      rep.check(
        "DB: B は無傷(auth ユーザーあり・2 つのペアに所属)で、2 つのペアはどちらも解消済みのアーカイブとして残る(植物の行も)",
        n("b_auth") === 1 && n("b_members") === 2 &&
          n("dissolved_pairs") === 2 && n("archived_plants") === 1,
        JSON.stringify(row),
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S26",
    "アカウントの削除(delete-account: B = 最後の所属者・C = ソロ)",
    async () => {
      const b = need("B");
      const cu = users.C;
      const p1 = uuid(d.pairId ?? "", "pairId");
      const p2 = uuid(d.pairId2 ?? "", "pairId2");

      const rb = await api.fn(b.jwt, "delete-account", "POST");
      rep.check(
        "B(最後の所属者): POST /delete-account → 200",
        rb.status === 200,
        brief(rb),
      );
      rep.shape(
        "B: 応答の形が delete-account.ok.json と一致",
        rb.json,
        fx.deleteAccount,
      );
      if (cu) {
        const rc = await api.fn(cu.jwt, "delete-account", "POST");
        rep.check(
          "C(ペア外・ソロ): POST /delete-account → 200",
          rc.status === 200,
          brief(rc),
        );
        rep.shape(
          "C: 応答の形が delete-account.ok.json と一致",
          rc.json,
          fx.deleteAccount,
        );
      } else {
        rep.skip("C の削除", "--no-outsider のため省略");
      }

      if (!dbOn || !c.mgmt) {
        rep.skip(
          "DB の確認",
          c.options.dbChecks
            ? "SUPABASE_ACCESS_TOKEN が無い"
            : "--no-db-checks",
        );
        return;
      }
      const ids = labels.map((l) => uuid(need(l).id, `${l} の ID`));
      const idArr = `array[${ids.map((i) => `'${i}'`).join(",")}]::uuid[]`;
      const pairs = `'${p1}', '${p2}'`;
      const rows = await c.mgmt.sql<J>(`
      select
        (select count(*) from auth.users where id = any(${idArr})) as auth_left,
        (select count(*) from public.users where id = any(${idArr})) as users_left,
        (select count(*) from public.promises where user_id = any(${idArr})) as promises_left,
        (select count(*) from public.checkins where user_id = any(${idArr})) as checkins_left,
        (select count(*) from public.invites where from_user = any(${idArr})) as invites_left,
        (select count(*) from public.pairs where id in (${pairs})) as pairs_left,
        (select count(*) from public.pair_members where pair_id in (${pairs})) as members_left,
        (select count(*) from public.plants where pair_id in (${pairs})) as plants_left,
        (select count(*) from public.ticket_ledger where pair_id in (${pairs})) as ledger_left,
        (select count(*) from public.nudges where pair_id in (${pairs})) as nudges_left,
        (select count(*) from storage.objects where bucket_id = 'photos' and (name like 'pairs/${p1}/%' or name like 'pairs/${p2}/%')) as objects_left
    `);
      const row = rows[0] ?? {};
      const left = Object.entries(row).filter(([, v]) => Number(v) !== 0);
      rep.check(
        "DB: 3 人のアカウントとその行(約束・チェックイン・招待)がすべて消えた",
        [
          "auth_left",
          "users_left",
          "promises_left",
          "checkins_left",
          "invites_left",
        ]
          .every((k) => Number(row[k]) === 0),
        JSON.stringify(row),
      );
      rep.check(
        "DB: 誰も残らなくなった 2 つのペアの行・所属・植物・お休みチケットの台帳・つつくが連鎖して消えた",
        [
          "pairs_left",
          "members_left",
          "plants_left",
          "ledger_left",
          "nudges_left",
        ]
          .every((k) => Number(row[k]) === 0),
        JSON.stringify(row),
      );
      rep.check(
        "Storage: 2 つのペアの下にオブジェクトが残っていない",
        Number(row.objects_left) === 0,
        `objects=${row.objects_left}`,
      );
      rep.check(
        "本番に残ったテストデータなし(上のすべての件数が 0)",
        left.length === 0,
        left.map(([k, v]) => `${k}=${v}`).join(" "),
      );
    },
  );
}
