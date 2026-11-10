"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { Search, X } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";

// A list's search box: types, waits a short moment after the LAST keystroke, then puts the text in the URL (?q=) so the server filters.
// The page is NEVER blocked or dimmed while the server answers: the router call runs inside a transition (the current list stays on screen
// and stays clickable), and only a small spinner inside the box shows that a search is in flight.
export function SearchBox({ paramName = "q", placeholder = "بحث..." }: { paramName?: string; placeholder?: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const urlValue = searchParams.get(paramName) ?? "";
  const [value, setValue] = useState(urlValue);
  const [searching, startSearch] = useTransition();

  // Follow the URL when it changes from OUTSIDE this box (a top-bar search result that opens ?q=…, the back button): before, the box kept
  // showing the old text while the list was already filtered by the new one. The URL changes this box itself caused are ignored, so
  // typing is never overwritten by an older value coming back.
  const [lastPushed, setLastPushed] = useState(urlValue);
  const [seenUrl, setSeenUrl] = useState(urlValue);
  if (urlValue !== seenUrl) {
    setSeenUrl(urlValue);
    if (urlValue !== lastPushed) {
      setLastPushed(urlValue);
      setValue(urlValue);
    }
  }

  useEffect(() => {
    // Nothing to do when the box already matches the URL (first render, or a deep link like ?q=x&page=3): pushing would re-render
    // the page on the server for no reason and reset the pagination to page 1.
    const wanted = value.trim();
    if (wanted === urlValue) return;
    const handle = setTimeout(() => {
      const params = new URLSearchParams(searchParams.toString());
      if (wanted) params.set(paramName, wanted);
      else params.delete(paramName);
      params.delete("page"); // a new search always starts back at page 1
      const href = `${pathname}?${params.toString()}`;
      setLastPushed(wanted);
      // replace, not push: every pause while typing would otherwise add a history entry and the back button would walk through them
      startSearch(() => router.replace(href, { scroll: false }));
    }, 180);
    return () => clearTimeout(handle);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  return (
    <div className="flex h-10 w-full min-w-0 items-center sm:max-w-xs gap-2 rounded-xl border border-borderSoft bg-white px-3">
      <Search size={14} className="shrink-0 text-charcoal/35" strokeWidth={2} />
      <input type="search" enterKeyHint="search" aria-label={placeholder} value={value} onChange={(e) => setValue(e.target.value)} placeholder={placeholder} className="w-full bg-transparent text-sm text-charcoal outline-none placeholder:text-charcoal/35 [&::-webkit-search-cancel-button]:hidden" />
      {searching && <Spinner size={13} />}
      {value && (
        <button type="button" aria-label="مسح البحث" onClick={() => setValue("")} className="shrink-0 text-charcoal/30 hover:text-charcoal">
          <X size={13} strokeWidth={2} />
        </button>
      )}
    </div>
  );
}
