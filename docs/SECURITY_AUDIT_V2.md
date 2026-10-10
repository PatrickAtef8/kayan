# Kayan — Security Audit (updated codebase, re-verified)

**Scope:** `kayan_latest.zip` (first upload) and the updated upload (migrations 0001–0029, Next.js 14.2.15 app, Supabase).
**Method:** source review **plus live exploitation**. I built PostgreSQL 16 with Supabase's role model and default privileges, applied all migrations, seeded two tenants and eight personas (owner, accountant, warehouse, restricted rep, plain sales, outsider, attacker, victim), and attacked it through the same roles PostgREST uses. Every finding marked **EXPLOITED** was reproduced; every fix in `0030_security_hardening.sql` was re-tested against the same exploit.

**Not verifiable from the zip (UNKNOWN):** Supabase dashboard settings (email confirmation, password policy, redirect allow-list, auth rate limits), the real project's table/function grants, git history (no `.git`), hosting headers/HSTS, Storage's served content-types.

> Change since first upload: migrations 0001–0021 untouched. 0022–0029 fixed several business-logic bugs (listed under "Fixed") but **none of the access-control criticals**. `package.json`, `next.config.mjs`, `middleware.ts` unchanged.

---

## 1. Critical / High — MUST fix

### C1 · Permission catalog is world-writable → platform-wide privilege escalation — **FAIL · CRITICAL · EXPLOITED**
- **Where:** tables `permissions`, `role_permissions` (created in `0001_foundation.sql`, grants in `0003_grants.sql`). Neither ever gets `enable row level security`; nothing revokes writes.
- **Evidence:** inventory query on the built DB: only these two tables lack RLS; `anon` and `authenticated` hold INSERT/UPDATE/DELETE on both (Supabase default privileges). A freshly signed-up user belonging to **no org** ran `INSERT INTO role_permissions … (sales template, 'manage_settings'/'view_financial'/'treasury.manage')` → succeeded; an unrelated tenant's plain sales user then returned `true` for all three, and could call `list_org_members` and read the audit log. DELETE also succeeded (strip everyone's permissions).
- **Why it works:** system roles (`organization_id IS NULL`) are *shared templates across every tenant*; `has_permission()` reads `role_permissions`. One write changes every company.
- **Fix:** `0030` §1 — enable + force RLS, SELECT-only policy, `REVOKE ALL … FROM anon, authenticated`, re-grant SELECT. **Verified:** insert/delete denied for stranger and anon.
- **Check on your live project:** `select grantee, privilege_type from information_schema.role_table_grants where table_name in ('role_permissions','permissions') and grantee in ('anon','authenticated');`

### H1 · `find_user_id_by_email` callable by anyone with the anon key — **FAIL · HIGH · EXPLOITED**
- **Where:** `0011_returns_and_team.sql`, SECURITY DEFINER over `auth.users`; comment claims "never granted to authenticated/anon" but no REVOKE exists.
- **Evidence:** as `anon`: returns the user's UUID for a registered email and NULL otherwise (unauthenticated user enumeration + UUID disclosure).
- **Root cause:** `alter default privileges in schema public revoke execute … from public, anon` (0010) cannot remove Postgres's *global* PUBLIC default, so **every function without its own REVOKE is exposed**. The "SECURITY_AUDIT.md" claim that this was solved is incorrect (verified). 15 functions were anon-executable (mostly harmless helpers/trigger fns).
- **Fix:** `0030` §2 — revoke on that function, sweep-revoke from `public, anon` on all non-extension functions, and fix default privileges (`alter default privileges revoke execute on functions from public` *without* `IN SCHEMA`). **Verified denied** for anon and authenticated.

### H2 · Forced tenant enrolment → victim misdirection and owner lock-out — **FAIL · HIGH · EXPLOITED**
- **Where:** `add_team_member`, `complete_team_invite` (0011); `src/lib/org-context.ts → getMembership()` (`.limit(1)`, no `ORDER BY`); every server action uses `.maybeSingle()`.
- **Evidence:** any free account becomes an org owner via `create_organization`, then:
  1. `add_team_member(evil_org, 'victim@x.com', role)` inserts the victim as **`active`** with no consent. Response differs for unknown emails → **email enumeration by any logged-in user**.
  2. A victim who has signed up but not onboarded gets `getMembership()` = the attacker's org → the layout never redirects to onboarding; they work inside the attacker's tenant (attacker is owner).
  3. A real tenant owner enrolled a second time has 2 active memberships → `.maybeSingle()` errors → **every server action returns "غير مصرح"**; the owner cannot delete the rogue row (DELETE needs `manage_settings` in *that* org). Persistent DoS.
  4. `complete_team_invite` accepts any raw `p_user_id`.
