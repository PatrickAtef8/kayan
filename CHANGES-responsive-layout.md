# Responsive layout pass

- globals.css: responsive root font size (16 / 17.5 / 18.5 / 20px), overflow guard, `.num` + LTR-run rules, 16px inputs on touch, zero-specificity gap for justify-between rows.
- Dashboard shell/sidebar/topbar: sidebar becomes a permanent panel at 1024px (was 768px); search visible on phones.
- DataTable: cards on phones/tablets (table from md, or lg for >6 columns), table scrolls inside its own box.
- Modal / ConfirmDialog: bottom sheet on phones, internal scroll, safe-area padding.
- New `StatValue`: KPI numbers that scale with length, keep the unit beside them and align with their label.
- Applied to dashboard home, rep home, chart summary, inventory total, warehouse tiles.
- PageHeader, Pagination (Arabic digits, correct order), DateRangeFilter, SearchBox, tabs, payment/return/product modals, signup module grid.
- Sales chart: screen-reader table no longer widens the page.

## Reports follow-up
- Payroll (المرتبات), المناديب and the single-rep report now use the same month picker as the dashboard / treasury (`PeriodSelect`, month-only mode). Old `?month=YYYY-MM` links still work.
- All native `<select>` boxes (payment method in sales/purchases forms and payment modals, return condition/reason, debts rep filter) replaced by `ModernSelect`, like Products.
- Reports sub-tabs (sales: by rep / channel / product, debts, inventory): new `loading.tsx` per section so only the content area shows the skeleton and the tab bar stays; clicked tab highlights instantly.
- Period picker now opens towards the side with room inside the page content area, so it never hides behind the sidebar.
- Customers page: the add-customer form used col-span-4 inside a 1-column grid, which made hidden extra columns and squeezed the fields (labels stacked letter by letter on phones). Fixed; the other add forms now go 1 → 2 → 3/4 columns, and the expense form's wide row spans the full grid.

## المركز المالي: one card
- The two cards (رأس المال العام / صافي المركز المالي) shared five lines and differed only by "أصول أخرى". Kept one card, titled رأس المال العام, computed from the complete formula (`net_position`): inventory + customer debts + cash + other assets − supplier debts − other liabilities.
- New migration `0057_general_capital_complete.sql`: `report_financial_position` now returns `general_capital` = inventory + receivables + cash + other assets − payables − other liabilities (same value as `net_position`; both keys kept). Run it with the other migrations.
- `supabase/tests/10_flows_test.sql` expectations updated (17,550 → 18,050; 19,550 → 20,050) and the audit doc note adjusted. These tests were not run here (no Postgres in this environment) — run them after applying 0057.

## Cash vs. other assets/liabilities, and unpaid commissions
- Decision: other assets/liabilities stay in المركز المالي and are NOT moved to the treasury. The treasury holds cash only (every movement is real money); a car, equipment, a loan or late rent are not cash and would corrupt the cash balance and the cash reconciliation. They are now labelled "غير نقدية" with a short rule + example (cash loan = treasury "دخل" + a liability here), and the treasury form carries the reverse hint.
- Migration `0058_capital_includes_unpaid_commissions.sql`: رأس المال العام also subtracts earned-but-unpaid rep commissions (`rep_commission_balances`, positive balances only), shown as "عمولات مناديب مستحقة". New key `commissions_payable`.
- `10_flows_test.sql` capital assertions now subtract `commissions_payable`, plus one assertion tying it to `rep_commission_balances`. Not run here (no Postgres) — run after applying 0057 and 0058.

## Wording clean-up
- المركز المالي: removed the "تقرير إداري ... راجع المحاسب" sentence.
- تقرير الخزنة: "مطابقة الخزنة مع المستندات" rewritten in plain language. Healthy = one green line "أرصدة الخزنة سليمة" (details behind "عرض التفاصيل"); mismatch = a red card that lists only the lines that differ, with what it means. The word "مستندات" is gone ("العمليات المسجلة" instead).

## Negative amounts: one format, always red
- Rule: minus sign "-" directly before the digits (to their left), e.g. `-٨٠٠٫٠٠ ج.م`; the number is an isolated left-to-right unit (U+2066…U+2069) so Arabic text around it can never move the sign. Anything below zero is red.
- Cause of the mismatch: ~30 screens formatted amounts with `toLocaleString("ar-EG")`, which puts an Arabic letter mark before the minus sign (sign drifted to the end in some cells); only a few used `formatMoney`.
- `lib/money.ts`: `formatMoney` now emits the isolated, sign-first form (+ optional decimals) and `negativeClass`. Every local `money()` helper (and lib/party-reports, lib/sales-report, notifications) now calls it.
- `<Money>` (number + ج.م as one unit, `!text-rose` when negative) is used for the amounts in reports, tables, cards, payment modals, P&L rows and the profit/margin figures. Stat/StatValue/chart tooltips follow the same rule.

## Warehouse keeper screen (and topbar regression)
- Topbar: the bell/avatar group is pushed to the far left again (`mr-auto`; my earlier `ml-auto` did nothing in RTL). This is why the notifications panel opened towards the sidebar and was cut off. The panel now sits fully inside the page area on desktop, tablet and phone.
- Warehouse orders: each item is a card on phones (required / done / remaining + the quantity field); on larger screens the table has aligned headings and spacing; the confirm button is full width on phones.
