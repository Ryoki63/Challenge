import type { PairSnapshot } from "../_shared/snapshot.ts";

export async function snapshotResponse(
  userId: string,
  snapshot: PairSnapshot,
  ifNoneMatch: string | null,
): Promise<Response> {
  const { updatedAt: _updatedAt, ...state } = snapshot;
  const canonical = Object.fromEntries(
    Object.entries(state).sort(([left], [right]) => left.localeCompare(right)),
  );
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify([userId, canonical])),
  );
  const etag = `W/"${
    Array.from(new Uint8Array(digest), (byte) =>
      byte.toString(16).padStart(2, "0"))
      .join("")
  }"`;
  const headers = {
    "content-type": "application/json",
    "cache-control": "private, no-store",
    "etag": etag,
    "vary": "Authorization",
  };
  if (ifNoneMatch === etag) return new Response(null, { status: 304, headers });
  return new Response(JSON.stringify({ snapshot }), { status: 200, headers });
}
