# Performance review

## Regions (documented, not changeable from code)
Latency is dominated by distance between the three places a request touches: the user → Vercel → Supabase.
* **Supabase project region** is fixed when the project is created (Project Settings → General). **Vercel Functions region** is set in Project Settings → Functions → *Function Region* (or `regions` in `vercel.json`).
* Make them the **same or neighbouring** region. For Egyptian users the nearest Supabase options are generally EU (Frankfurt / Paris / London) or `me-central`/`me-south` where offered — check the current list in the Supabase dashboard; availability changes. Pick one, then set Vercel's function region to the matching one (e.g. Frankfurt `fra1` ↔ Supabase `eu-central-1`).
* This is also the answer to the "Supabase region" question in `docs/LEGAL_OPEN_ITEMS.md`: the privacy text needs the **actual** region once chosen.
* Not done by me: I cannot see your Supabase or Vercel projects, so the current regions are unknown. Record them in the deployment checklist.

## Auth lookups (reviewed)
* Per request: the proxy refreshes the session once with `getClaims()`; `org-context.ts` shares one user lookup, one membership lookup and one `my_org_access` call per request through React `cache` (never across requests/users). Dashboard pages fetch independent RPCs with `Promise.all`; the heavy aggregates are single SQL functions (not row-by-row in the app).
* **`getClaims()` and JWT signing keys.** `getClaims()` verifies the token locally only if the project uses **asymmetric JWT signing keys**; on a legacy shared-secret project the library falls back to a network `getUser()` check (same behaviour as before, just no speed-up). To verify: Supabase → Project Settings → **JWT Keys** — if a signing key with an asymmetric algorithm (ES256/RS256) is *current*, local verification is active; if only the legacy HS256 secret exists, it is not. No code change is needed either way. I could not check your project.
* Trade-off to know: with local verification a deleted/banned user's access token stays valid until it expires (default 1 hour) for **read** paths. Every server action that writes calls `auth.getUser()` (a live check); the proxy only gates page access. I did not widen the use of `getClaims()`.

## Full-table reads reviewed
* Fixed: invoice forms no longer load every customer/supplier/product (they were silently capped at 1000 by the API and shipped the whole catalogue to the browser). They now search on the server (30 results per search, migration 0069's Arabic-aware search).
* Dashboard/report numbers come from SQL aggregates; I did not touch any financial calculation.
* **Still full-list reads (deferred, listed for the next pass):** the inventory transfer / stocktake product pickers, the sales-rep home customer list (`limit 1000`), and the party-balance report (`limit 500`). They behave correctly below those sizes; above them the list is truncated. Convert them to the same server-side search when a customer approaches 1000 products/customers.
* Nothing was cached across requests, so no financial figure can be stale.
