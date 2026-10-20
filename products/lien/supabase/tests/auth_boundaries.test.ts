import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/pgcrypto";

const users = {
  alice: "00000000-0000-0000-0000-000000000001",
  bob: "00000000-0000-0000-0000-000000000002",
  carol: "00000000-0000-0000-0000-000000000003",
  david: "00000000-0000-0000-0000-000000000004",
  eve: "00000000-0000-0000-0000-000000000005",
};

const pairs = {
  aliceBob: "10000000-0000-0000-0000-000000000001",
  carolDavid: "10000000-0000-0000-0000-000000000002",
  davidEve: "10000000-0000-0000-0000-000000000003",
};

const checkins = {
  alice: "20000000-0000-0000-0000-000000000001",
  carol: "20000000-0000-0000-0000-000000000002",
  david: "20000000-0000-0000-0000-000000000003",
  davidBeforePair: "20000000-0000-0000-0000-000000000004",
  eve: "20000000-0000-0000-0000-000000000005",
};

type Reaction = {
  checkin_id: string;
  from_user: string;
  stamp: string;
};

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

async function createDatabase(): Promise<PGlite> {
  const database = new PGlite({ extensions: { pgcrypto } });
  try {
    await database.exec(`
      create role anon nologin;
      create role authenticated nologin;
      create role service_role nologin bypassrls;
      create schema auth;
      create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
      $$;
      grant usage on schema public, auth to anon, authenticated, service_role;
      create schema storage;
      create table storage.buckets (id text primary key, name text, public boolean);
      create table storage.objects (id uuid primary key, bucket_id text, name text);
      alter table storage.objects enable row level security;
      create function storage.foldername(name text) returns text[]
      language sql immutable as $$ select string_to_array(name, '/') $$;
    `);
    await database.exec(
      await Deno.readTextFile(
        new URL("../migrations/0001_init.sql", import.meta.url),
      ),
    );
    await database.exec(`
      insert into auth.users (id) values
        ('${users.alice}'), ('${users.bob}'), ('${users.carol}'),
        ('${users.david}'), ('${users.eve}');
      insert into public.promises (id, user_id, title, emoji)
        select id, id, 'Synthetic promise', '🌱' from auth.users;
      insert into public.pairs (id, started_on) values
        ('${pairs.aliceBob}', '2026-10-01'),
        ('${pairs.davidEve}', '2026-10-01');
      insert into public.pair_members (pair_id, user_id) values
        ('${pairs.aliceBob}', '${users.alice}'),
        ('${pairs.aliceBob}', '${users.bob}'),
        ('${pairs.davidEve}', '${users.david}'),
        ('${pairs.davidEve}', '${users.eve}');
      insert into public.checkins (id, promise_id, user_id, date_local) values
        ('${checkins.eve}', '${users.eve}', '${users.eve}', '2026-10-19'),
        ('${checkins.davidBeforePair}', '${users.david}', '${users.david}', '2026-10-19');
      insert into public.reactions (checkin_id, from_user, stamp) values
        ('${checkins.eve}', '${users.david}', 'clap'),
        ('${checkins.davidBeforePair}', '${users.eve}', 'heart');
      update public.pairs set status = 'dissolved', dissolved_at = '2026-10-20T00:00:00Z'
        where id = '${pairs.davidEve}';
      insert into public.pairs (id, started_on) values
        ('${pairs.carolDavid}', '2026-10-20');
      insert into public.pair_members (pair_id, user_id) values
        ('${pairs.carolDavid}', '${users.carol}'),
        ('${pairs.carolDavid}', '${users.david}');
      insert into public.checkins (id, promise_id, user_id, date_local) values
        ('${checkins.alice}', '${users.alice}', '${users.alice}', '2026-10-20'),
        ('${checkins.carol}', '${users.carol}', '${users.carol}', '2026-10-20'),
        ('${checkins.david}', '${users.david}', '${users.david}', '2026-10-20');
      insert into public.reactions (checkin_id, from_user, stamp) values
        ('${checkins.alice}', '${users.bob}', 'clap'),
        ('${checkins.carol}', '${users.david}', 'heart'),
        ('${checkins.david}', '${users.carol}', 'clap');
    `);
    return database;
  } catch (error) {
    await database.close();
    throw error;
  }
}

