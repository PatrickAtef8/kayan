# Security audit — Phase 7

Before writing `0010_hardening.sql`, I ran the schema produced by
`0001`–`0009` against a scratch database and tried to actually break it —
as a second tenant, as an under-privileged member, and as an anonymous
caller — rather than only reading the code for issues. Every finding below
was reproduced first, then fixed, then covered by a regression test so it
can't come back silently. The exploit scripts themselves aren't kept in
the repo (no reason to ship working attack payloads); the fixes and the
tests that pin them down are in `0010_hardening.sql` and
`supabase/tests/20_isolation_test.sql` / `30_hardening_test.sql`.

## Findings

### 1. Cross-tenant treasury/expense/collection/payment RPCs (critical)
`record_treasury_movement`, `record_partner_withdrawal`, `create_expense`,
`record_customer_collection` and `record_supplier_payment` all checked that
the **caller** belonged to `org_id` and had the right permission, but never
checked that the **referenced record** (a treasury account, an expense
category, an invoice) actually belonged to that same `org_id`. A member of
Company B could pass Company A's treasury account id into
`record_treasury_movement(orgB, thatAccountId, 'out', 999999, ...)` and the
function would happily post the movement — Company A's cash balance moved,
Company B's audit trail (if it existed yet) recorded it. Reproduced by
creating two organizations, taking a real account id from org A's
`treasury_accounts`, and calling the RPC as an org B member.

**Fix:** every one of these RPCs now checks
`exists (select 1 from <table> where id = <id> and organization_id = org_id)`
before touching the row. Covered by `20_isolation_test.sql` §3.

### 2. `treasury_balances` view ignored organization_id in its join (high)
The view summed movements by `treasury_account_id` alone. Combined with
finding #1 this was double exposure — even read-only, a crafted account id
comparison could leak whether a foreign account existed. Fixed by joining
on `(id, organization_id)` together.

