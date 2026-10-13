// steps_flow.ts — S09〜S16: ペア成立後のコアループ(snapshot・写真つきチェックイン・相手が写真を読む経路 #59・nudge・react・ふたり達成・整合)
//
// 手順の流れ・守ること・登場人物は scenario.ts。共有の型と道具は scenario_lib.ts。

import {
  looksLikeJpeg,
  oversizedJpegLike,
  PHOTO_1,
  PHOTO_2,
  PNG_LIKE,
  sha256Hex,
  THUMB,
} from "./images.ts";
import { Abort, redact } from "./report.ts";
import { jsonEqual } from "./shape.ts";
import {
  arr,
  brief,
  type Ctx,
  expectError,
  expectFields,
  getSnapshot,
  obj,
  partnerRowsQuery,
  signFailureProblems,
  tamperSignedUrl,
  UPLOAD_REJECTED_STATUS,
  UUID_RE,
  viaSignedUrl,
  type World,
} from "./scenario_lib.ts";

export async function stepsFlow(c: Ctx, w: World): Promise<void> {
  const { api, rep, fx, today } = c;
  const { users, need, d } = w;

  // ------------------------------------------------------------------
  await rep.run(
    "S09",
    "成立直後の snapshot(両者。段階 0・回数 0・次は 1 回)",
    async () => {
      const a = need("A");
      const b = need("B");
      const base = {
        pairId: d.pairId,
        streakCurrent: 0,
        streakBest: 0,
        todayMeDone: false,
        todayPartnerDone: false,
        plantStage: 0,
        plantGrownDays: 0,
        plantStageFloor: 0,
        plantNextStageAt: 1,
        plantMood: "normal",
        plantName: null,
        hasPartnerPhotoToday: false,
        // お休みチケットの残数(issue #19): 初期付与の 2 枚。ペアの2人に同じ値が見える
        ticketBalance: 2,
      };
      const sa = await getSnapshot(c, a, "A");
      expectFields(
        c,
        "A: 成立直後の値(新キー plantGrownDays / plantStageFloor / plantNextStageAt / ticketBalance を含む)",
        sa,
        {
          ...base,
          partnerName: b.nickname,
          partnerPromiseTitle: b.promise.title,
          partnerPromiseEmoji: b.promise.emoji,
          myPromiseTitle: a.promise.title,
          myPromiseEmoji: a.promise.emoji,
        },
      );
      const sb = await getSnapshot(c, b, "B");
      const none = await api.rest(b.jwt, "GET", partnerRowsQuery(b.id, today));
      const noneFixture = fx.optional["partner-checkin.none.json"] ?? [];
      rep.check(
        "B: 相手がまだチェックインしていない間、PV の問い合わせは [](partner-checkin.none.json)",
        none.status === 200 && jsonEqual(none.json, noneFixture),
        brief(none),
      );
      expectFields(c, "B: 成立直後の値(受信者視点)", sb, {
        ...base,
        partnerName: a.nickname,
        partnerPromiseTitle: a.promise.title,
        partnerPromiseEmoji: a.promise.emoji,
        myPromiseTitle: b.promise.title,
        myPromiseEmoji: b.promise.emoji,
      });
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S10",
    "A: 写真つきチェックイン(署名付きアップロード → photoPath。差し替えも)",
    async () => {
      const a = need("A");
      const b = need("B");
      const pairId = d.pairId as string;
      const dir = `pairs/${pairId}/${today}/${a.id}`;

      // 1. チェックインと同時に署名付きアップロード URL を受け取る
      const issued = await api.fn(a.jwt, "checkin", "POST", {
        json: { dateLocal: today, requestPhotoUpload: true },
      });
      if (
        !rep.check(
          "A: POST /checkin(requestPhotoUpload)→ 200",
          issued.status === 200,
          brief(issued),
        )
      ) {
        throw new Abort("署名付きアップロード URL を受け取れない");
      }
      rep.shape(
        "A: 応答の形が checkin.photo-upload.json と一致",
        issued.json,
        fx.checkin,
      );
      const ij = obj(issued.json);
      const up = obj(ij.photoUpload);
      const photo = obj(up.photo);
      const thumb = obj(up.thumb);
      rep.check(
        "A: 新規のチェックイン(alreadyCheckedIn = false)",
        ij.alreadyCheckedIn === false,
        JSON.stringify(ij.alreadyCheckedIn),
      );
      rep.check(
        "A: 発行されたパスが pairs/<pair>/<今日>/<自分>/photo.jpg と photo_thumb.jpg(本人の区画)",
        photo.path === `${dir}/photo.jpg` &&
          thumb.path === `${dir}/photo_thumb.jpg`,
        `${photo.path} / ${thumb.path}`,
      );
      rep.check(
        "A: 署名トークンが原寸・サムネの両方にある",
        typeof photo.token === "string" && String(photo.token).length > 20 &&
          typeof thumb.token === "string" && String(thumb.token).length > 20,
        "token が短い / 無い",
      );
      expectFields(c, "A: snapshot は自分だけ完了(fidget)", ij.snapshot, {
        todayMeDone: true,
        todayPartnerDone: false,
        plantMood: "fidget",
        hasPartnerPhotoToday: false,
      });
      d.photoPath = String(photo.path);
      d.thumbPath = String(thumb.path);
      await c.state.addStoragePath(d.photoPath);
      await c.state.addStoragePath(d.thumbPath);

      // 2. 原寸とサムネをアップロード(アプリと同じ: Content-Type と x-upsert だけ)
      const put = async (
        name: string,
        path: string,
        token: string,
        bytes: Uint8Array<ArrayBuffer>,
      ) => {
        const r = await api.signedUpload(path, token, bytes);
        if (r.status === 200) return rep.check(name, true);
        rep.fail(name, brief(r));
        // 切り分け: apikey / Authorization を付ければ通るか(アプリの uploadPhoto が付けていないヘッダ)
        const withKeys = await api.signedUpload(path, token, bytes, {
          apikey: api.anonKey,
          Authorization: `Bearer ${a.jwt}`,
        });
        rep.note(
          `${name} — apikey / Authorization を付けた再試行`,
          withKeys.status === 200
            ? "通った。アプリの EdgeFunctionCheckinClient.uploadPhoto にヘッダの追加が要る"
            : `これも失敗: ${brief(withKeys)}`,
        );
        return false;
      };
      await put(
        "A: 原寸 photo.jpg の署名付きアップロード(PUT)→ 200",
        String(photo.path),
        String(photo.token),
        PHOTO_1,
      );
      await put(
        "A: サムネ photo_thumb.jpg の署名付きアップロード(PUT)→ 200",
        String(thumb.path),
        String(thumb.token),
        THUMB,
      );

      // 3. photoPath 付きで再送 → 行に記録される(2 回目なので alreadyCheckedIn)
      const fin = await api.fn(a.jwt, "checkin", "POST", {
        json: { dateLocal: today, photoPath: d.photoPath },
      });
      rep.check(
        "A: photoPath 付きの POST /checkin → 200",
        fin.status === 200,
        brief(fin),
      );
      rep.shape("A: 応答の形が契約フィクスチャと一致", fin.json, fx.checkin);
      rep.check(
        "A: alreadyCheckedIn = true(同じ日の再送。冪等)",
        obj(fin.json).alreadyCheckedIn === true,
        JSON.stringify(obj(fin.json).alreadyCheckedIn),
      );

      // 4. 差し替え(同じ日の貼り直し。x-upsert)
      const again = await api.fn(a.jwt, "checkin", "POST", {
        json: { dateLocal: today, requestPhotoUpload: true },
      });
      const ph2 = obj(obj(again.json).photoUpload).photo;
      rep.check(
        "A: 差し替え用に署名付きアップロード URL をもう一度受け取れる",
        again.status === 200 && obj(ph2).path === d.photoPath,
        brief(again),
      );
      await put(
        "A: 原寸を別の画像で上書き(PUT・x-upsert)→ 200",
        String(obj(ph2).path),
        String(obj(ph2).token),
        PHOTO_2,
      );
      const fin2 = await api.fn(a.jwt, "checkin", "POST", {
        json: { dateLocal: today, photoPath: d.photoPath },
      });
      rep.check(
        "A: 差し替え後の photoPath 付き再送 → 200・alreadyCheckedIn = true",
        fin2.status === 200 && obj(fin2.json).alreadyCheckedIn === true,
        brief(fin2),
      );

      // 4b. バケットの制限(migration 0008): 上限(6 MiB)を超えるファイルと JPEG 以外は、署名付きアップロードでも断られる。
      //     断られ方は、署名の発行の失敗(S12)と同じく **HTTP 400 + 本文の statusCode / error**(HTTP ステータスは 413 / 415 でない。
      //     本番の実測 2026-10-13)。断られたあとも置いてある写真(差し替え後の PHOTO_2)は変わらない(S12 が SHA-256 で確かめる)。
      //     試すたびに新しい署名付き URL を受け取る(失敗が署名の使い回しのせいでないことを分けるため)
      const rejectedUpload = async (
        name: string,
        bytes: Uint8Array<ArrayBuffer>,
        contentType: string,
        expected: { statusCode: string; error: string },
      ) => {
        const fresh = await api.fn(a.jwt, "checkin", "POST", {
          json: { dateLocal: today, requestPhotoUpload: true },
        });
        const target = obj(obj(obj(fresh.json).photoUpload).photo);
        if (
          fresh.status !== 200 || typeof target.token !== "string" ||
          target.path !== d.photoPath
        ) {
          rep.fail(
            name,
            `署名付きアップロード URL を受け取れない: ${brief(fresh)}`,
          );
          return;
        }
        const r = await api.signedUpload(
          String(target.path),
          String(target.token),
          bytes,
          { "Content-Type": contentType },
        );
        const body = obj(r.json);
        rep.check(
          name,
          r.status === UPLOAD_REJECTED_STATUS &&
            body.statusCode === expected.statusCode &&
            body.error === expected.error,
          `期待 HTTP ${UPLOAD_REJECTED_STATUS}・statusCode ${expected.statusCode}・error ${expected.error}、実際 ${
            brief(r)
          }`,
          `HTTP ${r.status} statusCode ${body.statusCode} ${body.error}`,
        );
      };
      await rejectedUpload(
        "A: 上限(6 MiB)を 1 バイト超える JPEG は断られる(Payload too large)",
        oversizedJpegLike(),
        "image/jpeg",
        { statusCode: "413", error: "Payload too large" },
      );
      await rejectedUpload(
        "A: PNG(Content-Type: image/png)は断られる(invalid_mime_type)",
        PNG_LIKE,
        "image/png",
        { statusCode: "415", error: "invalid_mime_type" },
      );
      await rejectedUpload(
        "A: JPEG の中身でも Content-Type が application/octet-stream なら断られる(invalid_mime_type)",
        PHOTO_1,
        "application/octet-stream",
        { statusCode: "415", error: "invalid_mime_type" },
      );

      // 5. photoPath の規約違反は 400(本人の原寸パス以外は受け付けない)
      const badPath = async (name: string, photoPath: string) =>
        expectError(
          c,
          name,
          await api.fn(a.jwt, "checkin", "POST", {
            json: { dateLocal: today, photoPath },
          }),
          "checkin",
          "invalid_photo_path",
        );
      await badPath(
        "A: 相手(B)の区画のパス → 400 invalid_photo_path",
        `pairs/${pairId}/${today}/${b.id}/photo.jpg`,
      );
      await badPath(
        "A: サムネのパス → 400 invalid_photo_path",
        `${dir}/photo_thumb.jpg`,
      );
      await badPath(
        "A: 旧形式(ペア×日付)のパス → 400 invalid_photo_path",
        `pairs/${pairId}/${today}/photo.jpg`,
      );
      await badPath(
        "A: ../ で相手の区画へ → 400 invalid_photo_path",
        `${dir}/../${b.id}/photo.jpg`,
      );
      await badPath(
        "A: 別のペアのパス → 400 invalid_photo_path",
        `pairs/00000000-0000-4000-8000-000000000000/${today}/${a.id}/photo.jpg`,
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run("S11", "snapshot(A だけ完了。相手の写真あり)", async () => {
    const a = need("A");
    const b = need("B");
    const sa = await getSnapshot(c, a, "A");
    expectFields(c, "A: 自分だけ完了(fidget)・相手の写真は無い", sa, {
      todayMeDone: true,
      todayPartnerDone: false,
      plantMood: "fidget",
      hasPartnerPhotoToday: false,
      streakCurrent: 0,
      plantGrownDays: 0,
      plantStage: 0,
    });
    const sb = await getSnapshot(c, b, "B");
    expectFields(
      c,
      "B: 相手(A)だけ完了(fidget)・相手の写真あり(hasPartnerPhotoToday = true)",
      sb,
      {
        todayMeDone: false,
        todayPartnerDone: true,
        plantMood: "fidget",
        hasPartnerPhotoToday: true,
        streakCurrent: 0,
        plantGrownDays: 0,
        plantStage: 0,
      },
    );
  });

  // ------------------------------------------------------------------
  await rep.run(
    "S12",
    "相手が写真を読む経路(#59 PV): PostgREST で photo_path → 署名付き URL → 画像",
    async () => {
      const a = need("A");
      const b = need("B");
      const photoPath = d.photoPath as string;
      const thumbPath = d.thumbPath as string;

      // 既存の resolver(react 用)と同じクエリ: id だけ
      const q1 = await api.rest(
        b.jwt,
        "GET",
        `checkins?select=id&date_local=eq.${today}&user_id=neq.${b.id}&limit=1`,
      );
      const row1 = obj(arr(q1.json)[0]);
      rep.check(
        "B: 相手の当日のチェックイン行を読める(PostgREST・RLS checkins_select_pair)",
        q1.status === 200 && arr(q1.json).length === 1 &&
          UUID_RE.test(String(row1.id)),
        brief(q1),
      );
      d.aCheckinId = String(row1.id);

      // PV が広げるクエリ: photo_path まで
      const q2 = await api.rest(
        b.jwt,
        "GET",
        `checkins?select=id,user_id,date_local,photo_path&date_local=eq.${today}&user_id=neq.${b.id}&limit=1`,
      );
      const row2 = obj(arr(q2.json)[0]);
      rep.check(
        "B: 行に photo_path が入っている(= A が最後に送った原寸のパス)・user_id は A",
        q2.status === 200 && row2.photo_path === photoPath &&
          row2.user_id === a.id &&
          row2.id === d.aCheckinId && row2.date_local === today,
        JSON.stringify(row2),
      );

      // PV の問い合わせそのもの(手書きフィクスチャ partner-checkin.*.json の要求): select=id,photo_path
      const pv = await api.rest(
        b.jwt,
        "GET",
        partnerRowsQuery(b.id, today),
      );
      rep.check(
        "B: PV の問い合わせ(select=id,photo_path&…&limit=1)→ 200・1 行・photo_path は文字列",
        pv.status === 200 && arr(pv.json).length === 1 &&
          typeof obj(arr(pv.json)[0]).photo_path === "string",
        brief(pv),
      );
      if (fx.partnerCheckin) {
        rep.shape(
          "B: 行の形が partner-checkin.photo.json と一致(キーは id / photo_path だけ)",
          pv.json,
          fx.partnerCheckin,
        );
      } else {
        rep.skip(
          "B: partner-checkin.*.json との突き合わせ",
          "手書きのフィクスチャが contracts/ に無い(PV #59 が足すもの)",
        );
      }

      // 署名付き URL(原寸)。寿命はアプリと同じ 3600 秒
      const full = await viaSignedUrl(c, b.jwt, photoPath);
      rep.check(
        "B: 原寸の署名付き URL を作れる(POST /storage/v1/object/sign/photos/<path>)→ 200",
        full.sign.status === 200 && full.signedUrl !== null,
        brief(full.sign),
      );
      if (fx.storageSign) {
        rep.shape(
          "B: 署名の応答の形が storage-sign.ok.json と一致(キーは signedURL だけ)",
          full.sign.json,
          fx.storageSign,
        );
      }
      if (full.signedUrl) {
        let shapeOk = false;
        try {
          shapeOk = decodeURIComponent(full.signedUrl.split("?")[0]).endsWith(
            `/object/sign/photos/${photoPath}`,
          ) &&
            /[?&]token=[^&]+/.test(full.signedUrl);
        } catch { /* shapeOk のまま */ }
        rep.check(
          "B: signedURL が /object/sign/photos/<path>?token=... の形(基準 URL は {base}/storage/v1)",
          shapeOk && Object.keys(obj(full.sign.json)).join(",") === "signedURL",
          `キー=${Object.keys(obj(full.sign.json)).join(",")}`,
        );
      }
      if (full.get) {
        rep.check(
          "B: 署名付き URL をヘッダなしで GET → 200・image/jpeg・JPEG",
          full.get.status === 200 &&
            (full.get.headers.get("content-type") ?? "").includes(
              "image/jpeg",
            ) &&
            looksLikeJpeg(full.get.bytes),
          `HTTP ${full.get.status} ${full.get.headers.get("content-type")}`,
        );
        rep.check(
          "B: 取り戻した画像が A の最後のアップロード(差し替え後)と同じバイト列(SHA-256)",
          await sha256Hex(full.get.bytes) === await sha256Hex(PHOTO_2),
          `${full.get.bytes.length} バイト(期待 ${PHOTO_2.length})`,
        );
        // 署名が検証される(署名部の途中の 1 文字を変えたら通らない。最後の文字は詰め物のビットなので変えない)
        const tampered = tamperSignedUrl(full.signedUrl as string);
        if (tampered === null) {
          rep.fail(
            "署名付き URL の署名を改ざんできない(token が JWT の形でない)",
            "signedURL に token= が無い、または署名部が短い",
          );
        } else {
          const bad = await api.signedGet(tampered);
          rep.check(
            "署名付き URL の署名を 1 文字変えると取れない(200 にならない)",
            bad.status !== 200,
            `HTTP ${bad.status}`,
            `HTTP ${bad.status}`,
          );
        }
      }

      // サムネ(ホームに出すのはこちら。パスは原寸の photo.jpg を photo_thumb.jpg に読み替えたもの)
      const th = await viaSignedUrl(c, b.jwt, thumbPath);
      rep.check(
        "B: サムネの署名付き URL を作れて、取り戻した画像が A のアップロードと同じ",
        th.sign.status === 200 && th.get?.status === 200 &&
          await sha256Hex(th.get.bytes) === await sha256Hex(THUMB),
        th.get ? `HTTP ${th.get.status}` : brief(th.sign),
      );
      if (fx.storageSign) {
        rep.shape(
          "B: サムネの署名の応答の形も storage-sign.ok.json と一致",
          th.sign.json,
          fx.storageSign,
        );
      }

      // 署名付き URL の失効(寿命 1 秒で作って待つ)。アプリは 400 / 401 / 403 を「失効」として署名からやり直す
      const shortLived = await api.storageSign(b.jwt, thumbPath, 1);
      const shortUrl = obj(shortLived.json).signedURL;
      if (shortLived.status === 200 && typeof shortUrl === "string") {
        await new Promise((resolve) => setTimeout(resolve, 2500));
        const late = await api.signedGet(shortUrl);
        rep.check(
          "寿命が切れた署名付き URL は取れない(アプリが「失効」とみなす 400 / 401 / 403 のどれか)",
          [400, 401, 403].includes(late.status),
          `HTTP ${late.status} ${redact(late.text).slice(0, 120)}`,
          `HTTP ${late.status} ${redact(late.text).slice(0, 100)}`,
        );
      } else {
        rep.fail("寿命 1 秒の署名付き URL を作れない", brief(shortLived));
      }

      // 「無い」オブジェクト(同じペアの、存在しないファイル)の署名の発行
      const missing = await viaSignedUrl(
        c,
        b.jwt,
        `${photoPath.replace(/photo\.jpg$/, "")}missing.jpg`,
      );
      rep.check(
        "B: 存在しないオブジェクトの署名付き URL は作れない(200 にならない)",
        missing.sign.status !== 200,
        brief(missing.sign),
        `HTTP ${missing.sign.status} 本文の statusCode=${
          JSON.stringify(obj(missing.sign.json).statusCode)
        }`,
      );
      // 署名の発行の失敗の契約は HTTP 400 + 本文 { statusCode: "404", error: "not_found", ... }
      // (contracts/storage-sign.not-found.json。404 ではない)。ずれたら FAIL(+ 契約とのずれ)
      if (fx.storageSignNotFound) {
        const problems = signFailureProblems(
          missing.sign.status,
          missing.sign.json,
          fx.storageSignNotFound,
        );
        if (
          !rep.check(
            "B: 署名の発行の失敗が storage-sign.not-found.json の契約どおり(HTTP 400・本文の statusCode / error が一致)",
            problems.length === 0,
            problems.join(" / "),
            `HTTP ${missing.sign.status}`,
          )
        ) {
          rep.deviation(
            `署名の発行(POST sign)の失敗が storage-sign.not-found.json と違う: ${
              problems.join(" / ")
            }`,
          );
        }
      } else if (fx.storageSign && missing.sign.status !== 404) {
        // 手書きのフィクスチャが無い間: 署名の発行の失敗は 404 でなく 400 で返る(本番の実測)ので、契約が未整備
        rep.deviation(
          `署名の発行(POST sign)の「無い・読めない」は HTTP ${missing.sign.status}(本文の statusCode は ${
            JSON.stringify(obj(missing.sign.json).statusCode)
          })で、契約のフィクスチャ(contracts/storage-sign.not-found.json)が無い。` +
            "HTTP 404 を想定した説明(contracts/README.md)と StoragePhotoURLSigner の写像は、実際の 400 とずれている",
        );
      }

      // ペア外・未ログインには見えない
      const cu = users.C;
      if (cu) {
        const q = await api.rest(
          cu.jwt,
          "GET",
          `checkins?select=id,user_id,photo_path&date_local=eq.${today}&limit=10`,
        );
        rep.check(
          "C(ペア外): checkins を読んでも返るのは自分の行だけ(A / B の行は返らない。RLS)",
          q.status === 200 &&
            arr(q.json).every((r) => obj(r).user_id === cu.id),
          brief(q),
        );
        const q3 = await api.rest(
          cu.jwt,
          "GET",
          `checkins?select=id,photo_path&id=eq.${d.aCheckinId}`,
        );
        rep.check(
          "C(ペア外): A の行を id 指定で読んでも 0 件",
          q3.status === 200 && arr(q3.json).length === 0,
          brief(q3),
        );
        const s = await viaSignedUrl(c, cu.jwt, photoPath);
        rep.check(
          "C(ペア外): 同じパスの署名付き URL は作れない(200 にならない)",
          s.sign.status !== 200,
          `HTTP ${s.sign.status} ${redact(s.sign.text).slice(0, 120)}`,
          `HTTP ${s.sign.status} ${redact(s.sign.text).slice(0, 100)}`,
        );
      } else {
        rep.skip("C(ペア外)からは見えない", "--no-outsider のため省略");
      }
      const anonRows = await api.rest(
        null,
        "GET",
        `checkins?select=id,photo_path&limit=5`,
      );
      rep.check(
        "未ログイン(anon キーだけ): checkins は何も返らない",
        !(anonRows.status === 200 && arr(anonRows.json).length > 0),
        brief(anonRows),
        `HTTP ${anonRows.status}`,
      );
      const anonSign = await viaSignedUrl(c, null, photoPath);
      rep.check(
        "未ログイン(anon キーだけ): 署名付き URL は作れない",
        anonSign.sign.status !== 200,
        `HTTP ${anonSign.sign.status}`,
        `HTTP ${anonSign.sign.status}`,
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run("S13", "つつく(nudge: A → B。B は未完)", async () => {
    const a = need("A");
    const cu = users.C;
    const stamps = fx.stamps.nudge;
    for (let i = 0; i < 3; i++) {
      const r = await api.fn(a.jwt, "nudge", "POST", {
        json: { stamp: stamps[i] },
      });
      rep.check(
        `A: ${stamps[i]} でつつく(${i + 1} 回目)→ 200`,
        r.status === 200,
        brief(r),
      );
      rep.shape(
        `A: ${i + 1} 回目の応答の形が nudge.ok.json と一致`,
        r.json,
        fx.nudge,
      );
      rep.check(
        `A: remainingToday = ${2 - i}`,
        obj(r.json).remainingToday === 2 - i,
        JSON.stringify(obj(r.json).remainingToday),
      );
    }
    expectError(
      c,
      "A: 4 回目 → 429 nudge_limit_exceeded(1 日 3 回まで)",
      await api.fn(a.jwt, "nudge", "POST", { json: { stamp: stamps[0] } }),
      "nudge",
      "nudge_limit_exceeded",
    );
    expectError(
      c,
      "A: 語彙外のスタンプ → 400 invalid_stamp",
      await api.fn(a.jwt, "nudge", "POST", { json: { stamp: "x" } }),
      "nudge",
      "invalid_stamp",
    );
    expectError(
      c,
      "A: stamp なし → 400 invalid_stamp",
      await api.fn(a.jwt, "nudge", "POST", { json: {} }),
      "nudge",
      "invalid_stamp",
    );
    if (cu) {
      expectError(
        c,
        "C(ペアなし): つつく相手がいない → 409 no_pair",
        await api.fn(cu.jwt, "nudge", "POST", { json: { stamp: stamps[0] } }),
        "nudge",
        "no_pair",
      );
    }
  });

  // ------------------------------------------------------------------
  await rep.run(
    "S14",
    "リアクション(react: B → A のチェックイン)",
    async () => {
      const a = need("A");
      const b = need("B");
      const cu = users.C;
      const checkinId = d.aCheckinId;
      if (!checkinId) throw new Abort("A のチェックイン id が無い(S12 の失敗)");
      const stamps = fx.stamps.reaction;
      const react = (jwt: string, payload: { json?: unknown; raw?: string }) =>
        api.fn(jwt, "react", "POST", payload);

      expectError(
        c,
        "B: 語彙外のスタンプ → 400 invalid_stamp",
        await react(b.jwt, { json: { checkinId, stamp: "x" } }),
        "react",
        "invalid_stamp",
      );
      expectError(
        c,
        "B: checkinId が文字列でない → 400 invalid_request",
        await react(b.jwt, { json: { checkinId: 123, stamp: stamps[0] } }),
        "react",
        "invalid_request",
      );
      expectError(
        c,
        "B: 存在しない checkinId → 404 checkin_not_found",
        await react(b.jwt, {
          json: {
            checkinId: "00000000-0000-4000-8000-000000000000",
            stamp: stamps[0],
          },
        }),
        "react",
        "checkin_not_found",
      );
      expectError(
        c,
        "A: 自分のチェックインには付けられない → 403 not_partner",
        await react(a.jwt, { json: { checkinId, stamp: stamps[0] } }),
        "react",
        "not_partner",
      );
      if (cu) {
        expectError(
          c,
          "C(ペアなし): → 409 no_pair",
          await react(cu.jwt, { json: { checkinId, stamp: stamps[0] } }),
          "react",
          "no_pair",
        );
      }

      const first = await react(b.jwt, {
        json: { checkinId, stamp: stamps[0] },
      });
      rep.check(
        `B: ${stamps[0]} を付ける → 200・changed = true(新規)`,
        first.status === 200 && obj(first.json).changed === true,
        brief(first),
      );
      rep.shape("B: 応答の形が react.ok.json と一致", first.json, fx.react);
      const same = await react(b.jwt, {
        json: { checkinId, stamp: stamps[0] },
      });
      rep.check(
        "B: 同じスタンプの再送 → 200・changed = false(冪等)",
        same.status === 200 && obj(same.json).changed === false,
        brief(same),
      );
      // 付け替え: 語彙の残り 5 つを順に(すべて受理され、保存内容が変わる)
      const results: string[] = [];
      for (const s of stamps.slice(1)) {
        const r = await react(b.jwt, { json: { checkinId, stamp: s } });
        results.push(`${s}:${r.status}/${obj(r.json).changed}`);
      }
      rep.check(
        "B: 残りの語彙 5 種に付け替え → すべて 200・changed = true",
        results.every((x) => x.endsWith("200/true")),
        results.join(" "),
      );

      // 保存された行: 1 チェックインに 1 人 1 つ。最後のスタンプ。A からも読める(RLS reactions_select_pair)
      const last = stamps[stamps.length - 1];
      const rowsA = await api.rest(
        a.jwt,
        "GET",
        `reactions?select=checkin_id,from_user,stamp&checkin_id=eq.${checkinId}`,
      );
      rep.eq(
        "A: reactions を読める。B の 1 件だけで、最後のスタンプ",
        rowsA.json,
        [{ checkin_id: checkinId, from_user: b.id, stamp: last }],
      );

      // ペア外(C)・未ログインには見えない(reactions_select_pair)。上の A の読み取りが対照(同じ問い合わせで 1 件見える)。
      // reactions は S18 の取消で CASCADE で消えるので、表の中身が残っているうちのここで確かめる(S22 は reactions を除く)
      const reactionsQuery =
        `reactions?select=checkin_id,from_user,stamp&checkin_id=eq.${checkinId}`;
      if (cu) {
        const q = await api.rest(cu.jwt, "GET", reactionsQuery);
        rep.check(
          "C(ペア外): A のチェックインへの reactions は 0 件(RLS)",
          q.status === 200 && arr(q.json).length === 0,
          `HTTP ${q.status} ${arr(q.json).length} 行`,
        );
      } else {
        rep.skip(
          "C(ペア外)から reactions は見えない",
          "--no-outsider のため省略",
        );
      }
      const anonQ = await api.rest(null, "GET", reactionsQuery);
      rep.check(
        "未ログイン(anon キーだけ): reactions は何も返らない",
        !(anonQ.status === 200 && arr(anonQ.json).length > 0),
        `HTTP ${anonQ.status} ${arr(anonQ.json).length} 行`,
        `HTTP ${anonQ.status}`,
      );
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S15",
    "B のチェックイン → ふたり達成(ストリーク 1・成長 1 回・段階 1)",
    async () => {
      const a = need("A");
      const b = need("B");
      const r = await api.fn(b.jwt, "checkin", "POST", {
        json: { dateLocal: today },
      });
      rep.check("B: POST /checkin → 200", r.status === 200, brief(r));
      rep.shape("B: 応答の形が契約フィクスチャと一致", r.json, fx.checkin);
      rep.check(
        "B: alreadyCheckedIn = false",
        obj(r.json).alreadyCheckedIn === false,
        JSON.stringify(obj(r.json).alreadyCheckedIn),
      );
      const both = {
        pairId: d.pairId,
        todayMeDone: true,
        todayPartnerDone: true,
        streakCurrent: 1,
        streakBest: 1,
        plantStage: 1,
        plantGrownDays: 1,
        plantStageFloor: 1,
        plantNextStageAt: 3,
        plantMood: "happy",
      };
      expectFields(
        c,
        "B: 応答の snapshot が「ふたり達成」(段階 1・次は 3 回)・A の写真が見える",
        obj(r.json).snapshot,
        {
          ...both,
          hasPartnerPhotoToday: true,
        },
      );
      const again = await api.fn(b.jwt, "checkin", "POST", {
        json: { dateLocal: today },
      });
      rep.check(
        "B: もう一度 → 200・alreadyCheckedIn = true",
        again.status === 200 && obj(again.json).alreadyCheckedIn === true,
        brief(again),
      );

      expectError(
        c,
        "A: B が完了済みの日につつく → 409 partner_already_done",
        await api.fn(a.jwt, "nudge", "POST", {
          json: { stamp: fx.stamps.nudge[0] },
        }),
        "nudge",
        "partner_already_done",
      );

      const sa = await getSnapshot(c, a, "A");
      expectFields(c, "A: GET /snapshot も「ふたり達成」・B は写真なし", sa, {
        ...both,
        hasPartnerPhotoToday: false,
      });
    },
  );

  // ------------------------------------------------------------------
  await rep.run(
    "S16",
    "両者の snapshot の整合(受信者視点で、ペアの値は同じ)",
    async () => {
      const a = need("A");
      const b = need("B");
      const sa = await getSnapshot(c, a, "A");
      const sb = await getSnapshot(c, b, "B");
      const shared = [
        "schemaVersion",
        "pairId",
        "streakCurrent",
        "streakBest",
        "plantStage",
        "plantGrownDays",
        "plantStageFloor",
        "plantNextStageAt",
        "plantMood",
        "plantName",
        "ticketBalance",
      ];
      const diffs = shared.filter((k) => !jsonEqual(sa[k], sb[k]));
      rep.check(
        "ペア共通の項目(ストリーク・植物)が A と B で同じ",
        diffs.length === 0,
        diffs.map((k) =>
          `${k}: ${JSON.stringify(sa[k])} / ${JSON.stringify(sb[k])}`
        ).join(" / "),
      );
      rep.check(
        "向きが反転している(A の me = B の partner)",
        sa.todayMeDone === sb.todayPartnerDone &&
          sa.todayPartnerDone === sb.todayMeDone &&
          sa.partnerName === b.nickname && sb.partnerName === a.nickname &&
          sa.myPromiseTitle === sb.partnerPromiseTitle &&
          sb.myPromiseTitle === sa.partnerPromiseTitle,
        `A.partnerName=${sa.partnerName} B.partnerName=${sb.partnerName}`,
      );
      rep.check(
        "schemaVersion = 1(互換性の契約)",
        sa.schemaVersion === 1 && sb.schemaVersion === 1,
        `${sa.schemaVersion}/${sb.schemaVersion}`,
      );
    },
  );
}
