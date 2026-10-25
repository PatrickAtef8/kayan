// A table that stays readable on every screen.
//   - phones (and tablets, when there are many columns): one card per row, each value labelled by its column header,
//     any action column (empty header) shown as a button row at the bottom of the card;
//   - larger screens: the classic table, scrolling sideways inside its own box instead of stretching the page.
type Column<T> = { header: string; render: (row: T) => React.ReactNode };

export function DataTable<T>({ columns, rows, getRowKey, emptyLabel = "لا توجد بيانات بعد", rowClassName }: { columns: Column<T>[]; rows: T[]; getRowKey: (row: T) => string; emptyLabel?: string; rowClassName?: (row: T) => string }) {
  if (rows.length === 0) return <div className="rounded-2xl border border-dashed border-borderSoft bg-white p-8 text-center text-sm text-charcoal/45 sm:p-12">{emptyLabel}</div>;

  // wide tables (many columns) switch to the table later, so they never need a long sideways scroll on a tablet
  const many = columns.length > 6;
  const cardsOnly = many ? "lg:hidden" : "md:hidden";
  const tableOnly = many ? "hidden lg:block" : "hidden md:block";
  const dataColumns = columns.filter((c) => c.header);
  const actionColumns = columns.filter((c) => !c.header);

  return (
    <>
      <div className={`space-y-3 md:grid md:grid-cols-2 md:gap-3 md:space-y-0 ${cardsOnly}`}>
        {rows.map((row) => (
          <div key={getRowKey(row)} className={`min-w-0 rounded-2xl border border-borderSoft/80 bg-white p-4 shadow-[0_10px_30px_rgba(28,28,26,0.035)] ${rowClassName?.(row) ?? ""}`}>
            <dl className="divide-y divide-borderSoft/60">
              {dataColumns.map((c) => (
                <div key={c.header} className="flex items-start justify-between gap-4 py-2 text-sm first:pt-0 last:pb-0">
                  <dt className="shrink-0 pt-0.5 text-xs text-charcoal/45">{c.header}</dt>
                  <dd className="min-w-0 max-w-[70%] break-words text-end text-charcoal">{c.render(row)}</dd>
                </div>
              ))}
            </dl>
            {actionColumns.map((c, i) => (
              <div key={`action-${i}`} className="mt-3 flex flex-wrap items-center gap-1 border-t border-borderSoft/60 pt-3 [&>div]:flex-wrap">{c.render(row)}</div>
            ))}
          </div>
        ))}
      </div>

      <div className={`overflow-hidden rounded-2xl border border-borderSoft/80 bg-white shadow-[0_10px_30px_rgba(28,28,26,0.035)] ${tableOnly}`}>
        <div className="table-scroll overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-borderSoft/80 bg-paper/50 text-charcoal/40">
                {columns.map((c, i) => <th key={`${c.header}-${i}`} className="whitespace-nowrap px-4 py-3.5 text-start text-[0.6875rem] font-medium lg:px-5">{c.header}</th>)}
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={getRowKey(row)} className={`border-b border-borderSoft/60 transition-colors last:border-0 hover:bg-sageSoft/20 ${rowClassName?.(row) ?? ""}`}>
                  {columns.map((c, i) => <td key={`${c.header}-${i}`} className="whitespace-nowrap px-4 py-4 align-middle text-charcoal lg:px-5">{c.render(row)}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
