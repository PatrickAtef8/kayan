# Billing flow fixes: paywall page, package-controlled modules, admin company count

## 1. "فعّل حسابك" card stayed on screen at /dashboard/billing
**Cause:** the payment gate lives in `dashboard/layout.tsx`. Next.js does not re-render a layout when you move between pages inside it, so the
layout kept showing the "activate" card (decided from the URL it saw on the first load) while the URL had already changed to billing.
**Fix:** the layout still redirects on a full page load; for an unpaid owner it now wraps the page in `OwnerPaywallBody` (client component,
`usePathname`) which shows the billing page on `/dashboard/billing/**` and the prompt + redirect everywhere else. The gate itself (layout +
database on every table/RPC) is unchanged.

## 2. Modules chosen at sign-up although the PACKAGE decides them
* Sign-up is one step now (company, activity, email, password); no module cards. A new company starts with the core modules only, and after sign-up
  goes straight to `/checkout` (package chosen) or `/dashboard/billing`.
* **Migration `0066_package_controls_modules.sql`:** when a license is created its package's modules are switched on (gated modules outside the
  package are switched off); widening a package later switches the NEW modules on and never switches anything off; `billing_fit_report` ignores
  modules until a license exists (an old unpaid company that ticked "partners" can now pay for Basic). One-time clean-up: unpaid companies' optional
  modules are switched off (paying turns on exactly the package's modules). Licensed companies are untouched.
* Settings → Modules shows the modules outside the package locked ("غير مشمولة في باقتك"); the database trigger still refuses them.

## 3. Admin showed 0 companies
The overview read `organizations` directly with the service role and ignored the error, so any failure became a silent `0`. It now uses
`admin_companies_overview` (the function the companies list already uses) and shows «—» if that call fails.

## Also
Removed `src/components/pricing/billing-actions.tsx`: unused leftover importing the deleted `retryOrder`; it failed `tsc` / `next build`.

## Deploy
Run `0066_package_controls_modules.sql` (after 0065), then deploy the app. Tests: `npm run test:billing` (78 pass), `tsc --noEmit` clean;
DB tests `112` (updated) and new `117_package_controls_modules_test.sql` need a Postgres (`npm run test:db`) — not run in my sandbox.

## Round 2: admin accounts on the users page and login
* The users-page subtitle claimed deletion rules that ignore administrators. It now says administrator accounts (yours and their demo company) are
  protected, and administrator rows carry a «مدير منصة» badge. (The server already refused to disable/delete yourself or another administrator.)
* A signed-in administrator without a company was sent to `/signup` (a form that creates a new account). They now go to `/admin`.

## Round 3: the administrator can delete companies and users (migration 0067)
Before: no way to delete a company, and a user who belonged to any company could not be deleted ("blockers"). Now the administrator can delete
**any** company and **any** user except their own account (so they cannot lock themselves out), and can disable any other user, administrators
included.
* `admin_delete_company` erases the company and everything inside it, including its (otherwise immutable) audit trail; members' accounts stay.
* `admin_delete_user` removes the person's memberships and clears them from every "created by" column (those columns become nullable); the
  records stay, attributed to nobody; the Auth account is then deleted by the app. A company whose only owner is deleted is left ownerless.
* Both run in one transaction and are callable only with the service role. They switch the application triggers off for the duration (the
  integrity triggers stay on), so run them on a quiet moment: the tables are locked briefly.
* UI: «حذف الشركة نهائيًا» on the company page; «حذف نهائي» enabled for every user on the users page.
* Not done: files in Supabase Storage (attachments) of a deleted company are not removed.
* Tests: `supabase/tests/118_admin_delete_test.sql` (not run here: no Postgres in my sandbox).

## Round 4: performance of the admin area, billing and checkout (migration 0068)
These pages had none of the earlier performance work (see PERFORMANCE_NOTES.md). Now:
* **Admin authorization once per request, no network for id-listed admins.** The layout and every page each called `auth.getUser()` (a round trip
  to Supabase Auth, twice per navigation). `requireSuperAdminPage` is now memoised and reads the verified session token; only an administrator
  listed by EMAIL (which needs a confirmed email) costs one verified lookup. Server actions still verify with `getUser()`.
* **Users page: one query.** `admin_users_page` (search + paging + memberships) replaces up to 5 sequential Auth-API calls + a second call; the
  search is no longer limited to the first 1,000 accounts.
* **Overview and packages pages:** `admin_overview_stats` / `admin_license_stats` replace downloading every license row and an Auth-API call.
* **Company page:** the access-state call joined the main batch (it was a sequential 6th call).
* **Billing page:** admin check + pricing config + license + orders + access in ONE batch (they ran one after another); `my_org_access` is shared
  with the layout (`getOrgAccess`, one call instead of two). **Checkout:** config + pending order + legal versions in one batch (4 sequential
  awaits → 2). **/pricing:** reads the session token locally instead of `auth.getUser()`.
* **Perceived speed:** `loading.tsx` skeletons for every admin section, billing and checkout; the top progress bar + dimming on admin, billing and
  checkout (they only existed inside the dashboard shell); the clicked admin tab lights up immediately.
* Apply `0068_admin_perf.sql` BEFORE deploying the code (the users and overview pages call the new functions).
* Not changed: the legal-documents admin page still loads every version with its text (needed by the editor's history); the billing page's
  per-package fit check is still one cheap RPC per package, run only for a company that has not paid yet.

## Round 5: search audit (migration 0069)
Every search box was reviewed for behaviour and database cost. Found and fixed:
* **Arabic spellings never matched** («احمد» vs «أحمد», «مدرسه» vs «مدرسة», Arabic vs western digits in phones). New `ar_norm()` + expression
  trigram indexes; used by the customers / suppliers / products lists (`search_entity_page`, one database call returns the page of ids + the total)
  and by the top-bar search.
* **Lists broke on punctuation:** the customers / suppliers / products pages put the raw text inside a PostgREST `or(...)`, so a "," or ")" made the
  request fail and the list came back empty. Now the search goes through the function; if it is unavailable the page uses a safe filter.
* **Top-bar search (`global_search`):** "%" and "_" were wildcards; barcodes were not searched (the products page does); results are now "starts
  with what you typed" first. Client: a slow reply for «ab» could overwrite the answer for «abc» (stale-response guard added), errors showed as
  "no results" (now "search failed"), Escape closes, Enter opens the best match, accessibility attributes.
* **List search box:** when the URL changed from outside (clicking a top-bar result that opens `?q=…`, or the back button) the box kept the old text
  while the list was filtered by the new one; typed searches also added one history entry per pause. Now it follows the URL and uses `replace`.
* **Missing indexes:** phone, SKU and barcode searches scanned the whole company; now indexed. Return-invoice picker: `_`/quotes stripped too.
* Already fine, unchanged: 350 ms / 250 ms debounce with a stale-response guard in the invoice picker; invoice-number search (escaped, trigram
  index); admin searches (database-side, paged, submit-button style by design).
* Not changed: debts / party-balance / warehouse-orders reports search through their own SQL (wildcards stripped, no Arabic folding yet);
  names are matched as one contiguous text (not word-by-word).
* Apply `0069_search_arabic_and_indexes.sql` BEFORE deploying the code (without it the lists fall back to the plain filter and the top bar keeps
  its old behaviour). Tests: `npm run test:unit` (entity-search), DB test `119_search_test.sql` (not run: no Postgres here).
