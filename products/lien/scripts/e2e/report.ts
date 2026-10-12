// report.ts — 通しテストの結果の記録と表示
//
// 結果は 4 種類:
//   PASS  期待どおり
//   FAIL  期待と違う(終了コード 1)。契約フィクスチャとのずれ(キー・型・値)も FAIL
//   NOTE  失敗ではないが、仕様の前提や運用上、知っておくべき観測(例: APNs が未設定、取消後に写真の実体が残る)
//   SKIP  前提が満たされず確認できなかった(例: ペア外ユーザーを使わない指定)
//
// 契約フィクスチャとのずれ(deviations)は、FAIL とは別に最後へまとめて見せる。ずれが 1 件でもあれば、FAIL が 0 件でも
// 「問題あり」(hasProblems = 終了コード 1)にする。「ずれ N 件」と出ているのに結果が PASS(終了コード 0)になる、
// という食い違いを作らないため。ずれは情報として流さない。
//
// 表示にはキー・JWT を出さない(redact)。公開リポジトリの issue / ログに貼る前提で、詳細は短く保つ。

import {
  type Deviation,
  diffShape,
  diffValues,
  formatDeviation,
  formatValueDeviation,
  jsonEqual,
  type Schema,
} from "./shape.ts";

export type Level = "pass" | "fail" | "note" | "skip";

export interface Result {
  step: string;
  name: string;
  level: Level;
  detail?: string;
}

/** 前提が崩れて先へ進めないときに投げる(以降の手順を打ち切って、後片付け・集計へ進む) */
export class Abort extends Error {}

const SECRET_PATTERNS: RegExp[] = [
  /sb_secret_[A-Za-z0-9_-]+/g,
  /sb_publishable_[A-Za-z0-9_-]+/g,
  /sbp_[A-Za-z0-9]{20,}/g,
  /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/g,
];

/** 鍵・JWT の形をしたものを伏せる(エラーメッセージや応答の本文を表示する前に通す) */
export function redact(s: string): string {
  return SECRET_PATTERNS.reduce((acc, re) => acc.replace(re, "<redacted>"), s);
}

function oneLine(s: string, max = 400): string {
  const t = redact(s).replace(/\s+/g, " ").trim();
  return t.length > max ? `${t.slice(0, max)}…` : t;
}

const ICON: Record<Level, string> = {
  pass: "PASS",
  fail: "FAIL",
  note: "NOTE",
  skip: "SKIP",
};

export class Reporter {
  readonly results: Result[] = [];
  /** 契約フィクスチャとのずれ(FAIL の中から抜き出して、最後にまとめて見せる) */
  readonly deviations: string[] = [];
  /** 契約フィクスチャとの突き合わせの回数(形 / 値) */
  shapeChecks = 0;
  valueChecks = 0;
  private step = "";
  private readonly steps: Array<{ id: string; title: string }> = [];

  constructor(
    private readonly out: (line: string) => void = console.log,
    private readonly color = false,
  ) {}

  private paint(level: Level, text: string): string {
    if (!this.color) return text;
    const code = { pass: "32", fail: "31", note: "33", skip: "90" }[level];
    return `\x1b[${code}m${text}\x1b[0m`;
  }

  begin(id: string, title: string): void {
    this.step = id;
    this.steps.push({ id, title });
    this.out("");
    this.out(`[${id}] ${title}`);
  }

  private add(level: Level, name: string, detail?: string): void {
    this.results.push({ step: this.step, name, level, detail });
    this.out(`  ${this.paint(level, ICON[level])}  ${name}`);
    if (detail) this.out(`        ${oneLine(detail)}`);
  }

  pass(name: string, detail?: string): void {
    this.add("pass", name, detail);
  }

  fail(name: string, detail?: string): void {
    this.add("fail", name, detail);
  }

  note(name: string, detail?: string): void {
    this.add("note", name, detail);
  }

  skip(name: string, detail?: string): void {
    this.add("skip", name, detail);
  }

  /**
   * 契約とのずれを 1 件記録する(最後の「契約フィクスチャとのずれ」に出る)。
   * shape() / values() / expectError は、FAIL の記録と一緒にこれを呼ぶ。単独で呼んでも、
   * hasProblems が true になる(= 終了コード 1)ので、ずれを見逃したまま PASS にはならない
   */
  deviation(message: string): void {
    this.deviations.push(`[${this.step}] ${message}`);
  }

  /**
   * ok なら PASS、でなければ FAIL。detail は失敗時だけ表示する。
   * info は成功時にも見せたい観測値(拒否された応答のステータスなど)
   */
  check(name: string, ok: boolean, detail?: string, info?: string): boolean {
    if (ok) this.add("pass", name, info);
    else this.add("fail", name, detail);
    return ok;
  }

