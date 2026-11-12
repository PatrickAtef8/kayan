# Blocked customers can't be invoiced + invoice status counts returns

Two database migrations, two new database tests. **No application code (TypeScript) was changed**: the sales form already shows
Arabic database errors as they are (`safeErrorMessage`), and the status badges just read the stored `payment_status`.
Apply the migrations in order before using the new behaviour: `0076`, then `0077`.

## 1. A blocked customer cannot get a new sales invoice — `0076_blocked_customers_cannot_be_invoiced.sql`
* «محظور» (`customers.credit_status = 'blocked'`) used to be only a coloured label in the customers list; any caller could still invoice him.
* A `BEFORE INSERT` trigger on `sales_invoices` (`a_reject_blocked_customer`) now refuses the invoice with an Arabic message
  («العميل "…" محظور — لا يمكن إصدار فاتورة جديدة له. غيّر حالته الائتمانية أولًا.»). It sits in the table, so it covers the owner's form, a rep's form,
  the `create_sales_invoice()` RPC and a direct insert.
* **Not blocked on purpose:** collecting money from him, recording his returns, reading his statement — a blocked customer usually owes money and must be able to pay it.
  «مراقبة» (watch) is a warning only and is unchanged.

## 2. Invoice status counts returns — `0077_invoice_status_counts_returns.sql`
* Before: status was `paid` only when `amount_paid >= total`. An invoice settled by payments **plus a return** owed nothing but stayed «partial» for ever
  (no payment could ever be accepted to push `amount_paid` up to the total).
* Now one rule, the same arithmetic as `sales_invoice_remaining()` / `purchase_invoice_remaining()`:
  `remaining = total − amount_paid − returns + cash refunded`; `remaining <= 0` → **paid**; nothing paid → **unpaid**; otherwise **partial**.
* Applied by triggers, so the four payment functions are not rewritten: a `BEFORE UPDATE OF total, amount_paid, payment_status` trigger on
  `sales_invoices` / `purchase_invoices` recomputes the status, and an `AFTER INSERT/UPDATE` trigger on `sales_returns` / `purchase_returns` recomputes it when a return is recorded.
  A hand-written status that the numbers don't support is put back.
* The same defect existed on the purchase side (payments + returns to the supplier), so it is fixed there too, with the same rule.
* The migration also corrects existing invoices (one `UPDATE` at the end; `updated_at` is not touched).
* Side effect to know: an invoice for which everything was returned and nothing was ever paid is now «paid» (nothing is owed). A never-paid invoice that is only partly returned stays «unpaid».

## Tests
* `supabase/tests/126_blocked_customer_test.sql` — good/watch customers are invoiced; blocked is refused through the RPC, for a cash sale, and for a direct insert;
  collections and returns still work for a blocked customer; un-blocking restores invoicing.
* `supabase/tests/127_invoice_status_returns_test.sql` — truth table of the rule; sales scenarios (paid then returned, returned last, paid then refunded in cash,
  never paid, fully returned, a hand-written «paid»); the purchase equivalent; every invoice of the test company carries the rule's status.
* Full suite: `npm run test:db`.
