# 0052 — collections and stock-shortage reports: verified edge cases

Run `supabase/migrations/0052_collection_lock_and_shortage_accuracy.sql` once (Supabase → SQL Editor). Re-runnable.

## What was verified (and how)
Real parallel database sessions: `supabase/tests/concurrency_collections_check.sh`.
Sequential checks (77): `supabase/tests/108_collections_shortages_edge_cases_test.sql`.

| Question | Before | Now |
|---|---|---|
| Two simultaneous collections of the full balance | **Both committed**: 2 000 collected on a 1 000 invoice, 2 000 in the treasury | Second waits for the first, then is refused; 1 collection, 1 treasury movement |
| Payment updates balance / treasury / commission / notifications | Correct | Correct (now asserted by tests) |
| Rep collects only from own customers (database level) | Correct | Correct (another rep, unlinked, deactivated, storekeeper, direct insert all refused) |
| Same shortage, second purchase invoice | No protection | Asked to confirm only when purchases already on their way cover the need; a purchase that is still needed is never blocked |
| Stock added once on receipt | Correct | Correct (two storekeepers at once: +50 once) |
| Purchase cancelled / partly received | Report stayed «جاري التجهيز» with a stale note | Report follows the invoice: note shows available / coming / missing; back to «جديد» when no purchase is left |
| Closing a report | Auto-close was right; **manual close had no stock check** | Manual close refused unless SELLABLE stock (on hand − promised to open sales − expired) covers the need |

## "تم توفيره من مصدر آخر"
Means: the quantity already reached the warehouse from another source (transfer, purchase not linked to the report, stocktake).
The system measures the sellable stock at that moment; below the need it refuses and shows both numbers. Stock promised to
open sales does not count. The measured quantity is written to the audit log.

## Tests adjusted on purpose
`102`, `103` and security case `90` closed a report by hand without any stock; they now prove the refusal first and then
bring the stock in. Test `106` had a missing login line (test bug, not a system bug).