### 3. `ensure_default_treasury_account` was callable by anyone, for any org (medium)
An internal helper with no auth check of its own, but no `REVOKE` either —
Postgres grants `EXECUTE` on new functions to `PUBLIC` by default. Any
authenticated *or anonymous* caller could invoke it for an arbitrary
`org_id` and create a treasury account row in a company they don't belong
to (harmless by itself, but a data-integrity and reconnaissance issue, and
a preview of finding #4). Fixed by revoking `PUBLIC`/`anon` execute and
granting only to `authenticated`, with `alter default privileges` so the
same mistake doesn't reappear on the next function. Applied the same
`REVOKE ... FROM PUBLIC` sweep across every function in `public`.
Covered by `20_isolation_test.sql` §4 and §"anon" section.

### 4. Ledger tables writable directly, bypassing the RPCs entirely (critical)
`0003_grants.sql` granted `INSERT`/`UPDATE`/`DELETE` on `sales_invoices`,
`purchase_invoices`, `customer_collections`, `treasury_movements`,
`expenses`, `inventory_stock`, etc. directly to `authenticated`, gated only
by RLS policies checking the relevant permission. That means a user with
(say) `sales.create` could `UPDATE sales_invoices SET profit_total = 0,
total = 1 WHERE id = ...` directly, bypassing the RPC that computes COGS,
profit, and commission — or `DELETE FROM sales_invoices` and leave
`inventory_stock` exactly where the sale had left it, silently wrong.
Reproduced by updating and deleting a real invoice as its own org's owner.
**This is the same class of bug as #1, just via raw SQL instead of a
crafted RPC argument, and it's the reason report totals could never be
trusted.** Fixed by revoking write grants on every ledger table from
`authenticated` (all writes now go through the `SECURITY DEFINER` RPCs,
which still work — they run as the table owner) and dropping the
now-unreachable write policies.

### 5. Audit log was neither populated, private, nor immutable (high)
Three separate problems in what `0001` shipped:
- Nothing ever inserted a row into `audit_logs` — no trigger, no RPC call.
  The table existed and was fully policy-protected, but empty.
- `audit_select` let every org member read every audit row, with no
  permission check — appropriate for an owner, not for a sales rep.
- `0003` granted `INSERT` on `audit_logs` to `authenticated` directly, so
  any member could insert a **forged** row — e.g. attributing an action to
  someone else, or write a fake "backup completed" row to paper over a real
  deletion.

**Fix:** a new `audit.view` permission (owner/admin/accountant by default);
`INSERT` revoked from `authenticated` entirely; an immutability trigger
that rejects any `UPDATE`/`DELETE` even by the table owner; and a generic
`audit_row_change()` trigger wired onto every ledger and configuration
table so rows are written automatically and can't be skipped by a code
path that forgets to call an audit function. Sales/purchase invoices use a
deferred constraint trigger so the row captures the finished invoice
(after its totals are computed), not the empty header. Covered by
`30_hardening_test.sql`.

### 6. Disabled modules were a UI convenience only (medium)
The sidebar hid nav items for disabled modules, but nothing stopped a
direct `create_sales_invoice(...)` call (or a raw `INSERT`) for a module
the organization never enabled — including one it explicitly disabled
after trying it. The SRS is explicit that frontend hiding isn't
sufficient (§11). Fixed with a `BEFORE INSERT` trigger
(`enforce_module_enabled`) on every module-gated table, which fires for
direct inserts and for the RPCs alike. Core modules (products, warehouses,
reports) are exempt — a business can't function without them. Covered by
`30_hardening_test.sql`.

### 7. No double-submission protection anywhere (medium)
Nothing stopped two rapid identical financial submissions — a double
click, a retry after a timeout, two tabs open. Forms already disable their
submit button while pending, but that's client-side only and doesn't
survive a retried request. Fixed with a server-side guard that rejects an
identical submission (same organization, same user, same key columns)
within 5 seconds, using a per-key advisory lock so two genuinely
concurrent identical requests are serialized rather than racing past each
other. **Honest limitation:** it compares a fixed set of columns per
table, not a client-supplied idempotency key, so two distinct sales that
happen to share every compared column within the same 5 seconds would also
be refused — acceptable for this trade-off, but worth knowing if a
support ticket ever reports a "phantom" rejection. Covered by
`30_hardening_test.sql`.

### 8. No protection against privilege escalation on organization membership (high)
Anyone with generic `organization_users` write access (there wasn't a
dedicated one, but nothing stopped a member from reasoning their way into
one) could add themselves as another org's owner, remove the only owner
and orphan the organization, or demote the last owner. Fixed with a
`protect_org_owners()` trigger: only an existing owner may add, promote,
demote, disable, or remove an owner, and the last active owner can never
be removed or demoted through the API (service-role/operator actions,
where `auth.uid()` is null, are unaffected). Covered by
`20_isolation_test.sql` §5.

### 9. Manual stock editing had no safe path (medium — completeness gap, not an exploit)
The `inventory.adjust` permission existed in the permission catalog from
Phase 1 but nothing implemented it: the only way to adjust
`inventory_stock` was a direct table write, which is both unaudited and
(after fix #4) no longer possible at all. The SRS requires manual stock
editing to be restricted and audited (§20). Added
`adjust_inventory_stock()`: permission-gated, requires a reason, refuses
to take stock negative, and is fully audited via the same trigger
mechanism as everything else.

### 10. Partners could be added but never edited or deleted (functional bug, not a vulnerability)
`0008` granted only `SELECT`/`INSERT` on `partners`; the Phase 5 UI has
working edit and delete actions that silently failed with "permission
denied" (swallowed by the server action, so it looked like nothing
happened). Found while probing partners for privilege issues. Fixed by
granting `UPDATE`/`DELETE` gated on `treasury.manage`, same as everything
else in Treasury & Partners.

### 11. Onboarding didn't validate module keys and never seeded expense categories (low)
`create_organization()` stored whatever module key string it was given
verbatim (a typo would silently create a dead module toggle), crashed on a
null module array, and — despite `0008`'s own comment promising it —
never created the default expense categories new organizations need
before they can log an expense. Fixed: module keys are validated against
a known list, a null array is treated as empty, and nine standard Arabic
expense categories are seeded for every new organization.

## What I deliberately did not change

- **RLS policies for `SELECT`** on business tables were already correct
  (`organization_id` scoped via `is_org_member()`/`has_permission()`) —
  the audit above is about writes and cross-references, not reads.
- I didn't add a client-supplied idempotency-key mechanism (finding #7);
  the time-window guard is a reasonable default for this app's size, but a
  dedicated idempotency key would be a better long-term fix if duplicate
  submissions ever show up in practice despite it.
- Rate limiting and brute-force login protection are Supabase Auth
  platform concerns, not something this schema controls — worth
  confirming in the Supabase dashboard, but out of scope for a database
  migration.
