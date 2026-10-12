// push_env_static_test.ts — push を送る Edge Function が push_env を読み忘れていないことの静的テスト(issue #60 項目7)
//
// APNs の環境(sandbox / production)はトークン単位。送り先の users 行を読むとき(getUser / getActivePair)に
// push_token と一緒に push_env も読み、送信オプションの environment に渡す(DESIGN §4.1)。
// 読み忘れると、そのユーザーへの push は黙って APNS_ENV に落ちる(TestFlight と開発ビルドが混在した瞬間に
// 片方へ届かない、という push_env を入れた理由そのものの不具合)。各 index.ts が users の読み出しに
// _shared/user_rows.ts を使っていること、送信のたびの逆引きが戻っていないことを、ソースを読んで検査する。
//
// 実行: deno test --allow-read products/lien/scripts/ops/(lien-cron-watch の ops-tests ジョブ)

const FUNCTIONS = new URL("../../supabase/functions/", import.meta.url);

function assert(cond: boolean, msg = ""): void {
  if (!cond) throw new Error(`assert failed: ${msg}`);
}

function assertEquals(actual: unknown, expected: unknown, msg = ""): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

async function read(rel: string): Promise<string> {
  return await Deno.readTextFile(new URL(rel, FUNCTIONS));
}

/** createPusher を使う = push を送る Function(index.ts) */
async function pushingFunctions(): Promise<string[]> {
  const names: string[] = [];
  for await (const entry of Deno.readDir(FUNCTIONS)) {
    if (!entry.isDirectory || entry.name.startsWith("_")) continue;
    let index: string;
    try {
      index = await read(`${entry.name}/index.ts`);
    } catch {
      continue;
    }
    if (index.includes("createPusher(")) names.push(entry.name);
  }
  return names.sort();
}

Deno.test("push を送る Function は 8 つ(増えたら、その index.ts も下の検査に入る)", async () => {
  assertEquals(await pushingFunctions(), [
    "checkin",
    "checkin-cancel",
    "close-day",
    "invite-accept",
    "nudge",
    "plant-name",
    "promise-set",
    "react",
  ]);
});

Deno.test("push を送る Function の index.ts は、users の読み出しに USER_COLUMNS / PARTNER_SELECT / toSnapshotUser を使う(push_env の読み忘れ防止)", async () => {
  for (const fn of await pushingFunctions()) {
    const index = await read(`${fn}/index.ts`);
    assert(
      index.includes(".select(USER_COLUMNS)"),
      `${fn}: getUser が USER_COLUMNS で読んでいない`,
    );
    assert(
      index.includes(".select(PARTNER_SELECT)"),
      `${fn}: getActivePair が PARTNER_SELECT で読んでいない`,
    );
    assert(
      index.includes("toSnapshotUser("),
      `${fn}: toSnapshotUser で行を変換していない`,
    );
    // push_token だけを読む select を直書きしない(push_env が抜ける)
    assert(
      !/\.select\("[^"]*push_token[^"]*"\)/.test(index),
      `${fn}: push_token を直書きの select で読んでいる(push_env が抜ける)`,
    );
  }
});

Deno.test("送信のたびの逆引き(push_token から push_env を引く)が戻っていない", async () => {
  for (const file of ["_shared/apns.ts", "_shared/pusher.ts"]) {
    const src = await read(file);
    assert(
      !src.includes("getPushEnv"),
      `${file} に getPushEnv(送信のたびの逆引き)が残っている`,
    );
    // コメントを除いたコードに、push_env の select が無い
    const code = src.split("\n").filter((l) =>
      !l.trim().startsWith("//") && !l.trim().startsWith("*")
    ).join("\n");
    assert(
      !/select\(["']push_env["']\)/.test(code),
      `${file} が push_env を select している`,
    );
  }
});

Deno.test("push を送る各 core.ts は、送信に sendOptionsFor(受信者の push_env)を使う", async () => {
  for (const fn of await pushingFunctions()) {
    const core = await read(`${fn}/core.ts`);
    const sends = core.match(/pusher\.send\(/g) ?? [];
    assert(sends.length >= 1, `${fn}/core.ts に pusher.send が無い`);
    const withOptions = core.match(/sendOptionsFor\(/g) ?? [];
    assert(
      withOptions.length >= sends.length,
      `${fn}/core.ts: pusher.send が ${sends.length} 回あるのに sendOptionsFor が ${withOptions.length} 回(environment を渡していない送信がある)`,
    );
  }
});