- **Fix:** `0030` §4 — enrol as `'invited'`, `accept_org_invite()`, self-leave/decline policy, self-select policy, uniform response. **Verified:** victim has 0 active memberships, can accept and leave. **App changes needed:** (a) `getMembership`: `.eq('status','active').order('created_at').limit(1)`; (b) switch every `maybeSingle()` membership lookup to the same helper; (c) add a small `list_my_invites()` RPC + pending-invite banner (RLS hides the org row until accepted).

### H3 · `NaN` poisoning of invoices and aggregates — **PARTIAL · HIGH · EXPLOITED**
- **Where:** `_pricing()` / `create_sales_invoice()` / `create_purchase_invoice()` (0029); `CHECK (quantity > 0)`-style constraints.
- **Evidence:** in Postgres `NaN > 0` is TRUE and `NaN <= 0`, `NaN < 0` are FALSE, so all guards pass. After 0028's stock check, NaN is blocked **only for stock-tracked products**. A `sales.create` user (restricted rep) still created invoices with NaN quantity (service product), NaN `unit_price`, and NaN `tax`; the tenant's `sum(total)` became `NaN`, breaking every report and dashboard until a DBA cleans rows. (`amount_collected` NaN is correctly rejected.)
- **Fix:** `0030` §3 — `CHECK (col <> 'NaN' AND <> ±Infinity)` on every numeric column. **Verified:** all four variants rejected, normal sale still succeeds.

