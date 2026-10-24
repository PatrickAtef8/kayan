# Kayan — Business Management SaaS

Multi-tenant, modular business management system for the Egyptian market
(Arabic RTL, EGP), built per the SRS in `Kayan.md`. All 7 phases from
`Kayan.md` §64 are implemented, plus a Phase 8 covering two gaps a full
SRS re-audit found afterward (see below).

## Phases

| Phase | Covers | Migration(s) |
|---|---|---|
| 1 | Foundation — auth, organizations, roles/permissions, module toggles, RTL shell | `0001`, `0002` |
| 2 | Master data — customers, suppliers, products, categories, warehouses, pricing | `0004` |
| 3 | Purchases & inventory — purchase invoices, weighted-average costing, stock movements, supplier payments | `0005` |
| 4 | Sales — sales invoices, item-level profitability, commissions, customer collections | `0006` |
| 5 | Operations — treasury/cashbox, expenses, partners & withdrawals, sales representatives | `0007`, `0008` |
| 6 | Reporting — sales/profit, inventory, customer & supplier balances + ledgers, treasury, financial position (رأس المال العام) | `0009` |
| 7 | Production hardening — see below | `0010` |
| 8 | Sales Returns + Settings/Team management — see below | `0011` |

**Phase 6** added the `/dashboard/reports` section (Sales & Profitability,
Inventory, Customers, Suppliers, Treasury, Financial Position) and the
underlying `report_*` RPCs, all permission-gated on `view_financial`
*inside the database*, not just in the UI.

**Phase 7** started from a real audit of Phases 1–5 — attacking the schema
as a second tenant, an under-privileged member, and an anonymous caller —
not just a code read-through. It found and fixed several real
cross-tenant and privilege-escalation issues; see
**`docs/SECURITY_AUDIT.md`** for the full finding list and what changed.
In summary:
- Ledger tables (invoices, payments, treasury, expenses, …) are now
  writable only through the `SECURITY DEFINER` RPCs — no more direct
  `INSERT`/`UPDATE`/`DELETE` that bypasses the business logic.
- RPCs that take a foreign-key argument (a treasury account, an expense
  category, an invoice) now verify it belongs to the caller's own
  organization, closing a real cross-tenant data-manipulation bug.
- The audit log is now actually populated (via triggers, automatically),
  permission-gated (`audit.view`), and immutable.
- Disabled modules are enforced server-side, not only hidden in the nav.
- A duplicate-submission guard rejects an identical financial submission
  within 5 seconds (double-click / retry protection).
- An owner-protection trigger prevents privilege escalation and stops an
  organization from ever being left without an active owner.
- Manual stock adjustment is now a real, audited, permission-gated
  operation (`inventory.adjust`), reachable from the Inventory page.

**Phase 8** followed a second, full re-read of the SRS against the running
app (not just the phases touched so far), which found two genuine MVP
gaps that predated this work: Sales Returns (§27) had no table, RPC, or
UI at all, and there was no way to invite a second user, change a
member's role, or manage organization settings after signup — the
sidebar's "الإعدادات" link was dead (404). Both are now built:

- **Sales Returns** (`/dashboard/sales/returns`, `create_sales_return`):
  a return always references the original invoice; each line is marked
  *resalable* (stock re-enters the same warehouse, blended into its
  weighted-average cost like a purchase would) or *damaged* (no restock,
  the full amount hits profit as a loss). `report_summary`,
  `report_sales_breakdown`, `report_party_ledger`, `report_recent_activity`,
  and `customer_balances` all account for returns. A few things were left
  as documented, sensible defaults rather than silent guesses — see the
  design-decision comments at the top of `0011_returns_and_team.sql`
  (invoice-level discount/tax aren't prorated into a return; a return
  doesn't auto-adjust the original invoice's sales-rep commission).
  Commission and discount/tax proration on returns are worth confirming
  with the business if their accounting policy expects otherwise.
