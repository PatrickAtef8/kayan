import Link from "next/link";

// Shown when a page was opened from a notification / search result for ONE invoice (?inv=<id>).
export function FocusedInvoiceBanner({ clearHref, found }: { clearHref: string; found: boolean }) {
  return (
    <div className="mb-4 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-borderSoft bg-paper px-4 py-2.5 text-sm">
      <span className={found ? "text-charcoal/70" : "text-rose"}>
        {found ? "تعرض الآن الفاتورة المطلوبة فقط" : "الفاتورة غير موجودة أو ليست ضمن ما يمكنك الاطلاع عليه"}
      </span>
      <Link href={clearHref} className="text-sage underline-offset-2 hover:underline">عرض كل الفواتير</Link>
    </div>
  );
}
