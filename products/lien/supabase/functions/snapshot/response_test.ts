import { snapshotResponse } from "./response.ts";
import { buildSoloSnapshot } from "../_shared/snapshot.ts";

function snapshot() {
  return buildSoloSnapshot({
    myPromise: null,
    updatedAtIso: "2026-10-20T10:00:00Z",
    todayMeDone: false,
    todayLocal: "2026-10-20",
  });
}

function assert(condition: boolean) {
  if (!condition) throw new Error("assertion failed");
}

Deno.test("snapshot conditional GET: legacy clients retain the same 200 envelope", async () => {
  const state = snapshot();
  const result = await snapshotResponse("user-a", state, null);
  assert(result.status === 200);
  assert(
    JSON.stringify(await result.json()) === JSON.stringify({ snapshot: state }),
  );
  assert(result.headers.get("cache-control") === "private, no-store");
});

Deno.test("snapshot conditional GET: unchanged state returns bodyless 304 despite later updatedAt", async () => {
  const state = snapshot();
  const initial = await snapshotResponse("user-a", state, null);
  const result = await snapshotResponse("user-a", {
    ...state,
    updatedAt: "2026-10-20T10:01:00Z",
  }, initial.headers.get("etag"));
  assert(result.status === 304);
  assert(
    result.headers.get("x-lien-snapshot-confirmed-at") ===
      String(Date.parse("2026-10-20T10:01:00Z")),
  );
  assert(await result.text() === "");
});

Deno.test("snapshot conditional GET: changed state returns latest snapshot", async () => {
  const state = snapshot();
  const initial = await snapshotResponse("user-a", state, null);
  const changed = { ...state, todayMeDone: true };
  const result = await snapshotResponse(
    "user-a",
    changed,
    initial.headers.get("etag"),
  );
  assert(result.status === 200);
  assert((await result.json()).snapshot.todayMeDone === true);
  assert(result.headers.get("etag") !== initial.headers.get("etag"));
});

Deno.test("snapshot conditional GET: next local day invalidates cursor", async () => {
  const state = snapshot();
  const initial = await snapshotResponse("user-a", state, null);
  const result = await snapshotResponse("user-a", {
    ...state,
    dateLocal: "2026-10-21",
  }, initial.headers.get("etag"));
  assert(result.status === 200);
});

Deno.test("snapshot conditional GET: cursor is bound to authenticated user", async () => {
  const initial = await snapshotResponse("user-a", snapshot(), null);
  const result = await snapshotResponse(
    "user-b",
    snapshot(),
    initial.headers.get("etag"),
  );
  assert(result.status === 200);
  assert(result.headers.get("vary") === "Authorization");
});

Deno.test("snapshot conditional GET: reordering keys does not create a change", async () => {
  const state = snapshot();
  const initial = await snapshotResponse("user-a", state, null);
  const reordered = Object.fromEntries(
    Object.entries(state).reverse(),
  ) as typeof state;
  const result = await snapshotResponse(
    "user-a",
    reordered,
    initial.headers.get("etag"),
  );
  assert(result.status === 304);
});
