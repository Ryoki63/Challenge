// test_util.ts — e2e の deno test が共有する小さな検査の道具(外部モジュールを使わない。scripts/ops/*_test.ts と同じ方針)
//
// ファイル名が *_test.ts ではないので、deno test の対象にはならない(テストから import されるだけ)。

/** JSON にして等しいか(キーの順序は呼び出し側でそろえる) */
export function assertEquals(
  actual: unknown,
  expected: unknown,
  msg = "",
): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed ${msg}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

/** 条件が真か */
export function assertTrue(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`assertTrue failed: ${msg}`);
}

/** 同期の関数が、includes を含むメッセージの例外を投げるか */
export function assertThrows(
  fn: () => unknown,
  includes: string,
  msg = "",
): void {
  try {
    fn();
  } catch (e) {
    const text = e instanceof Error ? e.message : String(e);
    if (!text.includes(includes)) {
      throw new Error(
        `期待したメッセージ「${includes}」が無い ${msg}: ${text}`,
      );
    }
    return;
  }
  throw new Error(`例外が出なかった ${msg}`);
}

/** 非同期の関数が、includes を含むメッセージの例外を投げるか */
export async function assertRejects(
  fn: () => Promise<unknown>,
  includes: string,
  msg = "",
): Promise<void> {
  try {
    await fn();
  } catch (e) {
    const text = e instanceof Error ? e.message : String(e);
    if (!text.includes(includes)) {
      throw new Error(
        `期待したメッセージ「${includes}」が無い ${msg}: ${text}`,
      );
    }
    return;
  }
  throw new Error(`例外が出なかった ${msg}`);
}
