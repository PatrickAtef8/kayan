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
