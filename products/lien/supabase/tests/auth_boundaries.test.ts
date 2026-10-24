// auth_boundaries.test.ts — migrations の RLS を使う合成データ認可試験。
//
// 目的: 別ペア・未認証・削除済み利用者に、約束・履歴・写真などの実データが
//       返らないことを、アプリのコードではなく DB の RLS で確認する。
//
// 隔離方法:
//   * Supabase Auth / Storage のローカルサービスは使わない。Postgres の RLS 自体を
//     PGlite(WASM の PostgreSQL)上で実行する。外部の Supabase・本番 DB には接続しない。
//   * auth.users / auth.uid() / storage.foldername() など Supabase が用意する部分だけを
//     テスト内で最小限に模擬する。RLS ポリシーと migration はリポジトリの実物を使う。
//   * 利用者はすべて合成 UUID。実在の利用者・認証情報・本番データは使わない。
//
// 実行: リポジトリ根から
//   deno test --allow-read --allow-net products/lien/supabase/tests/
//   (PGlite を npm から取得するため --allow-net が要る)
//
// 限界(未実施)は tests/README.md に記録する。とくに Storage API 本体・GoTrue の
// JWT 期限切れ・マネージド Supabase の実バージョンはこのテストの対象外。

import { PGlite } from "npm:@electric-sql/pglite@0.5.10";

type Role = "authenticated" | "anon";
type Row = Record<string, unknown>;

