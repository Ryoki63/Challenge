// scenario.ts — 本番に対する 2 ユーザーの API 通しテストの手順(issue #67)の順序
//
// 登場人物(いずれも新しい匿名ユーザー。サインアップの印 lien_e2e・ニックネーム E2E-A / E2E-B / E2E-C・絵文字 🧪・
//   約束の「E2E 」接頭辞が、後片付けの安全装置の目印になる。marker.ts):
//   A = 招待する側 / B = 招待を受ける側 … ペアになる 2 人
//   C = ペア外のユーザー … ソロのチェックインと、ペア外から見えてはいけないものの確認に使う
//
// 手順(S 番号は出力・issue のコメントと対応する):
//   S01 匿名ユーザー  S02 エラーの基本形  S03 プロフィール  S04 snapshot(新規)  S05 約束  S06 snapshot(ソロ)
//   S07 ソロの確認  S08 招待→ペア成立  S09 成立直後の snapshot  S10 写真つきチェックイン(署名付きアップロード)
//   S11 snapshot(片方だけ完了)  S12 相手が写真を読む経路(#59 PV)  S13 nudge  S14 react  S15 ふたり達成
//   S16 snapshot の整合  S17 植物の名前  S18 チェックイン取消→やり直し  S19 push 登録の経路(PushTokenSync)
//   S20 クライアントの書き込み権限の境界  S21 DB の中身(Management API で SELECT)
//   S22 ペア外(C)・未ログインから A–B ペアの表が見えない(RLS。reactions だけは取消で消える前の S14 で確かめる)
//   S23 ペアの解消(pair-dissolve。冪等・解消後の閲覧境界)  S24 組み直し(新しいペアは 0 から)
//   S25 アカウントの削除(delete-account: A。現役のペアあり)  S26 アカウントの削除(B = 最後の所属者・C = ソロ)
//   ※ S25・S26 でテストユーザー自身を消すので、全部通ると A / B / C は存在しない(後片付けは「もう DB に無い」として扱う)
//
// 守ること:
//   - close-day / grant-tickets は呼ばない(OPS §10)。新しいペアの started_on は今日なので、昨日の確定の対象にも入らない
//   - アプリが実際に送るヘッダ・本文の形で呼ぶ(client.ts)。CI で通る形ではなく、本番で通る形を見る
//   - 応答はフィクスチャ(products/lien/contracts/)と形で突き合わせ、ずれは FAIL にして「契約とのずれ」に集める
//   - 失敗しても、作ったデータの ID は state に残る(後片付けできる)
//
// 構成: 型と道具は scenario_lib.ts、手順は steps_setup.ts(S01〜S08)/ steps_flow.ts(S09〜S16)/
//   steps_after.ts(S17〜S22)/ steps_account.ts(S23〜S26)。手順を足すときは該当ファイルに rep.run("S27", ...) の形で足し、ここの一覧にも書く。

import { stepsAccount } from "./steps_account.ts";
import { stepsAfter } from "./steps_after.ts";
import { stepsFlow } from "./steps_flow.ts";
import { stepsSetup } from "./steps_setup.ts";
import { createWorld, type Ctx } from "./scenario_lib.ts";

export type { Ctx, ScenarioOptions } from "./scenario_lib.ts";

/** 手順を順に流す。前提が崩れたら Abort が上がる(呼び出し側が集計・後片付けへ進む) */
export async function runScenario(c: Ctx): Promise<void> {
  const w = createWorld(c);
  await stepsSetup(c, w);
  await stepsFlow(c, w);
  await stepsAfter(c, w);
  await stepsAccount(c, w);
}
