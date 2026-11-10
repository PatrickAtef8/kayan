# UX fixes + expense deletion

1. **Number boxes with "0"** — `src/components/ui/input.tsx`: every `type="number"` field now selects its whole value on focus (typing replaces the 0), and a controlled field can be cleared (an empty box no longer snaps back to "0").
2. **Deleting a discount tier (Settings → Discounts)** — now asks for confirmation (names the tier) before deleting.
3. **Duplicate errors** — `src/lib/db-errors.ts` names the repeated field and value («الباركود "123" مستخدم بالفعل…»); products also name the product that already uses the barcode/SKU (`products/actions.ts`).
4. **Search freeze** — `components/ui/search-box.tsx`: runs in a transition, no page dimming / blocking, 180 ms debounce, small spinner inside the box.
5. **Delete expenses** — migration `0075_delete_expenses.sql` (`delete_expense()` removes the expense, its treasury movement and attachment records in one transaction, audit `expense.deleted`), `deleteExpense` action, trash button + confirm dialog in the expenses table, test `supabase/tests/119_delete_expense_test.sql`.
   Apply the migration before using the delete button.
