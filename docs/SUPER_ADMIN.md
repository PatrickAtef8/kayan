# Super Admin dashboard (`/admin`)

A separate back office for the platform owner. It adds to Kayan; it changes nothing that exists: the public site, the company
dashboards, XPay billing, RLS and tenant isolation are as they were. With no override saved, every price, limit and module is
exactly what is written in `src/config/pricing.config.ts`.

## Set up your admin account (once)

1. **Create your account normally** at `/signup` (use an email you control; confirm it). Sign in once.
2. In Supabase → Authentication → Users, copy your **User UID**.
3. Set it as an environment variable on the server (Vercel → Settings → Environment Variables, and `.env.local` locally):
   `SUPER_ADMIN_USER_IDS=<your-uid>` (comma-separate for more than one person).
   *(Alternative: `SUPER_ADMIN_EMAILS=you@example.com` — honoured only for a **confirmed** email. The id is safer: nobody else
   can ever register it. If you use the email form, create the account first and keep "Confirm email" enabled in Supabase.)*
4. Make sure `SUPABASE_SERVICE_ROLE_KEY` is set (the admin area uses it, server-side only) and run migration
   `0061_super_admin.sql` (additive).
5. Redeploy / restart so the variable is read, sign in, and open **`/admin`**.

Not signed in → redirected to login. Signed in but not an admin → a plain 404. The check runs on the server for every page
**and** every action, and the database functions behind it only accept the service role, so a normal user cannot reach any of it
from the browser or by calling the API directly.

## Your account is never asked to pay (and everyone else is)

* **You (an id in `SUPER_ADMIN_USER_IDS`)** are never gated and never charged: the dashboard always opens, the billing page only says
  so, `/checkout` says so, and the payment actions refuse your account.
* **Your demo company** is given free access (a complimentary license) automatically the first time you open your dashboard, so the demo
  reps / storekeepers you add can work. Their access follows that real subscription — it is **not** inherited from you. Revoking the free
  access in /admin/companies locks them (and it is re-granted the next time *you* open the dashboard).
* **Everyone else** cannot open the dashboard until their company has paid: the owner lands on the package page, reviews the order on
  `/checkout`, pays at XPay, and is let in as soon as the payment is verified. Reps / storekeepers of an unpaid company see a notice.
* **Legal pages** (/admin/legal): Terms, Privacy, Refund & Cancellation (Arabic + English), the contact number and company identity; every save is a new version. They are drafts until a lawyer reviews them (docs/LEGAL_REVIEW.md).
* **Grace period** (/admin/packages): on/off and hours (default 24; 0 = lock immediately). See docs/BILLING.md.
* **Two buttons** appear only for you: «لوحة التحكم» (the whole app, as an owner sees it) and «لوحة تحكم الأدمن» (`/admin`), in the top bar
  of both areas (on a phone: in the account menu).
* To let another company in without payment: `/admin` → Companies → company → «منح وصول مجاني كامل».
* Run migrations `0062`, `0063`, `0064`, `0065` (in this order) **before** deploying the code: without them the gate cannot read the subscription and stays shut.

## What you can do

| Page | |
|---|---|
| **Companies** | all companies: owner, registration date, representatives / storekeepers / other members, warehouses, package, payment status; search by name or owner email; per-company detail (team, warehouses, license, last payments) and the free-access switch |
| **Users** | all accounts with their companies and roles, registration and last sign-in; **deactivate / reactivate** (reversible, nothing is deleted) and **delete** |
| **Packages & prices** | edit the three prices, member/warehouse limits and modules of Basic / Professional / Complete; see what changed from the shipped values; restore the shipped configuration or any earlier version; full change history |

**Deleting users — what is allowed.** Only accounts with no company, or whose invitation was never accepted, can be erased. Anyone
who works (or worked) inside a company is part of that company's invoices, stock movements and audit trail, and an owner is part
of its ownership, so those accounts can only be **deactivated**. This is a safety rule, not legal advice: accounting-record
retention and personal-data erasure rules vary — decide those cases with your counsel. You can never deactivate or delete yourself
or another Super Admin. A deactivated user cannot sign in or refresh a session; a session already open lasts until its token
expires (Supabase default: up to one hour).

## How pricing changes take effect (no redeploy)

Saved values live in `platform_pricing_config`, readable by everyone (prices are public) and writable only through the admin
functions. Every request that **shows** a price (`/pricing`, `/dashboard/billing`) or **charges** one (checkout) reads them first, and
falls back to the shipped values if anything is missing or invalid. So:

* a price change applies to the next page view and the next checkout; an XPay payment page already open keeps the amount it was created with
  (it expires within an hour, and a changed amount starts a fresh checkout);
* limits and modules go into the license of each **new** purchase. Companies that already bought keep what they bought, unless you
  tick **"apply to companies that already bought it"** when saving. That never disables anything a company already uses: limits only
  stop new additions (the database enforces them);
* prices never change what an existing customer already paid; the hosting/subscription renewal price follows the current price list.

**Hosting vs maintenance.** In Kayan's billing today, hosting and maintenance are one monthly fee, not two. The editor shows
that one fee (so as not to change billing behaviour). Separate lines would be a billing change; say if you want it.

## Tests

`npm run test:billing` (override resolution, safe fallbacks, validation, admin allow-list) and
`supabase/tests/113_super_admin_test.sql` (service-role-only access, config save/apply/reset, companies overview, free licenses, delete rules).
