// state.ts — 通しテストが本番に作ったデータの ID の記録(後片付けの入力)
//
// 記録するのは ID だけ(ユーザー・ペア・Storage のパス)。JWT・refresh token・キーは書かない。
// 作った直後に毎回保存するので、途中で失敗・中断しても、そこまでに作ったものは後片付けできる。
// 置き場所は既定で ${TMPDIR:-/tmp}/lien-e2e/(リポジトリの外。E2E_STATE_DIR で変えられる)。

export interface RunStateData {
  version: 1;
  ref: string;
  startedAt: string;
  /** JST の日付(この日付でチェックインを作った) */
  today: string;
  /** ラベル(A / B / C)→ auth.users.id */
  users: Record<string, string>;
  pairId: string | null;
  /** photos バケットに置いたオブジェクトのパス */
  storagePaths: string[];
  cleanedAt: string | null;
}

export class StateStore {
  readonly data: RunStateData;

  constructor(
    readonly file: string,
    init: Omit<
      RunStateData,
      "version" | "users" | "pairId" | "storagePaths" | "cleanedAt"
    >,
  ) {
    this.data = {
      version: 1,
      ...init,
      users: {},
      pairId: null,
      storagePaths: [],
      cleanedAt: null,
    };
  }

  async save(): Promise<void> {
    const tmp = `${this.file}.tmp`;
    await Deno.writeTextFile(tmp, JSON.stringify(this.data, null, 2) + "\n");
    await Deno.rename(tmp, this.file);
  }

  async addUser(label: string, id: string): Promise<void> {
    this.data.users[label] = id;
    await this.save();
  }

  async setPair(pairId: string): Promise<void> {
    this.data.pairId = pairId;
    await this.save();
  }

  async addStoragePath(path: string): Promise<void> {
    if (!this.data.storagePaths.includes(path)) {
      this.data.storagePaths.push(path);
      await this.save();
    }
  }

  async markCleaned(at: string): Promise<void> {
    this.data.cleanedAt = at;
    await this.save();
  }
}

export function isRunStateData(v: unknown): v is RunStateData {
  if (!v || typeof v !== "object") return false;
  const o = v as Record<string, unknown>;
  return o.version === 1 && typeof o.ref === "string" &&
    typeof o.users === "object" && o.users !== null &&
    Array.isArray(o.storagePaths);
}

export async function readState(file: string): Promise<RunStateData> {
  const parsed = JSON.parse(await Deno.readTextFile(file));
  if (!isRunStateData(parsed)) {
    throw new Error(`状態ファイルの形式が違う: ${file}`);
  }
  return parsed;
}

/** 状態ファイルのうち一番新しいもの(ファイル名の先頭が時刻なので、名前順の最後) */
export async function latestStateFile(dir: string): Promise<string | null> {
  const names: string[] = [];
  try {
    for await (const e of Deno.readDir(dir)) {
      if (e.isFile && /^run-.*\.json$/.test(e.name)) names.push(e.name);
    }
  } catch {
    return null;
  }
  if (names.length === 0) return null;
  names.sort();
  return `${dir.replace(/\/+$/, "")}/${names[names.length - 1]}`;
}