  /** JSON として等しいか */
  eq(name: string, actual: unknown, expected: unknown): boolean {
    const ok = jsonEqual(actual, expected);
    return this.check(
      name,
      ok,
      `期待 ${JSON.stringify(expected)} / 実際 ${JSON.stringify(actual)}`,
    );
  }

  /** 契約フィクスチャの形(キー・型)に収まるか。ずれは deviations にも積む */
  shape(
    name: string,
    actual: unknown,
    schema: Schema,
    nullable: readonly string[] = [],
  ): boolean {
    this.shapeChecks++;
    const devs: Deviation[] = diffShape(actual, schema, { nullable });
    if (devs.length === 0) return this.check(name, true);
    const lines = devs.map(formatDeviation);
    for (const l of lines) this.deviations.push(`[${this.step}] ${name}: ${l}`);
    return this.check(name, false, lines.join(" / "));
  }

  /** 決定的な状態の値がフィクスチャと一致するか(ignore の位置は比べない)。ずれは deviations にも積む */
  values(
    name: string,
    actual: unknown,
    expected: unknown,
    ignore: readonly string[],
  ): boolean {
    this.valueChecks++;
    const devs = diffValues(actual, expected, ignore);
    if (devs.length === 0) return this.check(name, true);
    const lines = devs.map(formatValueDeviation);
    for (const l of lines) this.deviations.push(`[${this.step}] ${name}: ${l}`);
    return this.check(name, false, lines.join(" / "));
  }

  /** 手順を実行する。予期しない例外は FAIL にして次の手順へ。Abort は集計のため上へ投げ直す */
  async run(id: string, title: string, fn: () => Promise<void>): Promise<void> {
    this.begin(id, title);
    try {
      await fn();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (e instanceof Abort) {
        this.add("fail", "中断", msg);
        throw e;
      }
      this.add("fail", "例外", msg);
    }
  }

  count(level: Level): number {
    return this.results.filter((r) => r.level === level).length;
  }

  get failed(): number {
    return this.count("fail");
  }

  /** FAIL が 1 件でもある、または契約フィクスチャとのずれが 1 件でもある(終了コードを 1 にする条件) */
  get hasProblems(): boolean {
    return this.failed > 0 || this.deviations.length > 0;
  }

  /** 手順ごとの集計と、全体の結果 */
  summaryLines(): string[] {
    const lines: string[] = [];
    lines.push("");
    lines.push("==== 集計 ====");
    for (const s of this.steps) {
      const rs = this.results.filter((r) => r.step === s.id);
      const p = rs.filter((r) => r.level === "pass").length;
      const f = rs.filter((r) => r.level === "fail").length;
      const n = rs.filter((r) => r.level === "note").length;
      const k = rs.filter((r) => r.level === "skip").length;
      const mark = f > 0 ? "FAIL" : "ok  ";
      lines.push(
        `  ${mark} ${s.id} ${s.title}  (PASS ${p} / FAIL ${f} / NOTE ${n} / SKIP ${k})`,
      );
    }
    lines.push("");
    lines.push(
      `  合計: PASS ${this.count("pass")} / FAIL ${this.count("fail")} / NOTE ${
        this.count("note")
      } / SKIP ${this.count("skip")}`,
    );
    lines.push(
      `  契約フィクスチャとの突き合わせ: 形(キー・型)${this.shapeChecks} 回 / 値 ${this.valueChecks} 回 → ずれ ${this.deviations.length} 件`,
    );
    if (this.deviations.length > 0) {
      lines.push("");
      lines.push("==== 契約フィクスチャとのずれ ====");
      for (const d of this.deviations) lines.push(`  - ${oneLine(d, 600)}`);
    }
    const notes = this.results.filter((r) => r.level === "note");
    if (notes.length > 0) {
      lines.push("");
      lines.push("==== 観測(NOTE) ====");
      for (const n of notes) {
        lines.push(
          `  - [${n.step}] ${n.name}${
            n.detail ? ` — ${oneLine(n.detail, 600)}` : ""
          }`,
        );
      }
    }
    const fails = this.results.filter((r) => r.level === "fail");
    if (fails.length > 0) {
      lines.push("");
      lines.push("==== 失敗(FAIL) ====");
      for (const f of fails) {
        lines.push(
          `  - [${f.step}] ${f.name}${
            f.detail ? ` — ${oneLine(f.detail, 600)}` : ""
          }`,
        );
      }
    }
    return lines;
  }
}
