"use client";

import { useEffect, useRef, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { CalendarDays, ChevronDown, ChevronLeft, ChevronRight } from "lucide-react";
import { startNavigation } from "@/lib/navigation-state";
import { MIN_YEAR, MONTH_NAMES, cairoDate, monthTitle, yearText, yearTitle, type PeriodSel } from "@/lib/report-period";

// Pick ANY month or year (back to MIN_YEAR), or "all time". No days: the period is a URL param, so it keeps
// every other param of the page it sits on (tab, group, warehouse…) and can be bookmarked or shared.
//   month → ?period=month&m=2025-03     year → ?period=year&y=2025     all → ?period=all
//   the current month is the default, so it needs no params at all.
export function PeriodPicker({ sel, monthOnly = false }: { sel: PeriodSel; monthOnly?: boolean }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const ref = useRef<HTMLDivElement>(null);

  const [open, setOpen] = useState(false);
  const [view, setView] = useState<"months" | "years">("months");
  const [align, setAlign] = useState<"left" | "right">("left");
  const today = cairoDate();
  const cy = Number(today.slice(0, 4));
  const curMonth = today.slice(0, 7);
  const selYear = Number(sel.year ?? sel.month?.slice(0, 4) ?? cy);
  const [viewYear, setViewYear] = useState(selYear);
  // Show the chosen period immediately; the server value catches up when the page arrives.
  const [shown, setShown] = useState(sel.title);
  const [prevTitle, setPrevTitle] = useState(sel.title);
  if (sel.title !== prevTitle) {
    setPrevTitle(sel.title);
    setShown(sel.title);
  }

  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", esc);
    return () => {
      document.removeEventListener("mousedown", close);
      document.removeEventListener("keydown", esc);
    };
  }, [open]);

  function toggle() {
    if (!open) {
      const r = ref.current?.getBoundingClientRect();
      // Open towards whichever side has room INSIDE the page content area (not the whole window: on desktop the
      // sidebar covers the right edge, so a picker sitting at the right must open leftwards, never under the menu).
      if (r) {
        const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
        const panelW = window.innerWidth >= 640 ? 19 * rem : Math.max(r.width, 17 * rem);
        const c = document.querySelector("[data-page-content]")?.getBoundingClientRect();
        const minLeft = Math.max(c?.left ?? 0, 0) + 8;
        const maxRight = Math.min(c?.right ?? window.innerWidth, window.innerWidth) - 8;
        const fitsLeftAligned = r.left >= minLeft && r.left + panelW <= maxRight; // panel grows rightwards from the trigger's left edge
        const fitsRightAligned = r.right <= maxRight && r.right - panelW >= minLeft; // panel grows leftwards from the trigger's right edge
        setAlign(fitsLeftAligned ? "left" : fitsRightAligned ? "right" : r.left - minLeft > maxRight - r.right ? "right" : "left");
      }
      setViewYear(selYear);
      setView("months");
    }
    setOpen((o) => !o);
  }

  function go(patch: Record<string, string>, title: string) {
    const p = new URLSearchParams(searchParams.toString());
    for (const k of ["period", "m", "y", "month", "page"]) p.delete(k);
    for (const [k, v] of Object.entries(patch)) p.set(k, v);
    const q = p.toString();
    const href = q ? `${pathname}?${q}` : pathname;
    setShown(title);
    setOpen(false);
    startNavigation(href);
    router.push(href, { scroll: false });
  }

  const pickMonth = (ym: string) => (ym === curMonth ? go({}, monthTitle(ym)) : go({ period: "month", m: ym }, monthTitle(ym)));
  const pickYear = (y: number) => go(y === cy ? { period: "year" } : { period: "year", y: String(y) }, yearTitle(y));

  const pageStart = Math.floor((viewYear - MIN_YEAR) / 12) * 12 + MIN_YEAR;
  const chip = (active: boolean) => `rounded-lg px-2.5 py-1.5 text-xs font-medium transition-colors ${active ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/55 hover:text-charcoal"}`;
  const arrow = "flex h-8 w-8 items-center justify-center rounded-lg text-charcoal/50 transition-colors hover:bg-paper hover:text-charcoal disabled:pointer-events-none disabled:opacity-25";

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={toggle}
        aria-haspopup="dialog"
        aria-expanded={open}
        className={`flex w-full items-center justify-between gap-2 rounded-xl border px-3.5 py-3 text-right text-sm outline-none transition-all ${open ? "border-sage bg-white ring-4 ring-sage/10" : "border-borderSoft bg-paper hover:border-sage/60"}`}
      >
        <span className="flex min-w-0 items-center gap-2 text-charcoal">
          <CalendarDays size={16} className={open ? "text-sage" : "text-charcoal/40"} />
          <span className="truncate">{shown}</span>
        </span>
        <ChevronDown size={17} className={`shrink-0 text-charcoal/40 transition-transform duration-200 ${open ? "rotate-180 text-sage" : ""}`} />
      </button>

      {open && (
        <div
          role="dialog"
          aria-label="اختيار الفترة"
          className={`absolute z-30 mt-2 w-full min-w-[17rem] rounded-2xl border border-borderSoft bg-white p-3 shadow-[0_18px_40px_rgba(28,28,26,0.12)] sm:w-[19rem] ${align === "left" ? "left-0" : "right-0"}`}
        >
          {/* header: ‹ year › (RTL: "previous" sits on the right) */}
          <div className="mb-2 flex items-center justify-between">
            <button type="button" className={arrow} aria-label={view === "months" ? "السنة السابقة" : "السنوات السابقة"} disabled={view === "months" ? viewYear <= MIN_YEAR : pageStart <= MIN_YEAR} onClick={() => (view === "months" ? setViewYear((y) => y - 1) : setViewYear(pageStart - 1))}>
              <ChevronRight size={18} />
            </button>
            <button type="button" onClick={() => setView((v) => (v === "months" ? "years" : "months"))} className="flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-semibold text-charcoal transition-colors hover:bg-paper" aria-label="تغيير السنة">
              {view === "months" ? yearText(viewYear) : `${yearText(pageStart)} – ${yearText(Math.min(pageStart + 11, cy))}`}
              <ChevronDown size={14} className={`text-charcoal/40 transition-transform ${view === "years" ? "rotate-180" : ""}`} />
            </button>
            <button type="button" className={arrow} aria-label={view === "months" ? "السنة التالية" : "السنوات التالية"} disabled={view === "months" ? viewYear >= cy : pageStart + 12 > cy} onClick={() => (view === "months" ? setViewYear((y) => y + 1) : setViewYear(pageStart + 12))}>
              <ChevronLeft size={18} />
            </button>
          </div>

          {view === "months" ? (
            <div className="grid grid-cols-3 gap-1.5">
              {MONTH_NAMES.map((name, i) => {
                const ym = `${viewYear}-${String(i + 1).padStart(2, "0")}`;
                const future = ym > curMonth;
                const selected = sel.kind === "month" && sel.month === ym;
                return (
                  <button
                    key={ym}
                    type="button"
                    disabled={future}
                    aria-pressed={selected}
                    onClick={() => pickMonth(ym)}
                    className={`relative rounded-xl py-2.5 text-sm transition-colors ${selected ? "bg-sage font-medium text-white" : future ? "cursor-not-allowed text-charcoal/20" : "text-charcoal hover:bg-sageSoft"}`}
                  >
                    {name}
                    {ym === curMonth && !selected && <span className="absolute left-1/2 top-1 h-1 w-1 -translate-x-1/2 rounded-full bg-sage" aria-hidden="true" />}
                  </button>
                );
              })}
            </div>
          ) : (
            <div className="grid grid-cols-3 gap-1.5">
              {Array.from({ length: 12 }, (_, i) => pageStart + i).map((y) => {
                const future = y > cy;
                const selected = selYear === y && sel.kind !== "all";
                return (
                  <button
                    key={y}
                    type="button"
                    disabled={future}
                    onClick={() => {
                      setViewYear(y);
                      setView("months");
                    }}
                    className={`rounded-xl py-2.5 text-sm transition-colors ${selected ? "bg-sageSoft font-medium text-sage" : future ? "cursor-not-allowed text-charcoal/20" : "text-charcoal hover:bg-sageSoft"}`}
                  >
                    {yearText(y)}
                  </button>
                );
              })}
            </div>
          )}

          <div className="mt-3 flex flex-wrap gap-1.5 border-t border-borderSoft pt-3">
            <button type="button" className={chip(sel.kind === "month" && sel.isCurrent)} onClick={() => pickMonth(curMonth)}>
              هذا الشهر
            </button>
            {!monthOnly && (
              <>
                <button type="button" className={chip(sel.kind === "year" && sel.year === String(viewYear))} onClick={() => pickYear(viewYear)}>
                  {`كل ${yearTitle(viewYear)}`}
                </button>
                <button type="button" className={chip(sel.kind === "all")} onClick={() => go({ period: "all" }, "كل الوقت")}>
                  كل الوقت
                </button>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
