export function MarketingFooter() {
  return (
    <footer className="border-t border-borderSoft px-6 py-8">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 text-xs text-charcoal/40 sm:flex-row">
        <div className="flex items-center gap-3">
          <div className="flex h-7 w-7 items-center justify-center bg-charcoal text-xs font-medium text-ivory">ك</div>
          <span>كيان — لإدارة أعمالك</span>
        </div>
        <div className="flex items-center gap-5"><span dir="ltr">تأسس عام ٢٠٢٤ / القاهرة</span><span>© {new Date().getFullYear()} كيان</span></div>
      </div>
    </footer>
  );
}
