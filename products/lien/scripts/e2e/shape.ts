// shape.ts — 契約フィクスチャとの「形(キー・型)」の突き合わせ。純粋関数(ネットワーク・ファイル不要)
//
// products/lien/contracts/*.json はサーバーの実ハンドラを固定入力で走らせた応答。iOS は同じ JSON を
// LienTests でデコードして、アプリが本番で使うモデルで復元できることを検査している。
// 本番の実応答がフィクスチャと形(キー・型)で一致するかを見れば、「CI は緑なのに本番で通らない」を
// 応答の形のずれとして検出できる(docs/REVIEW-2026-10-12.md §2・§4.1)。
//
// 方針:
//   - 値ではなく形を見る(updatedAt や UUID は実行のたびに違う)。形とは、キーの集合と各値の JSON 型
//   - フィクスチャが 1 つの標本にすぎない点を補うため、同じ応答系統の複数のフィクスチャを合成した
//     スキーマで見る(例: snapshot の pairId はペアで string、ソロで null → string | null)。
//     標本の一部にしか無いキーは任意(optional)になる(例: checkin の photoUpload)
//   - 数値は、標本がすべて整数なら整数であることも見る(Swift の Int でデコードできない小数を検出)
//   - 値まで見たい決定的な状態(新規ユーザーの snapshot など)は diffValues で別に比べる

export type JsonType =
  | "null"
  | "string"
  | "number"
  | "boolean"
  | "array"
  | "object"
  | "undefined";

export function jsonType(v: unknown): JsonType {
  if (v === null) return "null";
  if (v === undefined) return "undefined";
  if (Array.isArray(v)) return "array";
  switch (typeof v) {
    case "string":
      return "string";
    case "number":
      return "number";
    case "boolean":
      return "boolean";
    case "object":
      return "object";
    default:
      return "undefined"; // function / symbol / bigint は JSON に現れない
  }
}

export interface PropSchema {
  schema: Schema;
  /** 標本の一部にしか無いキー(無くてもずれにしない) */
  optional: boolean;
}

export interface Schema {
  types: Set<JsonType>;
  /** number の標本がすべて整数か(number を含まないスキーマでは true のまま) */
  integerOnly: boolean;
  props?: Map<string, PropSchema>;
  items?: Schema;
}

/** 1 つの値から形を取り出す */
export function inferSchema(v: unknown): Schema {
  const t = jsonType(v);
  const schema: Schema = {
    types: new Set<JsonType>([t]),
    integerOnly: t === "number" ? Number.isInteger(v) : true,
  };
  if (t === "object") {
    schema.props = new Map();
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      schema.props.set(k, { schema: inferSchema(val), optional: false });
    }
  } else if (t === "array") {
    const arr = v as unknown[];
    if (arr.length > 0) {
      schema.items = arr.map(inferSchema).reduce(mergeSchemas);
    }
  }
  return schema;
}

/** 2 つの形を合成する(型は和集合、片方にしか無いキーは任意) */
export function mergeSchemas(a: Schema, b: Schema): Schema {
  const out: Schema = {
    types: new Set<JsonType>([...a.types, ...b.types]),
    integerOnly: a.integerOnly && b.integerOnly,
  };
  if (a.props || b.props) {
    out.props = new Map();
    const keys = new Set<string>([
      ...(a.props?.keys() ?? []),
      ...(b.props?.keys() ?? []),
    ]);
    for (const k of keys) {
      const pa = a.props?.get(k);
      const pb = b.props?.get(k);
      if (pa && pb) {
        out.props.set(k, {
          schema: mergeSchemas(pa.schema, pb.schema),
          optional: pa.optional || pb.optional,
        });
      } else {
        const only = (pa ?? pb) as PropSchema;
        out.props.set(k, { schema: only.schema, optional: true });
      }
    }
  }
  if (a.items || b.items) {
    out.items = a.items && b.items
      ? mergeSchemas(a.items, b.items)
      : (a.items ?? b.items);
  }
  return out;
}

/** 複数の標本(同じ応答系統のフィクスチャ)から合成した形 */
export function schemaFrom(...samples: unknown[]): Schema {
  if (samples.length === 0) throw new Error("標本が 1 つも無い");
  return samples.map(inferSchema).reduce(mergeSchemas);
}

export interface Deviation {
  /** `$.snapshot.plantName` のような位置 */
  path: string;
  /** missing = フィクスチャにあるキーが無い / extra = フィクスチャに無いキーがある / type = 型が違う */
  kind: "missing" | "extra" | "type";
  expected: string;
  actual: string;
}

