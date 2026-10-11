"use client";

import { useEffect, useRef, useState } from "react";
import { Check, ChevronDown, Search } from "lucide-react";

export type SearchOption = { value: string; label: string };

// Same look as ModernSelect when closed. When opened it shows a search field
// and a short list fetched on demand (top matches only), so the page never has
// to ship — or the browser render — every record just to fill one dropdown.
export function AsyncSearchSelect({
  value,
  selectedLabel,
  onChange,
  search,
  placeholder = "اختر",
  searchPlaceholder = "ابحث...",
}: {
  value: string;
  selectedLabel?: string;
  onChange: (value: string, label: string) => void;
  search: (query: string) => Promise<SearchOption[]>;
  placeholder?: string;
  searchPlaceholder?: string;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [options, setOptions] = useState<SearchOption[]>([]);
  const [loading, setLoading] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const requestId = useRef(0);

  useEffect(() => {
    const close = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, []);

  // Fetch when opened (empty query = most recent) and, debounced, as the user types.
  const fetchKey = open ? query : null;
  const [prevFetchKey, setPrevFetchKey] = useState<string | null>(null);
  if (fetchKey !== prevFetchKey) {
    setPrevFetchKey(fetchKey);
    if (fetchKey !== null) setLoading(true);
  }

  useEffect(() => {
    if (!open) return;
    const id = ++requestId.current;
    const handle = setTimeout(
      async () => {
        try {
          const result = await search(query);
          if (id === requestId.current) setOptions(result);
        } catch {
          if (id === requestId.current) setOptions([]);
        } finally {
          if (id === requestId.current) setLoading(false);
        }
      },
      query ? 250 : 0
    );
    return () => clearTimeout(handle);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, query]);

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((current) => !current)}
        aria-haspopup="listbox"
        aria-expanded={open}
        className={`flex w-full items-center justify-between rounded-xl border px-3.5 py-3 text-right text-sm outline-none transition-all ${open ? "border-sage bg-white ring-4 ring-sage/10" : "border-borderSoft bg-paper hover:border-sage/60"}`}
      >
        <span className={value ? "text-charcoal" : "text-charcoal/40"}>{value ? selectedLabel ?? placeholder : placeholder}</span>
        <ChevronDown size={17} className={`text-charcoal/40 transition-transform duration-200 ${open ? "rotate-180 text-sage" : ""}`} />
      </button>
      {open && (
        <div className="absolute right-0 z-30 mt-2 w-full rounded-xl border border-borderSoft bg-white p-1.5 shadow-[0_18px_40px_rgba(28,28,26,0.12)]">
          <div className="mb-1.5 flex items-center gap-2 rounded-lg border border-borderSoft px-2.5">
            <Search size={14} className="shrink-0 text-charcoal/35" strokeWidth={2} />
            <input autoFocus value={query} onChange={(e) => setQuery(e.target.value)} placeholder={searchPlaceholder} className="h-9 w-full bg-transparent text-sm text-charcoal outline-none placeholder:text-charcoal/35" />
          </div>
          <div role="listbox" className="max-h-60 overflow-y-auto">
            {loading && options.length === 0 ? (
              <p className="px-3 py-3 text-center text-xs text-charcoal/40">جارٍ التحميل...</p>
            ) : options.length === 0 ? (
              <p className="px-3 py-3 text-center text-xs text-charcoal/40">لا توجد نتائج</p>
            ) : (
              options.map((option) => (
                <button
                  key={option.value}
                  type="button"
                  role="option"
                  aria-selected={option.value === value}
                  onClick={() => {
                    onChange(option.value, option.label);
                    setOpen(false);
                    setQuery("");
                  }}
                  className={`flex w-full items-center justify-between rounded-lg px-3 py-2.5 text-right text-sm transition-colors hover:bg-paper ${option.value === value ? "text-sage" : "text-charcoal"}`}
                >
                  <span>{option.label}</span>
                  {option.value === value && <Check size={14} strokeWidth={2.4} />}
                </button>
              ))
            )}
          </div>
        </div>
      )}
    </div>
  );
}
