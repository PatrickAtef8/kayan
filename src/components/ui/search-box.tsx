"use client";

import { useEffect, useState } from "react";
import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { Search, X } from "lucide-react";
import { startNavigation } from "@/lib/navigation-state";

export function SearchBox({ paramName = "q", placeholder = "بحث..." }: { paramName?: string; placeholder?: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [value, setValue] = useState(searchParams.get(paramName) ?? "");

  useEffect(() => {
    // Nothing to do when the box already matches the URL (first render, or a
    // deep link like ?q=x&page=3) — pushing would re-render the whole page on
    // the server for no reason and reset the pagination to page 1.
    if (value.trim() === (searchParams.get(paramName) ?? "")) return;
    const handle = setTimeout(() => {
      const params = new URLSearchParams(searchParams.toString());
      if (value.trim()) params.set(paramName, value.trim());
      else params.delete(paramName);
      params.delete("page"); // a new search always starts back at page 1
      const href = `${pathname}?${params.toString()}`;
      startNavigation(href);
      router.push(href, { scroll: false });
    }, 350);
    return () => clearTimeout(handle);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  return (
    <div className="flex h-10 w-full max-w-xs items-center gap-2 rounded-xl border border-borderSoft bg-white px-3">
      <Search size={14} className="shrink-0 text-charcoal/35" strokeWidth={2} />
      <input value={value} onChange={(e) => setValue(e.target.value)} placeholder={placeholder} className="w-full bg-transparent text-sm text-charcoal outline-none placeholder:text-charcoal/35" />
      {value && (
        <button onClick={() => setValue("")} className="shrink-0 text-charcoal/30 hover:text-charcoal">
          <X size={13} strokeWidth={2} />
        </button>
      )}
    </div>
  );
}