function describe(schema: Schema): string {
  const types = [...schema.types].join("|");
  return schema.types.has("number") && schema.integerOnly
    ? types.replace("number", "integer")
    : types;
}

export interface DiffShapeOptions {
  /** 追加で null を許す位置(例 `$.promise.remindAt`。標本が文字列だけでも、サーバーの型は string | null) */
  nullable?: readonly string[];
  /** 位置の根(既定 `$`) */
  path?: string;
}

/** 実際の値がスキーマの形に収まっているか。ずれの一覧を返す(空なら一致) */
export function diffShape(
  actual: unknown,
  schema: Schema,
  opts: DiffShapeOptions = {},
): Deviation[] {
  const out: Deviation[] = [];
  walk(actual, schema, opts.path ?? "$", new Set(opts.nullable ?? []), out);
  return out;
}

function walk(
  actual: unknown,
  schema: Schema,
  path: string,
  nullable: ReadonlySet<string>,
  out: Deviation[],
): void {
  const t = jsonType(actual);
  const allowed = new Set<JsonType>(schema.types);
  if (nullable.has(path)) allowed.add("null");
  if (!allowed.has(t)) {
    out.push({
      path,
      kind: "type",
      expected: [...allowed].join("|"),
      actual: t,
    });
    return;
  }
  if (t === "number" && schema.integerOnly && !Number.isInteger(actual)) {
    out.push({
      path,
      kind: "type",
      expected: "integer",
      actual: `number(${actual})`,
    });
  }
  if (t === "object" && schema.props) {
    const obj = actual as Record<string, unknown>;
    for (const [k, p] of schema.props) {
      if (!(k in obj)) {
        if (!p.optional) {
          out.push({
            path: `${path}.${k}`,
            kind: "missing",
            expected: describe(p.schema),
            actual: "(キーなし)",
          });
        }
        continue;
      }
      walk(obj[k], p.schema, `${path}.${k}`, nullable, out);
    }
    for (const k of Object.keys(obj)) {
      if (!schema.props.has(k)) {
        out.push({
          path: `${path}.${k}`,
          kind: "extra",
          expected: "(フィクスチャに無いキー)",
          actual: jsonType(obj[k]),
        });
      }
    }
  }
  if (t === "array" && schema.items) {
    (actual as unknown[]).forEach((el, i) =>
      walk(el, schema.items as Schema, `${path}[${i}]`, nullable, out)
    );
  }
}

export function formatDeviation(d: Deviation): string {
  switch (d.kind) {
    case "missing":
      return `${d.path}: キーが無い(フィクスチャでは ${d.expected})`;
    case "extra":
      return `${d.path}: フィクスチャに無いキーがある(${d.actual})`;
    case "type":
      return `${d.path}: 型が違う(フィクスチャ ${d.expected} / 実際 ${d.actual})`;
  }
}

// ---- 値の突き合わせ(決定的な状態用) ----

export interface ValueDeviation {
  path: string;
  expected: unknown;
  actual: unknown;
}

/**
 * 値まで一致するかを比べる。新規ユーザーの snapshot や、ペア成立直後の応答など、
 * 実行のたびに変わらない状態をフィクスチャと突き合わせる用。ignore に入れた位置は比べない
 * (updatedAt・pairId・ユーザーごとのニックネームや約束など)。
 */
export function diffValues(
  actual: unknown,
  expected: unknown,
  ignore: readonly string[] = [],
  path = "$",
): ValueDeviation[] {
  if (ignore.includes(path)) return [];
  const ta = jsonType(actual);
  const te = jsonType(expected);
  if (ta !== te) return [{ path, expected, actual }];
  if (ta === "object") {
    const a = actual as Record<string, unknown>;
    const e = expected as Record<string, unknown>;
    const out: ValueDeviation[] = [];
    for (const k of new Set([...Object.keys(a), ...Object.keys(e)])) {
      out.push(...diffValues(a[k], e[k], ignore, `${path}.${k}`));
    }
    return out;
  }
  if (ta === "array") {
    const a = actual as unknown[];
    const e = expected as unknown[];
    if (a.length !== e.length) return [{ path, expected, actual }];
    return a.flatMap((el, i) => diffValues(el, e[i], ignore, `${path}[${i}]`));
  }
  return actual === expected ? [] : [{ path, expected, actual }];
}

export function formatValueDeviation(d: ValueDeviation): string {
  return `${d.path}: フィクスチャ ${JSON.stringify(d.expected)} / 実際 ${
    JSON.stringify(d.actual)
  }`;
}

/** JSON として等しいか(キーの順序は問わない) */
export function jsonEqual(a: unknown, b: unknown): boolean {
  return diffValues(a, b).length === 0;
}
