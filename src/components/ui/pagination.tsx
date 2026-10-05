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

  return (
    <div className="mt-4 flex items-center justify-between text-xs text-charcoal/45">
      <span dir="ltr">
        {from}–{to} من {totalCount}
      </span>
      <div className="flex items-center gap-1.5">
        <button
          onClick={() => goTo(page - 1)}
          disabled={page <= 1}
          className="flex h-8 w-8 items-center justify-center rounded-lg border border-borderSoft text-charcoal/50 disabled:opacity-30 hover:enabled:border-sage hover:enabled:text-sage"
        >
          <ChevronRight size={14} strokeWidth={2} />
        </button>
        <span>
          {page} / {totalPages}
        </span>
        <button
          onClick={() => goTo(page + 1)}
          disabled={page >= totalPages}
          className="flex h-8 w-8 items-center justify-center rounded-lg border border-borderSoft text-charcoal/50 disabled:opacity-30 hover:enabled:border-sage hover:enabled:text-sage"
        >
          <ChevronLeft size={14} strokeWidth={2} />
        </button>
      </div>
    </div>
  );
}
