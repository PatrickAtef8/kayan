// Placeholder shown the moment a page starts loading. `header` adds the page
// title block; sections that already render their own header/tabs in a layout
// (settings, reports) use it without.
export function PageSkeleton({ header = true }: { header?: boolean }) {
  return (
    <div aria-busy="true" aria-live="polite" className="animate-pulse">
      {header && (
        <div className="mb-8 space-y-3">
          <div className="h-3 w-20 rounded bg-charcoal/10" />
          <div className="h-8 w-56 rounded-lg bg-charcoal/10" />
          <div className="h-3 w-72 max-w-full rounded bg-charcoal/5" />
        </div>
      )}
      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {Array.from({ length: 3 }).map((_, i) => (
          <div key={i} className="h-28 rounded-2xl border border-borderSoft bg-white" />
        ))}
      </div>
      <div className="space-y-3 rounded-2xl border border-borderSoft bg-white p-5">
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className="h-9 rounded-lg bg-charcoal/5" />
        ))}
      </div>
    </div>
  );
}
