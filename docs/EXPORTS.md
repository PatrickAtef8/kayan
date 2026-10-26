# Exports (Excel + PDF)

Kayan exports every report as a formatted **Excel (.xlsx)** or **PDF** file. There is no CSV anywhere in the product and
import is postponed (see below).

## How a report gets its export buttons

```tsx
<ExportButtons
  filename={`مبيعات-الأصناف-${from ?? "الكل"}-${to ?? "الآن"}`}   // required: file name (no extension)
  title="مبيعات حسب الصنف"                                          // title shown in the file
  subtitle={rangeText(from, to)}                                   // period / filter line
  headers={["الصنف", "الكمية", "صافي الإيراد"]}                      // required
  rows={rows.map((r) => [r.name, r.qty, r.revenue])}               // required
  kinds={["text", "qty", "money:sum"]}                             // one per header — see below
  summary={[{ label: "صافي المبيعات", value: total }]}             // optional key figures
  notes={["* الأرصدة الموجبة مستحقة لنا."]}                         // optional footnotes
/>
```

`kinds` says what each column is, so Excel gets real numbers/dates and the PDF aligns and formats them:

| kind | use for | Excel | PDF |
|---|---|---|---|
| `text` | names, descriptions | text, wraps | right-to-left |
| `code` | SKU, barcode, phone, reference | text (`0100…` keeps its zero) | left-to-right, centred |
| `date` | `YYYY-MM-DD` | real date | `YYYY-MM-DD` |
| `int` | counts | `#,##0` | Arabic-Indic digits |
| `qty` | quantities | decimals only if the data has them | same |
| `money` | amounts | `#,##0.00`, negatives red | same, negatives red |
| `percent` | share in percent points (12.5 = 12.5 %) | `0.0%` | `١٢٫٥٪` |

Add `:sum` (e.g. `money:sum`) to get a totals row. Totals are computed from the rows, so they always match the table.
Without `kinds` the types are inferred from the data (works, but money columns lose their fixed 2 decimals).

The company name in the file header comes from the signed-in organisation (`ExportOrgProvider` in the dashboard shell).

## Where the code is

| file | role |
|---|---|
| `src/components/ui/export-buttons.tsx` | the two buttons, busy / error states, download |
| `src/lib/export/model.ts` | shared types, column resolving, totals, number formatting |
| `src/lib/export/excel.ts` | workbook builder (`write-excel-file`) |
| `src/lib/export/excel-extras.ts` | auto-filter, print titles, fit-to-width, footer, tab colour (edits the sheet XML in schema order) |
| `src/lib/export/pdf.tsx` | PDF builder (`@react-pdf/renderer`) |
| `public/fonts/` | IBM Plex Sans Arabic (OFL licence) used inside the PDF |

Both builders are loaded only when a button is clicked, so they are not part of any page's bundle.

## Things to know

* **Row limit for PDF: 800** (`MAX_PDF_ROWS`). A PDF is laid out in the browser at roughly 20 ms per row of 9 columns, so a
  very long report would freeze the tab; above the limit the PDF button asks the user to use Excel (no limit, ~0.3 s for 2 000 rows).
* **Fresh fonts per PDF.** `@react-pdf` keeps loaded fonts for the life of the page and a later document can lose letters
  that an earlier one used. `registerFonts()` therefore registers its own copy under a unique family name on every build — do not
  "optimise" that into a one-time registration.
* **No direction marks in PDF text.** `formatMoney()` wraps numbers in direction isolates for the screen; PDF fonts draw them
  as stray glyphs, so the PDF uses `formatNumber()` from `model.ts` (same digits) and lays numbers out left-to-right.
* Exports contain only what the page already shows to that user (same rows, same financial-column gating), so permissions and
  tenant isolation are unchanged.
* Excel cells are typed (text vs number vs date), so a name starting with `=` is never executed as a formula.
  The old CSV export had that problem (SECURITY_AUDIT_V2 finding M2); it is gone with CSV.

## Invoices (sales and purchases)

Two different things, both available from the **sales invoices** and **purchase invoices** pages:

1. **One invoice as a document** — PDF or Excel, from the two small icons on each invoice row and from the buttons in the
   "تفاصيل الفاتورة" dialog (`InvoiceExportButtons`). The document has the company header, invoice number, date, customer/supplier,
   warehouse / rep / payment method, status, the items (quantity, bonus, unit price, discount, net), the totals block (item,
   invoice, tier and cash discounts, tax, total, returns, cash refunds, paid), the payment history, a highlighted remaining
   balance (or "تم السداد بالكامل"), signature lines and a page footer. It never contains cost, profit or commission. It is built in
   the browser from the row the user already sees, so it needs no extra permission and no server call.
   Code: `src/lib/export/invoice-model.ts` (row → document), `invoice-pdf.tsx`, `invoice-excel.ts`.
2. **The whole list** — Excel or PDF of every invoice matching the page's search and date filters (not only the 20 on screen),
   with totals. Needs the `reports.export` permission, enforced in the server action
   (`src/app/dashboard/invoice-export-actions.ts`), capped at 2 000 invoices (the file says so when it was cut).

## PDF layout rules (learned the hard way)

* Header cells use the **same alignment as the values under them** — a centred header over right-aligned numbers looks misaligned.
* Never put a right-to-left `<Text>` directly in a flex **row**: it loses width and its first letters disappear. Put each `<Text>`
  in a `<View>` with an explicit width (the tables do), and never build a sentence from pieces in a row.
* A date inside Arabic text can come out reversed ("25-10-2026"); `bidiSafe()` wraps dates in invisible left-to-right marks.
* Text with no Arabic letters ("Global Foods Ltd.") is laid out left-to-right, otherwise its full stop lands on the wrong side.

## Import (postponed)

The CSV import screens (customers, suppliers, products) were removed. The server actions that validate and insert rows
(`importCustomers`, `importSuppliers`, `importProducts`) were kept, unchanged apart from their names, for the Excel import that
will replace them.