- **Settings & Team** (`/dashboard/settings`): rename the organization,
  toggle modules after onboarding (not just during it), and manage team
  members — list, change role, remove, and add. Adding someone who
  already has a Supabase account works immediately with no extra setup.
  Inviting a **brand-new** person requires a `SUPABASE_SERVICE_ROLE_KEY`
  in `.env.local` (see `.env.example`) — without it, that specific path
  fails with a clear error while everything else keeps working.
  **Invitation emails** are sent by Supabase Auth, so they need (1) a working
  SMTP provider — Supabase's built-in sender only delivers to your own project
  team and is heavily rate-limited, so set Custom SMTP under *Authentication →
  Emails → SMTP Settings* — and (2) `NEXT_PUBLIC_SITE_URL` set to the public
  address of the site (also added to *Authentication → URL Configuration*).
  The link opens `/reset-password`, where the invited person chooses a password. Custom
  per-organization roles (beyond the 5 system templates) were not built
  here; that was never in the MVP scope (§68), just an example in §14.

## Database tests

`supabase/tests/` is a from-scratch test suite that runs against a plain
PostgreSQL database (no Supabase project needed) — it stubs the parts of
Supabase's `auth` schema the migrations depend on, applies every migration
in order, then runs assertion scripts covering:

- `10_flows_test.sql` — a full purchase → sale → collection → payment →
  expense flow, then every report function checked against numbers worked
  out by hand (weighted-average cost, profit, commission, treasury
  balance, رأس المال العام, …), plus permission gating on financial data.
- `20_isolation_test.sql` — tenant isolation (a second organization can
  read or write nothing belonging to the first, through tables or RPCs)
  and privilege escalation (only an owner can manage owners; the last
  owner can't be removed).
- `30_hardening_test.sql` — duplicate-submission rejection, disabled
  modules enforced server-side, audit log population + immutability +
  permission gating, and manual stock adjustment.
- `40_returns_test.sql` — resalable vs. damaged returns (with hand-checked
  stock/cost/profit numbers), over-return rejection, cash refunds,
  tenant isolation, and every report function's returns handling.
- `50_team_test.sql` — listing members, adding an existing user by email,
  completing an invite for a brand-new user, permission gating, tenant
  isolation, and organization/module settings.

Run it against any PostgreSQL 15/16 instance:

```bash
PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres \
  bash supabase/tests/run.sh
```

It only ever creates/drops a database whose name contains `test`,
`scratch`, or `tmp` (default `kayan_test`) — it will refuse to run
against anything that looks like a real database name.

## Setup

1. **Create a Supabase project** at supabase.com.
2. **Run the migrations in order** against your project (Supabase SQL
   Editor, or the Supabase CLI): `0001` through `0011`, in numeric order.
   Skipping the number gap is not allowed — each migration assumes the
   previous ones already ran.
3. **Copy `.env.example` to `.env.local`** and fill in your project's URL
   and anon key (Project Settings → API). Add the service role key too if
   you want to invite brand-new team members (see Phase 8 above).
4. **Install and run:**
   ```bash
   npm install
   npm run dev
   ```
5. Open `http://localhost:3000/signup`, create a company, pick modules,
   and you land on `/dashboard`.

See `DESIGN.md` and `REDESIGN_NOTES.md` for the visual design system and
the reasoning behind the current UI — the templates there are
intentional; don't revert to shadcn/ui defaults.

## Known open items (not gaps introduced by this work, but worth knowing)

A few things flagged in the SRS re-audit were intentionally left for a
later pass, since they were out of scope for what was asked:

- **No search, filtering, or pagination** on any list page (§44, §57) —
  every list fetches all rows unbounded. Fine at today's data volume,
  will need attention before a business accumulates thousands of records.
- **No password-reset flow** (§12) — only login and signup exist.

Monthly Market Offers (§35), file attachments (§55), import/export (§56),
by contrast, are correctly out of scope: none of them are in §68's Final
MVP Scope, and §35 is explicitly gated on a business decision that was
never made (§65). The `/dashboard/offers` page is a placeholder saying so
rather than a 404.