function assertEquals(actual: unknown, expected: unknown, label: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${label}: actual=${a} expected=${e}`);
}

function assert(condition: boolean, label: string): void {
  if (!condition) throw new Error(label);
}

const ids = {
  a: "11111111-1111-4111-8111-111111111111",
  b: "22222222-2222-4222-8222-222222222222",
  c: "33333333-3333-4333-8333-333333333333",
  d: "44444444-4444-4444-8444-444444444444",
  e: "55555555-5555-4555-8555-555555555555",
  pairAB: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  pairCD: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  pairDE: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
};

/** 1 リクエスト相当のトランザクションで、指定ロール・JWT subject として実行する。 */
async function executeAs<T>(
  db: PGlite,
  role: Role,
  userId: string | null,
  action: () => Promise<T>,
): Promise<T> {
  await db.exec("begin");
  try {
    await db.exec(`set local role ${role}`);
    // Supabase の auth.uid() は JWT の sub を返す。ここでは同じ値を GUC に入れて模擬する。
    await db.query("select set_config('request.jwt.claim.sub', $1, true)", [
      userId ?? "",
    ]);
    return await action();
  } finally {
    await db.exec("rollback");
  }
}

async function rowsAs(
  db: PGlite,
  role: Role,
  userId: string | null,
  sql: string,
  params: unknown[] = [],
): Promise<Row[]> {
  return await executeAs(
    db,
    role,
    userId,
    async () => (await db.query<Row>(sql, params)).rows,
  );
}

/** 指定ロールで SQL が SQLSTATE 付きで拒否されることを確かめる（「何か失敗した」では通さない）。 */
async function assertRejectedCode(
  db: PGlite,
  role: Role,
  userId: string | null,
  sql: string,
  params: unknown[],
  expectedCode: string,
  label: string,
): Promise<void> {
  try {
    await rowsAs(db, role, userId, sql, params);
  } catch (error) {
    const code = (error as { code?: string }).code;
    assert(
      code === expectedCode,
      `${label}: SQLSTATE ${expectedCode} を期待したが ${code ?? "なし"} (${
        String(error)
      })`,
    );
    return;
  }
  throw new Error(`${label}: 拒否されず成功した`);
}

Deno.test("RLS boundary matrix: separate pair, unauthenticated, dissolved pair, and deleted user", async (t) => {
  const db = new PGlite();
  try {
    // ---- Supabase が提供するスキーマの最小モック -------------------------
    await db.exec(`
      create role anon;
      create role authenticated;
      create role service_role bypassrls;
      create schema auth;
      create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      create schema storage;
      create table storage.buckets (id text primary key, name text, public boolean);
      create table storage.objects (
        id uuid primary key default gen_random_uuid(),
        bucket_id text not null,
        name text not null
      );
      create function storage.foldername(p_name text) returns text[]
        language sql immutable as $$
          select (string_to_array(p_name, '/'))[1:array_length(string_to_array(p_name, '/'), 1) - 1]
        $$;
      create function storage.filename(p_name text) returns text
        language sql immutable as $$ select regexp_replace(p_name, '^.*/', '') $$;
    `);

    // ---- リポジトリの migration をそのまま適用 --------------------------
    for (
      const filename of [
        "0001_init.sql",
        "0002_photo_storage_policies.sql",
        "0004_photo_path_per_user.sql",
      ]
    ) {
      let sql = await Deno.readTextFile(
        new URL(`../migrations/${filename}`, import.meta.url),
      );
      if (filename === "0001_init.sql") {
        // PGlite には pgcrypto が無い。gen_random_uuid は PostgreSQL 18 の組み込み関数を使う。
        sql = sql.replace(
          "create extension if not exists pgcrypto;",
          "-- pgcrypto is unavailable in PGlite; PostgreSQL 18 provides gen_random_uuid",
        );
      }
      await db.exec(sql);
    }

    // ---- クライアント権限と合成データ -----------------------------------
    // 本番の Storage は authenticated に storage.objects の CRUD を許し、RLS で制限する。
    // public テーブルは migration 0001 が SELECT と users の列限定 UPDATE だけを GRANT している。
    // helper 関数の EXECUTE は migration 0001 / 0004 の GRANT に任せる（ここで一括付与しない）。
    await db.exec(`
      grant usage on schema public, storage to authenticated;
      grant select, insert, update, delete on storage.objects to authenticated;
      alter table storage.objects enable row level security;

      insert into auth.users(id) values
        ('${ids.a}'), ('${ids.b}'), ('${ids.c}'), ('${ids.d}'), ('${ids.e}');
      update public.users set nickname = 'test-a' where id = '${ids.a}';
      update public.users set nickname = 'test-b' where id = '${ids.b}';
      update public.users set nickname = 'test-c' where id = '${ids.c}';
      update public.users set nickname = 'test-d' where id = '${ids.d}';
      update public.users set nickname = 'test-e' where id = '${ids.e}';

      -- AB と CD は現役、DE は解消済みから始める(あとで削除済み利用者の試験用に現役へ戻す)。
      insert into public.pairs(id, status, started_on, dissolved_at) values
        ('${ids.pairAB}', 'active', '2026-06-05', null),
        ('${ids.pairCD}', 'active', '2026-06-01', null),
        ('${ids.pairDE}', 'dissolved', '2026-06-01', '2026-06-10T03:00:00Z');
      insert into public.pair_members(pair_id, user_id) values
        ('${ids.pairAB}', '${ids.a}'), ('${ids.pairAB}', '${ids.b}'),
        ('${ids.pairCD}', '${ids.c}'), ('${ids.pairCD}', '${ids.d}'),
        ('${ids.pairDE}', '${ids.d}'), ('${ids.pairDE}', '${ids.e}');

      insert into public.promises(user_id, title, emoji) values
        ('${ids.a}', 'synthetic promise A', 'A'),
        ('${ids.b}', 'synthetic promise B', 'B'),
        ('${ids.c}', 'synthetic promise C', 'C'),
        ('${ids.d}', 'synthetic promise D', 'D'),
        ('${ids.e}', 'synthetic promise E', 'E');

      insert into public.checkins(promise_id, user_id, date_local)
      select p.id, p.user_id, v.date_local::date
        from public.promises p
        cross join (values ('2026-06-04'), ('2026-06-05')) as v(date_local)
       where p.user_id in ('${ids.a}', '${ids.b}', '${ids.c}', '${ids.d}', '${ids.e}');

      -- 別ペア AB のリアクション。C からは見えてはいけない。
      insert into public.reactions(checkin_id, from_user, stamp)
      select c.id, '${ids.b}', 'heart'
        from public.checkins c
       where c.user_id = '${ids.a}' and c.date_local = '2026-06-05';

      -- ペアスコープの資源。C からは CD の分だけ見える。
      insert into public.streak_days(pair_id, date_local, kind) values
        ('${ids.pairAB}', '2026-06-05', 'both'),
        ('${ids.pairCD}', '2026-06-05', 'both'),
        ('${ids.pairDE}', '2026-06-05', 'both');
      insert into public.ticket_ledger(pair_id, delta, reason, date_local) values
        ('${ids.pairAB}', 2, 'monthly', '2026-06-01'),
        ('${ids.pairCD}', 2, 'monthly', '2026-06-01'),
        ('${ids.pairDE}', 2, 'monthly', '2026-06-01');
      insert into public.nudges(pair_id, from_user, stamp) values
        ('${ids.pairAB}', '${ids.a}', 'poke'),
        ('${ids.pairCD}', '${ids.c}', 'poke'),
        ('${ids.pairDE}', '${ids.d}', 'poke');
      insert into public.plants(pair_id, species, name) values
        ('${ids.pairAB}', 'seed', 'ab'),
        ('${ids.pairCD}', 'seed', 'cd'),
        ('${ids.pairDE}', 'seed', 'de');
      insert into public.invites(token, from_user, expires_at) values
        ('AAAA1111', '${ids.a}', '2026-07-01T00:00:00Z'),
        ('CCCC3333', '${ids.c}', '2026-07-01T00:00:00Z');

      -- 写真はすべてのペアに置く。C からは CD の 2 枚だけ見える。
      insert into storage.objects(bucket_id, name) values
        ('photos', 'pairs/${ids.pairAB}/2026-06-05/${ids.a}/photo.jpg'),
        ('photos', 'pairs/${ids.pairAB}/2026-06-05/${ids.b}/photo.jpg'),
        ('photos', 'pairs/${ids.pairCD}/2026-06-05/${ids.c}/photo.jpg'),
        ('photos', 'pairs/${ids.pairCD}/2026-06-05/${ids.d}/photo.jpg'),
        ('photos', 'pairs/${ids.pairDE}/2026-06-05/${ids.d}/photo.jpg'),
        ('photos', 'pairs/${ids.pairDE}/2026-06-05/${ids.e}/photo.jpg');
    `);

    // ==== ① 別ペア: C は AB のデータを 1 行も取得できない ==================
    await t.step(
      "別ペアの約束・履歴・リアクション・写真は返らない",
      async () => {
        const seen = await executeAs(db, "authenticated", ids.c, async () => ({
          users:
            (await db.query<Row>("select id from public.users order by id"))
              .rows.map((r) => r.id),
          pairs:
            (await db.query<Row>("select id from public.pairs order by id"))
              .rows.map((r) => r.id),
          pairMembers: (await db.query<Row>(
            "select user_id from public.pair_members order by user_id",
          )).rows.map((r) => r.user_id),
          promises: (await db.query<Row>(
            "select user_id from public.promises order by user_id",
          )).rows.map((r) => r.user_id),
          checkins: (await db.query<Row>(
            "select user_id from public.checkins order by user_id, date_local",
          )).rows.map((r) => r.user_id),
          reactions: (await db.query<Row>(
            "select from_user from public.reactions order by from_user",
          )).rows.map((r) => r.from_user),
          streakDays: (await db.query<Row>(
            "select pair_id from public.streak_days order by pair_id",
          )).rows.map((r) => r.pair_id),
          tickets: (await db.query<Row>(
            "select pair_id from public.ticket_ledger order by pair_id",
          )).rows.map((r) => r.pair_id),
          nudges: (await db.query<Row>(
            "select pair_id from public.nudges order by pair_id",
          )).rows.map((r) => r.pair_id),
          plants: (await db.query<Row>(
            "select pair_id from public.plants order by pair_id",
          )).rows.map((r) => r.pair_id),
          invites: (await db.query<Row>(
            "select token from public.invites order by token",
          )).rows.map((r) => r.token),
          photos: (await db.query<Row>(
            "select name from storage.objects order by name",
          )).rows.map((r) => r.name),
        }));

        assertEquals(seen.users, [ids.c], "users は自分のプロフィール行だけ");
        assertEquals(seen.pairs, [ids.pairCD], "pairs は自分の現役ペアだけ");
        assertEquals(
          seen.pairMembers,
          [ids.c, ids.d],
          "pair_members は自分のペアの2行だけ",
        );
        assertEquals(
          seen.promises,
          [ids.c, ids.d],
          "promises は現役ペアの2人分だけ",
        );
        assertEquals(
          seen.checkins,
          [ids.c, ids.c, ids.d, ids.d],
          "checkins は現役ペアの2人分だけ",
        );
        assertEquals(seen.reactions, [], "別ペア AB のリアクションは返らない");
        assertEquals(
          seen.streakDays,
          [ids.pairCD],
          "streak_days は自分のペアだけ",
        );
        assertEquals(
          seen.tickets,
          [ids.pairCD],
          "ticket_ledger は自分のペアだけ",
        );
        assertEquals(seen.nudges, [ids.pairCD], "nudges は自分のペアだけ");
        assertEquals(seen.plants, [ids.pairCD], "plants は自分のペアだけ");
        assertEquals(
          seen.invites,
          ["CCCC3333"],
          "invites は自分が発行した分だけ",
        );
        assertEquals(
          seen.photos,
          [
            `pairs/${ids.pairCD}/2026-06-05/${ids.c}/photo.jpg`,
            `pairs/${ids.pairCD}/2026-06-05/${ids.d}/photo.jpg`,
          ],
          "storage.objects は自分のペアの写真だけ",
        );
      },
    );

    // ==== 対照: 現役ペア内の相手データは読める(拒否しすぎていない) ======
    await t.step("現役ペア内の相手リアクションは読める（対照）", async () => {
      await db.query(
        `insert into public.reactions(checkin_id, from_user, stamp)
         select c.id, $1, 'clap' from public.checkins c
          where c.user_id = $2 and c.date_local = '2026-06-05'`,
        [ids.d, ids.c],
      );
      const reactions = await rowsAs(
        db,
        "authenticated",
        ids.c,
        "select from_user from public.reactions order by from_user",
      );
      assertEquals(
        reactions.map((r) => r.from_user),
        [ids.d],
        "現役ペアの相手リアクションは読める",
      );
      // 削除済み利用者の試験に持ち越さない(反応の可視範囲は送り手単位のため)。
      await db.query("delete from public.reactions where from_user = $1", [
        ids.d,
      ]);
    });

    // ==== 既知の欠陥 #151: 別ペア宛リアクション行の可視（修正後に有効化） ====
    await t.step({
      name:
        "既知の欠陥 #151: 現役ペアの相手が別ペア宛に送ったリアクション行は返らない",
      ignore: true,
      fn: async () => {
        // 修正前は C から D の「E のチェックインへのリアクション」行が見える。
        // DE は解消済みのままでよい（D の過去のリアクション行は残る）。
        // https://github.com/Ryoki63/Challenge/issues/151
        await db.query(
          `insert into public.reactions(checkin_id, from_user, stamp)
           select c.id, $1, 'clap' from public.checkins c
            where c.user_id = $2 and c.date_local = '2026-06-05'`,
          [ids.d, ids.e],
        );
        const leaked = await rowsAs(
          db,
          "authenticated",
          ids.c,
          "select checkin_id, from_user, stamp from public.reactions",
        );
        assertEquals(leaked, [], "別ペア宛のリアクション行は返らない");
        await db.query("delete from public.reactions where from_user = $1", [
          ids.d,
        ]);
      },
    });

    // ==== ② 未認証: anon は GRANT でも RLS でも拒否される =================
    await t.step("未認証ロールは GRANT でも RLS でも拒否される", async () => {
      const tables = [
        "public.users",
        "public.pairs",
        "public.pair_members",
        "public.promises",
        "public.checkins",
        "public.streak_days",
        "public.ticket_ledger",
        "public.nudges",
        "public.reactions",
        "public.plants",
        "public.invites",
        "storage.objects",
      ];
      for (const table of tables) {
        await assertRejectedCode(
          db,
          "anon",
          null,
          `select * from ${table} limit 1`,
          [],
          "42501",
          `未認証ロールの ${table} SELECT`,
        );
      }

      // 未認証の書き込みも GRANT で拒否される（Storage 含む）。
      await assertRejectedCode(
        db,
        "anon",
        null,
        "insert into public.promises(user_id, title, emoji) values ($1, 'x', 'x')",
        [ids.c],
        "42501",
        "未認証の promises INSERT",
      );
      await assertRejectedCode(
        db,
        "anon",
        null,
        "insert into storage.objects(bucket_id, name) values ('photos', $1)",
        [`pairs/${ids.pairAB}/2026-06-05/${ids.a}/photo.jpg`],
        "42501",
        "未認証の写真 INSERT",
      );

      // 本番の default privileges で anon に SELECT が付いた場合を模擬する。
      // anon 向けの RLS ポリシーは 1 つも無いため、GRANT があっても 0 行になる。
      await db.exec(`
        grant usage on schema public, storage to anon;
        grant select on table
          public.users, public.pairs, public.pair_members, public.promises,
          public.checkins, public.streak_days, public.ticket_ledger,
          public.nudges, public.reactions, public.plants, public.invites
        to anon;
        grant select on storage.objects to anon;
      `);
      for (const table of tables) {
        const rows = await rowsAs(
          db,
          "anon",
          null,
          `select * from ${table} limit 1`,
        );
        assertEquals(
          rows.length,
          0,
          `${table} は GRANT があっても RLS で 0 行`,
        );
      }
      await db.exec(`
        revoke all on table
          public.users, public.pairs, public.pair_members, public.promises,
          public.checkins, public.streak_days, public.ticket_ledger,
          public.nudges, public.reactions, public.plants, public.invites
        from anon;
        revoke all on table storage.objects from anon;
        revoke usage on schema public, storage from anon;
      `);
    });

    // ==== 書き込み境界: 他者データを変更できない =========================
    await t.step("書き込み境界: 他者データを変更できない", async () => {
      // public テーブルは SELECT 以外の GRANT が無い（users の列限定 UPDATE を除く）。
      await assertRejectedCode(
        db,
        "authenticated",
        ids.c,
        "insert into public.promises(user_id, title, emoji) values ($1, 'x', 'x')",
        [ids.c],
        "42501",
        "promises INSERT は GRANT で拒否（自分の ID でも）",
      );
      await assertRejectedCode(
        db,
        "authenticated",
        ids.c,
        "update public.users set premium_until = '2099-01-01' where id = $1",
        [ids.c],
        "42501",
        "premium_until の自己更新は列 GRANT で拒否",
      );
      await assertRejectedCode(
        db,
        "authenticated",
        ids.c,
        "delete from public.checkins where user_id = $1",
        [ids.a],
        "42501",
        "他者の checkins DELETE",
      );
      await assertRejectedCode(
        db,
        "authenticated",
        ids.c,
        `insert into public.reactions(checkin_id, from_user, stamp)
         select c.id, $1, 'x' from public.checkins c
          where c.user_id = $2 and c.date_local = '2026-06-05'`,
        [ids.c, ids.a],
        "42501",
        "他者の checkin への reactions INSERT",
      );

      // users は自分の行だけ UPDATE できる（他者の行は 0 行で不変）。
      const ownProfile = await executeAs(
        db,
        "authenticated",
        ids.c,
        async () =>
          await db.query(
            "update public.users set nickname = 'test-c2' where id = $1",
            [
              ids.c,
            ],
          ),
      );
      assertEquals(
        ownProfile.affectedRows,
        1,
        "自分のプロフィールは更新できる",
      );
      const otherProfile = await executeAs(
        db,
        "authenticated",
        ids.c,
        async () =>
          await db.query(
            "update public.users set nickname = 'hacked' where id = $1",
            [ids.a],
          ),
      );
      assertEquals(
        otherProfile.affectedRows,
        0,
        "他者のプロフィールは更新できない",
      );
      await db.query(
        "update public.users set nickname = 'test-c' where id = $1",
        [
          ids.c,
        ],
      );

      // Storage は INSERT/UPDATE の GRANT があっても、0004 のパス規約が他者区画・別ペアを拒否する。
      const cPhoto = `pairs/${ids.pairCD}/2026-06-05/${ids.c}/photo.jpg`;
      const dPhoto = `pairs/${ids.pairCD}/2026-06-05/${ids.d}/photo.jpg`;
      await assertRejectedCode(
        db,
        "authenticated",
        ids.c,
        "insert into storage.objects(bucket_id, name) values ('photos', $1)",
        [`pairs/${ids.pairAB}/2026-06-05/${ids.c}/photo.jpg`],
        "42501",
        "別ペアの写真 INSERT",
      );
      await assertRejectedCode(
        db,
        "authenticated",
        ids.c,
        "insert into storage.objects(bucket_id, name) values ('photos', $1)",
        [dPhoto],
        "42501",
        "同じペアでも相手区画への写真 INSERT",
      );
      await assertRejectedCode(
        db,
        "authenticated",
        ids.c,
        "update storage.objects set name = $1 where name = $2",
        [dPhoto, cPhoto],
        "42501",
        "自分の写真を相手区画へ UPDATE",
      );
      const updatePartnerPhoto = await executeAs(
        db,
        "authenticated",
        ids.c,
        async () =>
          await db.query(
            "update storage.objects set name = name where name = $1",
            [
              dPhoto,
            ],
          ),
      );
      assertEquals(
        updatePartnerPhoto.affectedRows,
        0,
        "相手区画の写真は UPDATE の USING で 0 行",
      );
      await assertRejectedCode(
        db,
        "authenticated",
        ids.c,
        "insert into storage.objects(bucket_id, name) values ('photos', $1)",
        [`pairs/${ids.pairCD}/2026-06-06/photo.jpg`],
        "42501",
        "旧形式（user 区画なし）の写真 INSERT",
      );
      const deleteOwn = await executeAs(
        db,
        "authenticated",
        ids.c,
        async () => {
          const deleted = await db.query(
            "delete from storage.objects where name = $1",
            [cPhoto],
          );
          const after = await db.query<{ n: number }>(
            "select count(*)::int as n from storage.objects where name = $1",
            [cPhoto],
          );
          return {
            affectedRows: deleted.affectedRows,
            remaining: Number(after.rows[0].n),
          };
        },
      );
      assertEquals(
        deleteOwn.affectedRows,
        0,
        "クライアントからの写真 DELETE は 0 行",
      );
      assertEquals(
        deleteOwn.remaining,
        1,
        "写真は同一トランザクション内でも削除されていない",
      );

      // 自分の区画・正しいファイル名なら INSERT できる（拒否しすぎていない対照）。
      const ownPhoto =
        `pairs/${ids.pairCD}/2026-06-06/${ids.c}/photo_thumb.jpg`;
      const insertOwn = await executeAs(
        db,
        "authenticated",
        ids.c,
        async () =>
          await db.query(
            "insert into storage.objects(bucket_id, name) values ('photos', $1)",
            [ownPhoto],
          ),
      );
      assertEquals(
        insertOwn.affectedRows,
        1,
        "自分の区画への写真 INSERT はできる",
      );
      await db.query("delete from storage.objects where name = $1", [ownPhoto]);
    });

    // ==== ③ ペア解消: 元相手のデータと共有写真は返らない ==================
    await t.step("ペア解消後は元相手のデータと写真が返らない", async () => {
      await db.query(
        "update public.pairs set status = 'dissolved', dissolved_at = $2 where id = $1",
        [ids.pairAB, "2026-06-10T03:00:00Z"],
      );
      const seen = await executeAs(db, "authenticated", ids.b, async () => ({
        users: (await db.query<Row>("select id from public.users order by id"))
          .rows.map((r) => r.id),
        pairs: (await db.query<Row>("select id from public.pairs order by id"))
          .rows.map((r) => r.id),
        pairMembers: (await db.query<Row>(
          "select user_id from public.pair_members order by user_id",
        )).rows.map((r) => r.user_id),
        promises: (await db.query<Row>(
          "select user_id from public.promises order by user_id",
        )).rows.map((r) => r.user_id),
        checkins: (await db.query<Row>(
          "select user_id from public.checkins order by user_id",
        )).rows.map((r) => r.user_id),
        reactions: (await db.query<Row>(
          "select from_user from public.reactions order by from_user",
        )).rows.map((r) => r.from_user),
        streakDays: (await db.query<Row>(
          "select pair_id from public.streak_days order by pair_id",
        )).rows.map((r) => r.pair_id),
        tickets: (await db.query<Row>(
          "select pair_id from public.ticket_ledger order by pair_id",
        )).rows.map((r) => r.pair_id),
        nudges: (await db.query<Row>(
          "select pair_id from public.nudges order by pair_id",
        )).rows.map((r) => r.pair_id),
        plants: (await db.query<Row>(
          "select pair_id from public.plants order by pair_id",
        )).rows.map((r) => r.pair_id),
        invites: (await db.query<Row>(
          "select token from public.invites order by token",
        )).rows.map((r) => r.token),
        photos: (await db.query<Row>(
          "select name from storage.objects order by name",
        )).rows.map((r) => r.name),
      }));

      assertEquals(seen.users, [ids.b], "解消後も users は自分だけ");
      assertEquals(
        seen.pairs,
        [ids.pairAB],
        "pairs はアーカイブとして自分のペアだけ",
      );
      assertEquals(
        seen.pairMembers,
        [ids.a, ids.b],
        "pair_members は解消済みペアのアーカイブとして2行",
      );
      assertEquals(seen.promises, [ids.b], "解消後は本人の約束だけ");
      assertEquals(seen.checkins, [ids.b, ids.b], "解消後は本人の履歴だけ");
      assertEquals(
        seen.reactions,
        [ids.b],
        "解消後も本人が送ったリアクションだけ",
      );
      assertEquals(
        seen.streakDays,
        [ids.pairAB],
        "streak_days はアーカイブで残る",
      );
      assertEquals(
        seen.tickets,
        [ids.pairAB],
        "ticket_ledger はアーカイブで残る",
      );
      assertEquals(seen.nudges, [ids.pairAB], "nudges はアーカイブで残る");
      assertEquals(seen.plants, [ids.pairAB], "plants はアーカイブで残る");
      assertEquals(
        seen.invites,
        [],
        "invites は自分が発行した分だけ（B は0件）",
      );
      assertEquals(seen.photos, [], "解消後に共有写真は返らない");
    });

    // ==== ④ 削除済み: 残存 JWT(sub)でも他者データが返らない ===============
    await t.step(
      "削除済み利用者の stale subject にはデータが返らない",
      async () => {
        // 本番の delete-account は「現役ペアを解消 → 本人写真を削除 → auth 削除」の順。
        // この試験は RLS を確かめるため、あえて auth を先に消して写真を残す（本番順序とは異なる）。
        // その後、写真削除とペア解消を適用して元相手の視点を確認する（この2手の順序も本番とは逆）。
        await db.query(
          "update public.pairs set status = 'dissolved', dissolved_at = $2 where id = $1",
          [ids.pairCD, "2026-06-10T03:00:00Z"],
        );
        await db.query(
          "update public.pairs set status = 'active', dissolved_at = null, started_on = '2026-06-05' where id = $1",
          [ids.pairDE],
        );

        const beforeDelete = await executeAs(
          db,
          "authenticated",
          ids.e,
          async () => ({
            users:
              (await db.query<Row>("select id from public.users order by id"))
                .rows.map((r) => r.id),
            pairs:
              (await db.query<Row>("select id from public.pairs order by id"))
                .rows.map((r) => r.id),
            pairMembers: (await db.query<Row>(
              "select user_id from public.pair_members order by user_id",
            )).rows.map((r) => r.user_id),
            promises: (await db.query<Row>(
              "select user_id from public.promises order by user_id",
            )).rows.map((r) => r.user_id),
            checkins: (await db.query<Row>(
              "select user_id from public.checkins order by user_id, date_local",
            )).rows.map((r) => r.user_id),
            photos: (await db.query<Row>(
              "select name from storage.objects order by name",
            )).rows.map((r) => r.name),
          }),
        );

        assertEquals(beforeDelete.users, [ids.e], "削除前の本人プロフィール");
        assertEquals(beforeDelete.pairs, [ids.pairDE], "削除前の現役ペア");
        assertEquals(
          beforeDelete.pairMembers,
          [ids.d, ids.e],
          "削除前のペア所属",
        );
        assertEquals(
          beforeDelete.promises,
          [ids.d, ids.e],
          "削除前の現役相手の約束は通常表示",
        );
        assertEquals(
          beforeDelete.checkins,
          [ids.d, ids.e, ids.e],
          "旧ペア成立前の D の履歴は読めず、現役ペア成立後の E 履歴は読める",
        );
        assertEquals(
          beforeDelete.photos,
          [
            `pairs/${ids.pairDE}/2026-06-05/${ids.d}/photo.jpg`,
            `pairs/${ids.pairDE}/2026-06-05/${ids.e}/photo.jpg`,
          ],
          "削除前の現役ペア写真",
        );

        // auth ユーザーだけを消す(public.users 以下は ON DELETE CASCADE)。
        // 写真はあえて残し、RLS が stale subject を遮断することを確かめる。
        await db.query("delete from auth.users where id = $1", [ids.e]);
        const orphanPhotos = await db.query<{ n: number }>(
          "select count(*)::int as n from storage.objects where bucket_id = 'photos' and name like $1",
          [`pairs/${ids.pairDE}/%`],
        );
        assertEquals(
          Number(orphanPhotos.rows[0].n),
          2,
          "写真オブジェクトは残っている（RLS 検証の前提）",
        );

        const afterDelete = await executeAs(
          db,
          "authenticated",
          ids.e,
          async () => ({
            users:
              (await db.query<Row>("select id from public.users order by id"))
                .rows.map((r) => r.id),
            pairs:
              (await db.query<Row>("select id from public.pairs order by id"))
                .rows.map((r) => r.id),
            pairMembers: (await db.query<Row>(
              "select user_id from public.pair_members order by user_id",
            )).rows.map((r) => r.user_id),
            promises: (await db.query<Row>(
              "select user_id from public.promises order by user_id",
            )).rows.map((r) => r.user_id),
            checkins: (await db.query<Row>(
              "select user_id from public.checkins order by user_id",
            )).rows.map((r) => r.user_id),
            reactions: (await db.query<Row>(
              "select from_user from public.reactions order by from_user",
            )).rows.map((r) => r.from_user),
            photos: (await db.query<Row>(
              "select name from storage.objects order by name",
            )).rows.map((r) => r.name),
          }),
        );

        assertEquals(afterDelete, {
          users: [],
          pairs: [],
          pairMembers: [],
          promises: [],
          checkins: [],
          reactions: [],
          photos: [],
        }, "削除済み利用者にデータが返らない");

        // 本人写真の削除とペア解消を適用する（この2手の順序も本番とは逆）。
        await db.query(
          "delete from storage.objects where bucket_id = 'photos' and name like $1",
          [`pairs/${ids.pairDE}/%/${ids.e}/%`],
        );
        await db.query(
          "update public.pairs set status = 'dissolved', dissolved_at = $2 where id = $1",
          [ids.pairDE, "2026-06-10T03:00:00Z"],
        );

        const partnerAfterDelete = await executeAs(
          db,
          "authenticated",
          ids.d,
          async () => ({
            users:
              (await db.query<Row>("select id from public.users order by id"))
                .rows.map((r) => r.id),
            promises: (await db.query<Row>(
              "select user_id from public.promises order by user_id",
            )).rows.map((r) => r.user_id),
            checkins: (await db.query<Row>(
              "select user_id from public.checkins order by user_id",
            )).rows.map((r) => r.user_id),
            photos: (await db.query<Row>(
              "select name from storage.objects order by name",
            )).rows.map((r) => r.name),
          }),
        );

        assertEquals(
          partnerAfterDelete.users,
          [ids.d],
          "削除後の元相手は自分のプロフィールだけ",
        );
        assertEquals(
          partnerAfterDelete.promises,
          [ids.d],
          "削除後の元相手は自分の約束だけ",
        );
        assertEquals(
          partnerAfterDelete.checkins,
          [ids.d, ids.d],
          "削除後の元相手は自分の履歴だけ",
        );
        assertEquals(
          partnerAfterDelete.photos,
          [],
          "削除対象の写真は削除後に返らない",
        );
      },
    );
  } finally {
    await db.close();
  }
});
