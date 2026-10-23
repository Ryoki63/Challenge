# Issue #160 QA: reactions visibility boundary

## Result

PASS for the proposed fix at PR #152 head `949cddc37d9253108906fa57c314a5b88b35f71b`.
PR #152 is still open and unmerged, so this result applies to the isolated candidate commit; it does not certify the deployed database.

## Isolated environment

- Detached Git worktree: `.qa-pr152` at the exact PR head SHA above.
- Test path: `products/lien/supabase/tests/auth_boundaries.test.ts` using in-memory PGlite.
- Fixture: synthetic users/pairs AB, DE, and re-paired CD. No Supabase connection, production API, real user, real JWT, secrets, or production data used.
- The test transaction assumes `authenticated` with `BYPASSRLS=false` for reads and applies migration `0001_init.sql` followed by candidate migration `0009_reactions_select_visible_checkin.sql`.

## Test evidence

- Command: `/Users/kojimaryoki/.deno/bin/deno test --config products/lien/supabase/tests/deno.json --frozen --allow-read --allow-env=NODE_ENV products/lien/supabase/tests/`
- Result: PASS, 1 test / 8 steps, 0 failed. The steps include synthetic legacy leak baseline, post-migration exclusion of the old pair's reaction, visible same-day partner reaction in the active pair, pre-pair boundary, sender-owned history, check-in owner access, unrelated pair isolation, and access removal after dissolution.
- Raw output: [`issue-160-pr152-deno-test.log`](issue-160-pr152-deno-test.log)
- Additional checks at the same SHA: `deno check`, `deno lint`, `deno fmt --check`, and `git diff --check` all exited 0.
- GitHub CI on PR #152 head: 6 `lien-ci` checks report SUCCESS (PR API observation during this QA run).

## Scope and status

- Same active pair's readable reaction: confirmed available.
- Other pair's reaction row in the current reader's result: confirmed absent after migration.
- Additional defect observed: none in the scoped test.
- Production migration / device UI / other #380 scenarios: not run; outside this task's scope.
