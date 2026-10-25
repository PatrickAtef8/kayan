"use client";

import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { ChevronRight, ChevronLeft } from "lucide-react";
import { startNavigation } from "@/lib/navigation-state";

export function Pagination({ page, pageSize, totalCount }: { page: number; pageSize: number; totalCount: number }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const totalPages = Math.max(1, Math.ceil(totalCount / pageSize));

  if (totalCount <= pageSize) return null;

  function goTo(nextPage: number) {
    const params = new URLSearchParams(searchParams.toString());
    if (nextPage <= 1) params.delete("page");
    else params.set("page", String(nextPage));
    const href = `${pathname}?${params.toString()}`;
    startNavigation(href);
    router.push(href, { scroll: false });
  }

  const from = (page - 1) * pageSize + 1;
  const to = Math.min(page * pageSize, totalCount);
  const n = (v: number) => v.toLocaleString("ar-EG", { useGrouping: false });

  return (
    <div className="mt-4 flex flex-wrap items-center justify-between gap-x-4 gap-y-2 text-xs text-charcoal/45">
      <span>
        عرض <bdi className="num">{n(from)}–{n(to)}</bdi> من <bdi className="num">{n(totalCount)}</bdi>
      </span>
      <div className="flex items-center gap-1.5">
        <button
          onClick={() => goTo(page - 1)}
          disabled={page <= 1}
          aria-label="الصفحة السابقة"
          className="flex h-9 w-9 items-center justify-center rounded-lg border border-borderSoft bg-white text-charcoal/50 disabled:opacity-30 hover:enabled:border-sage hover:enabled:text-sage"
        >
          <ChevronRight size={14} strokeWidth={2} />
        </button>
        <span className="min-w-[4.5rem] text-center">
          صفحة <bdi className="num">{n(page)}</bdi> من <bdi className="num">{n(totalPages)}</bdi>
        </span>
        <button
          onClick={() => goTo(page + 1)}
          disabled={page >= totalPages}
          aria-label="الصفحة التالية"
          className="flex h-9 w-9 items-center justify-center rounded-lg border border-borderSoft bg-white text-charcoal/50 disabled:opacity-30 hover:enabled:border-sage hover:enabled:text-sage"
        >
          <ChevronLeft size={14} strokeWidth={2} />
        </button>
      </div>
    </div>
  );
}