async function asUser<Result>(
  database: PGlite,
  userId: string,
  read: () => Promise<Result>,
): Promise<Result> {
  await database.exec("begin; set local role authenticated;");
  try {
    await database.query(
      "select set_config('request.jwt.claim.sub', $1, true)",
      [userId],
    );
    const identity = await database.query<{ role: string; bypass: boolean }>(`
      select current_user as role, rolbypassrls as bypass
      from pg_roles where rolname = current_user
    `);
    assertEquals(identity.rows, [{ role: "authenticated", bypass: false }]);
    return await read();
  } finally {
    await database.exec("rollback;");
  }
}

async function readReactions(database: PGlite): Promise<Reaction[]> {
  return (await database.query<Reaction>(`
    select checkin_id, from_user, stamp from public.reactions
    order by checkin_id, from_user
  `)).rows;
}

Deno.test("reactions RLS isolates visible checkins after re-pairing", async (test) => {
  const database = await createDatabase();
  try {
    await test.step("legacy policy reproduces the synthetic cross-pair leak", async () => {
      const reactions = await asUser(
        database,
        users.carol,
        () => readReactions(database),
      );
      assertEquals(
        reactions.filter((reaction) => reaction.checkin_id === checkins.eve),
        [{ checkin_id: checkins.eve, from_user: users.david, stamp: "clap" }],
      );
    });

    await database.exec(
      await Deno.readTextFile(
        new URL(
          "../migrations/0009_reactions_select_visible_checkin.sql",
          import.meta.url,
        ),
      ),
    );

    await test.step("new partner cannot read the other pair's reaction", async () => {
      await asUser(database, users.carol, async () => {
        assertEquals(
          (await database.query(
            "select id from public.checkins where id = $1",
            [checkins.eve],
          )).rows,
          [],
        );
        assertEquals(await readReactions(database), [
          {
            checkin_id: checkins.carol,
            from_user: users.david,
            stamp: "heart",
          },
          { checkin_id: checkins.david, from_user: users.carol, stamp: "clap" },
        ]);
      });
    });

    await test.step("partner checkins before the new pair stay private", async () => {
      await asUser(database, users.carol, async () => {
        assertEquals(
          (await database.query(
            "select id from public.checkins where id = $1",
            [checkins.davidBeforePair],
          )).rows,
          [],
        );
        assertEquals(
          (await readReactions(database)).filter((reaction) =>
            reaction.checkin_id === checkins.davidBeforePair
          ),
          [],
        );
      });
    });

    await test.step("sender retains their own reaction on the old pair's checkin", async () => {
      await asUser(database, users.david, async () => {
        assertEquals(
          (await database.query(
            "select id from public.checkins where id = $1",
            [checkins.eve],
          )).rows,
          [],
        );
        assertEquals(await readReactions(database), [
          {
            checkin_id: checkins.carol,
            from_user: users.david,
            stamp: "heart",
          },
          { checkin_id: checkins.david, from_user: users.carol, stamp: "clap" },
          {
            checkin_id: checkins.davidBeforePair,
            from_user: users.eve,
            stamp: "heart",
          },
          { checkin_id: checkins.eve, from_user: users.david, stamp: "clap" },
        ]);
      });
    });

    await test.step("checkin owner can read received reactions after dissolution", async () => {
      assertEquals(
        await asUser(database, users.eve, () => readReactions(database)),
        [
          {
            checkin_id: checkins.davidBeforePair,
            from_user: users.eve,
            stamp: "heart",
          },
          { checkin_id: checkins.eve, from_user: users.david, stamp: "clap" },
        ],
      );
    });

    await test.step("unrelated active pair still sees only its own reactions", async () => {
      assertEquals(
        await asUser(database, users.alice, () => readReactions(database)),
        [{ checkin_id: checkins.alice, from_user: users.bob, stamp: "clap" }],
      );
    });

    await test.step("dissolving the current pair removes access to partner checkins", async () => {
      await database.query(
        `update public.pairs set status = 'dissolved', dissolved_at = '2026-10-21T00:00:00Z'
         where id = $1`,
        [pairs.carolDavid],
      );
      assertEquals(
        await asUser(database, users.carol, () => readReactions(database)),
        [
          {
            checkin_id: checkins.carol,
            from_user: users.david,
            stamp: "heart",
          },
          { checkin_id: checkins.david, from_user: users.carol, stamp: "clap" },
        ],
      );
      assertEquals(
        await asUser(
          database,
          users.carol,
          async () =>
            (await database.query(
              "select id from public.checkins where id = $1",
              [checkins.david],
            )).rows,
        ),
        [],
      );
    });
  } finally {
    await database.close();
  }
});
