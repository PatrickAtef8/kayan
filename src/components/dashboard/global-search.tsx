"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Search, X } from "lucide-react";

type ResultRow = { entity_type: string; entity_id: string; title: string; subtitle: string };

const ENTITY_LABEL: Record<string, string> = {
  customer: "عميل",
  supplier: "مورد",
  product: "منتج",
  sales_invoice: "فاتورة بيع",
  purchase_invoice: "فاتورة شراء",
};

function hrefFor(row: ResultRow): string {
  switch (row.entity_type) {
    case "customer":
      return `/dashboard/customers?q=${encodeURIComponent(row.title)}`;
    case "supplier":
      return `/dashboard/suppliers?q=${encodeURIComponent(row.title)}`;
    case "product":
      return `/dashboard/products?q=${encodeURIComponent(row.title)}`;
    case "sales_invoice":
      return `/dashboard/sales?q=${encodeURIComponent(row.title)}`;
    case "purchase_invoice":
      return `/dashboard/purchases?q=${encodeURIComponent(row.title)}`;
    default:
      return "/dashboard";
  }
}

export function GlobalSearch({ organizationId }: { organizationId: string }) {
  const router = useRouter();
  const containerRef = useRef<HTMLDivElement>(null);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<ResultRow[]>([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    function onOutside(event: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(event.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onOutside);
    return () => document.removeEventListener("mousedown", onOutside);
  }, []);

  // Typing a searchable query starts a load: raise the flag while rendering, not inside the effect.
  const searchable = query.trim().length >= 2;
  const [prevQuery, setPrevQuery] = useState(query);
  if (query !== prevQuery) {
    setPrevQuery(query);
    setLoading(searchable);
  }
  const shownResults = searchable ? results : [];

  useEffect(() => {
    if (!searchable) return;
    const handle = setTimeout(async () => {
      // Loaded on first use so the Supabase browser client (~65 kB gzipped)
      // is not part of every dashboard page's initial JavaScript.
      const { createClient } = await import("@/lib/supabase/client");
      const { data } = await createClient().rpc("global_search", { org_id: organizationId, p_query: query, p_limit: 6 });
      setResults((data as ResultRow[]) ?? []);
      setLoading(false);
    }, 250);
    return () => clearTimeout(handle);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query]);

  function go(row: ResultRow) {
    setOpen(false);
    setQuery("");
    router.push(hrefFor(row));
  }

  return (
    <div ref={containerRef} className="relative hidden w-72 sm:block">
      <div className="flex h-10 items-center gap-2 rounded-xl border border-borderSoft bg-white px-3">
        <Search size={15} className="shrink-0 text-charcoal/35" strokeWidth={2} />
        <input
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          placeholder="بحث عن عميل، مورد، منتج، أو رقم فاتورة..."
          className="w-full bg-transparent text-sm text-charcoal outline-none placeholder:text-charcoal/35"
        />
        {query && (
          <button onClick={() => setQuery("")} className="shrink-0 text-charcoal/30 hover:text-charcoal">
            <X size={14} strokeWidth={2} />
          </button>
        )}
      </div>

      {open && query.trim().length >= 2 && (
        <div className="absolute right-0 z-30 mt-2 w-full overflow-hidden rounded-xl border border-borderSoft bg-white shadow-[0_18px_40px_rgba(28,28,26,0.12)]">
          {loading ? (
            <div className="px-4 py-6 text-center text-xs text-charcoal/40">جارٍ البحث...</div>
          ) : shownResults.length === 0 ? (
            <div className="px-4 py-6 text-center text-xs text-charcoal/40">لا توجد نتائج لـ &quot;{query}&quot;</div>
          ) : (
            <div className="max-h-96 overflow-y-auto">
              {shownResults.map((row) => (
                <button
                  key={`${row.entity_type}-${row.entity_id}`}
                  onClick={() => go(row)}
                  className="flex w-full items-center justify-between border-b border-borderSoft px-4 py-2.5 text-right last:border-b-0 hover:bg-paper"
                >
                  <div className="min-w-0">
                    <p className="truncate text-sm text-charcoal">{row.title}</p>
                    {row.subtitle && <p className="truncate text-xs text-charcoal/40">{row.subtitle}</p>}
                  </div>
                  <span className="shrink-0 rounded-md bg-paper px-2 py-0.5 text-[0.6875rem] font-medium text-charcoal/45">{ENTITY_LABEL[row.entity_type] ?? row.entity_type}</span>
                </button>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