### H4 · Financial data readable by every member regardless of role — **PARTIAL · HIGH · EXPLOITED**
- **Where:** SELECT policies `is_org_member` / `user_org_ids()` on `treasury_*`, `expenses`, `partners`, `partner_withdrawals`, `purchase_*`, `supplier_payments`, `other_balances`, `product_prices.cost`, `inventory_stock.avg_cost`.
- **Fixed in 0027:** sales cost/profit/COGS moved to companion tables gated by `view_financial` (verified: warehouse/plain-sales read 0 rows). **Restricted reps** (sales role + linked rep record) are cleanly isolated by RESTRICTIVE policies (verified: 0 rows for all finance tables).
- **Still open:** the protection is keyed to `role.key = 'sales'` *and* a rep link. A `warehouse` user (or plain sales, or any custom role) still read: owner's private partner withdrawals (5,000), expenses, treasury movements/balance, purchase invoices, suppliers, product **cost** (60) and stock **avg_cost**.
- **Fix:** `0030` §5 — RESTRICTIVE gates using `finance_org_ids()` / `purchasing_org_ids()`. **Verified:** warehouse sees 0; accountant and owner unchanged. **Still to do (not in 0030):** move `product_prices.cost` and `inventory_stock.avg_cost` into companion tables like 0027 (RLS can't hide a column). **Review against your screens** before shipping.

### H5 · Next.js 14.2.15 — **FAIL · HIGH (critical advisories) · unchanged**
- `npm audit`: 1 critical + 4 high, rooted in `next@14.2.15` (~32 advisories), incl. middleware authorization bypass (GHSA-f82v-jwr5-mffw) and middleware-redirect SSRF (GHSA-4342-x723-ch2f). Both are relevant because `middleware.ts` is used and passes `NextResponse.next({ request })`.
- **Practical impact here is reduced** because `dashboard/layout.tsx` re-checks `getUser()` and RLS is the real boundary, but session-refresh and defence-in-depth are gone and the DoS/RCE-class advisories are independent of that.
- **Fix:** upgrade to the current patched `next` (npm suggests a major bump), then re-run `npm audit`; test middleware/session refresh.

### H6 · Email ownership never proven; weak passwords — **FAIL (by design) / UNKNOWN setting · HIGH**
- **Where:** `src/app/(auth)/signup/page.tsx` (requires `signUp()` to return a session ⇒ "Confirm email" must be OFF), `dashboard/layout.tsx` (never checks `email_confirmed_at`), password min 6 enforced client-side.
- **Attack:** pre-register `ceo@victim.com`; when an admin later adds/invites that address (`add_team_member` matches by email) the attacker's account gets the role. Also signup returns "already registered" ⇒ enumeration.
- **Fix:** turn on email confirmation; add `/auth/callback` code exchange; block the dashboard until `email_confirmed_at`; server-side min length ≥ 12 + leaked-password protection in Supabase Auth; CAPTCHA/rate limits on signup/login.

### H7 · No commercial authority controls on invoices (insider loss) — **FAIL · HIGH (business) · EXPLOITED**
- **Where:** `create_sales_invoice` (0029) / `_pricing`.
- **Evidence:** a restricted rep (only `sales.create`) sold 50 units at **0.01** vs list **100**, sold 10 units at **100% discount**, and attached **30 free "manual bonus" units** with no matching `bonus_rules` — stock fell 98→7. `unit_price`, `discount_pct`, bonus items and `p_sales_rep_id` (for non-linked users) are all caller-controlled.
- **Fix (needs product decisions):** floor price = `product_prices.selling_price` × (1 − max_discount); `max_discount_pct` per role; require `sales.approve` for discounts above a threshold; validate bonus items against `bonus_rules`; ignore `p_sales_rep_id` unless caller has `manage_settings`.

---

## 2. Other important issues

| ID | Status | Sev | Finding & evidence | Fix |
|---|---|---|---|---|
| M1 | FAIL | MED | **Any member edits master data/prices/opening balances, unaudited.** `customers/suppliers/product_prices` UPDATE policies = membership only. Warehouse set selling_price=1, cost=999, customer `opening_balance=-50,000`, supplier `777,777`, `credit_status`; **0 audit rows** (audit triggers fire on DELETE only; price trigger only on `selling_price`). | `0030` §6 (restrictive update gate + audit triggers; verified price tamper blocked). Plain sales can still edit customers incl. `opening_balance` → move opening balances behind an RPC requiring `manage_settings`. |
| M2 | FAIL | MED | **CSV formula injection** — `src/lib/csv.ts → downloadCsv` escapes quotes/commas only; any member can plant `=HYPERLINK(...)` in names/notes that executes when an accountant opens the export. | Prefix string cells starting with `= + - @ \t \r` with `'`; apply to strings only (not numbers). |
| M3 | FAIL | MED | **No security headers** — `next.config.mjs` is empty: no CSP, `X-Frame-Options`/`frame-ancestors` (clickjacking on a financial UI), `Referrer-Policy`, `X-Content-Type-Options`, HSTS; `x-powered-by` on. | Add `headers()` with CSP (self + Supabase origin), `frame-ancestors 'none'`, `nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, HSTS; `poweredByHeader:false`. |
| M4 | FAIL | MED | **Attachments:** storage/table policies are membership-only (warehouse deleted a finance receipt; verified), bucket has **no size/MIME limit** (10 MB check is client-side), `uploaded_by` spoofable, `storage_path` can point at another org's folder (RLS stops reading it). | `0030` §7 (limits); add permission-based storage policies; enforce `storage_path` prefix = `organization_id` and `uploaded_by = auth.uid()` with a CHECK/trigger. |
| M5 | FAIL | MED | **No abuse limits:** 200 orgs created in one call; unlimited CSV rows; `inviteUserByEmail` (service role) can be driven by any self-made org admin to email arbitrary addresses. | `0030` §4 caps owned orgs at 3; add per-user rate limits on invites and CSV size; cap row count. |
| L1 | FAIL | LOW | `settings/discounts/actions.ts`: `insert({ organization_id: orgId, ...input })` — client can override `organization_id` (RLS stops cross-tenant). | Put `...input` first or whitelist fields. |
| L2 | FAIL | LOW | `/api/auth/signout` POST has no CSRF token (SameSite=Lax mitigates). | Accept only same-origin; optionally token. |
| L3 | FAIL | LOW | `.gitignore` ignores `.env.local`/`.env*.local` but not plain `.env`/`.env.production`; `tsconfig.tsbuildinfo` shipped; no `.env.example`. | Ignore `.env*`, add example file. |
| L4 | FAIL | LOW | `NEXT_PUBLIC_SITE_URL || "http://localhost:3000"` fallback in invite redirect; `party_notes.note` unbounded. | Fail hard if unset in production; add length checks. |
| L5 | PARTIAL | LOW | Two migrations numbered `0022_*`; ordering depends on filename sort. | Renumber. |
| L6 | PARTIAL | LOW | `organization_users.role_id` UPDATE has no org-match check (only `add_team_member` validates). | Trigger validating role org. |

---

## 3. Fixed since the first upload (verified by re-attack)
- **Double-return race** — `create_sales_return` now locks the invoice item (`FOR UPDATE`): concurrent second return rejected ("remaining 0"); previously 10 sold / 20 returned / 2,000 refunded.
- **Over-collection / commission inflation** — collections capped at remaining balance (was +100,000 commission).
- **Negative / oversell** — negative discounts/tax/paid rejected; oversell rejected by `_consume_stock`; discounts are bounded percentages.
- **Cost/profit exposure on sales documents** — moved behind `view_financial` (0027).
- **New surface is sound:** `party_notes`, rep-scope RESTRICTIVE policies, `security_invoker` views, `discount_tiers`/`bonus_rules` RLS, `pricing_preview`.

---

## 4. Controls verified as correctly implemented
- **Tenant isolation (PASS):** Org B owner got 0 rows from all A tables/views (including the new ones), and every RPC rejected foreign `org_id` and foreign object IDs (invoice, customer, rep, warehouse, product, expense rep, report analyses). `product_sale_prices` (owner-run view) is safe because it filters by `user_org_ids()`.
- **IDOR/BOLA in server actions (PASS):** actions derive `organization_id` from the DB, never from client input.
- **SQL injection (PASS):** all dynamic SQL uses `%I` with trusted identifiers; `global_search` is invoker-security and parameterised.
- **SECURITY DEFINER hygiene (PASS):** all have a pinned `search_path`; authenticated cannot `CREATE` in `public`.
- **Audit log immutability (PASS)**, org-owner protection trigger, duplicate-submission guard, report-RPC redaction, restricted-rep isolation.
- **XSS (PASS):** no `dangerouslySetInnerHTML`/`innerHTML`/`eval`; **open redirects (PASS):** only constant/relative targets.
- **Secrets (PASS):** none hard-coded; service-role key only via env, in `admin.ts` guarded by `import "server-only"`, single call site.
- **N/A:** webhooks, payment gateways (internal bookkeeping only), SSRF/outbound fetch, AI/Claude API — no such code present.
- **UNKNOWN:** Server Action Origin/CSRF check (framework feature, but your version has advisories), cookie flags (set by `@supabase/ssr`; not HttpOnly by design), git history.

---

## 5. Prioritised FIX ORDER
1. **Today:** apply `0030` §1 (C1) and §2 (H1). Two statements, zero UI impact.
2. **This week:** `0030` §3 (NaN), §4 (invites; plus the 3 app changes), §5 (finance gates — verify screens), §6–§8.
3. **This week:** upgrade Next.js and re-run `npm audit`.
4. **This week:** Supabase Auth settings — confirm email, strong passwords + leaked-password check, redirect allow-list, CAPTCHA/rate limits; then ship the callback + `email_confirmed_at` gate.
5. **Next sprint:** commercial controls (H7); move `cost`/`avg_cost` into gated companion tables; opening-balance RPC.
6. **Next sprint:** security headers + CSP; CSV injection fix; attachment permissions + path/uploaded_by checks; abuse limits.
7. **Hygiene:** L1–L6, add `supabase/tests` that run as `anon`/`authenticated` **with Supabase default privileges** (your current stub grants nothing by default, which is why the suite never caught C1/H1).

## 6. How to re-verify on your real project
```sql
-- tables without RLS (expect none)
select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and relkind='r' and not relrowsecurity;
-- functions anon can run (expect none besides extension fns)
select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and has_function_privilege('anon',p.oid,'execute');
```


---
## Update 2 — decisions implemented and verified
| Item | Status |
|---|---|
| H5 Next.js | **Fixed** — upgraded to 16.3.8 + React 19; `npm audit`: 0 critical, `next` no longer listed. Live check: security headers present, `/dashboard` redirects when signed out, the `x-middleware-subrequest` bypass header no longer works. |
| H7 Discount / bonus limits | **Fixed** — configurable per role (0031), unlimited option, enforced in the shared pricing engine so the invoice RPC and the live preview agree. Verified: 0% default blocks discounts/low prices/bonus for a rep; 10% cap blocks 10.5%, 5%+6% combined and price 89; unlimited allows; non-managers and other orgs cannot change limits; changes are audited. |
| H4 Balances | **Mostly fixed** — customer/supplier balances hidden unless permitted; warehouse cannot read suppliers or purchases. **Residual:** the `opening_balance` column of *customers* is still readable by anyone who can read the customer row (RLS cannot hide one column). Closing it needs the opening balance moved to a gated table, as 0027 did for profit. |
| Remaining dev-tooling advisories | 10 (build-time only: Tailwind 3 file-watching deps, ESLint config). Clearing them needs Tailwind 4. |


---
## Update 3 — remaining gaps closed (migrations 0032, 0033) — verified by 142 automated checks
| Gap | Fix | Verified |
|---|---|---|
| `customers.opening_balance` readable/writable by any role that could see the customer (RLS cannot hide one column) | Moved to `customer_opening_balances` (and `supplier_opening_balances`), RLS read/write split, audited, column dropped, 2 views + 5 report functions rewritten | Rep / plain sales / warehouse / other tenant: 0 rows, insert/update/delete blocked. Accountant/admin/owner allowed. View-only permission reads (scoped to own customers) but cannot write. Reports + balances still correct. Legacy data migrated exactly. |
| Anyone could sell below cost | Trigger on the cost record written for every invoice line (uses the REAL average cost at sale time); only the system Owner role exempt | at cost / above cost allowed; 59, 59.98, 41% line, 41% invoice, qty-3 @59, price 0 blocked for rep, plain sales and **admin**; owner allowed; blocked attempts leave no invoice; error does not reveal the cost |
| Reps could assign invoices/customers to other reps | Trigger on `sales_invoices` and `customers.sales_rep_id` + `sales.assign_any_rep` permission; `create_sales_invoice` honours the override (one-condition change) | own rep allowed; other rep refused or forced back to own; unlinked users keep only the customer's default rep; override granted -> allowed, removed -> blocked again; customer hand-offs blocked |

**Known limits (be aware):**
- (Fixed in Update 4) A restricted rep who named another rep used to be silently recorded under their own rep; they now get a clear error.
- The below-cost rule is per invoice line and is not shown in the live preview (it fires on save). The refusal message does not reveal the cost, but repeated attempts could still binary-search it (cost itself is no longer readable — see Update 4).
- "Owner" means the system `owner` role only; a custom role cloned from owner is NOT exempt.


---
## Update 4 — cost data protected; explicit rep error (migrations 0034, 0035) — 198 automated checks
**Cost was leaking through five sources, not two.** A scan of every cost-like column as a warehouse user found, besides `product_prices.cost` and `inventory_stock.avg_cost`: `inventory_movements.unit_cost`, `stock_transfer_items.unit_cost/line_total` and `stock_transfers.total_value` (5 units x 60 = 300 was readable). All five moved into RLS-protected tables (read: `view_financial` | `products.view_cost`; product cost write: `view_financial` | `purchases.approve` | `manage_settings`). The movement/transfer columns are kept but forced NULL by a trigger + CHECK so no writer can put a cost back.

| Check | Result |
|---|---|
| Costing maths unchanged | Same 8-step scenario (2 purchases at different prices, sale, transfer, adjustments, sales return, purchase return) run on the old and new schema: **60 snapshot rows identical** |
| Legacy data | Applied 0034/0035 to a database holding real cost data: 0 rows lost, 0 extra, old columns gone, legacy columns NULL |
| Blocked | warehouse, plain sales, restricted rep and other tenants: all cost columns gone/NULL, all protected tables empty, no writes, catch-all scan of every cost/cogs/profit/margin/total_value column finds nothing |
| Allowed | owner, admin, accountant read all stores; owner/admin/accountant edit product cost (audited); every report still shows cost to them |
| Rep error | restricted rep naming another rep -> refused with a clear message, nothing created; naming themselves or nobody works; override holders unaffected |
| Mutation tests | removing a protection fails the suite (policy leak: 8 failed checks, diversion trigger removed: 7, old silent behaviour restored: 8, editor policy loosened: 2) |

Bugs the tests caught in my own first draft (fixed before delivery): `product_costs` lacked a tenant column so any cost edit would have failed to write its audit row; `report_summary` broke because its loop variable `s` shadowed a table alias I introduced.

**Known limits:** historical `audit_logs` rows written before 0034 still contain old cost values in their before/after JSON (visible only to roles with `audit.view`, i.e. owner/admin/accountant by default). `sales_item_financials` (cost/profit per sold line) was already restricted by 0027.
