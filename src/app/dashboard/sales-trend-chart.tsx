"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { formatMoney, isNegativeMoney } from "@/lib/money";

// One bucket of the home-page chart. Comes from dashboard_sales_trend (0055), which uses the SAME rules as the
// KPI cards, so the bars add up to صافي المبيعات and the profit line adds up to صافي الربح.
export type TrendPoint = {
  bucket_date: string; // YYYY-MM-DD (first day of the bucket)
  net_sales: number;
  gross_profit: number | null; // null without view_financial
  overhead: number | null; // operating expenses + earned commissions
  net_profit: number | null;
};

type Bucket = "day" | "month";

const compact = new Intl.NumberFormat("ar-EG", { notation: "compact", maximumFractionDigits: 1 });
const pct = new Intl.NumberFormat("ar-EG", { maximumFractionDigits: 0 });

function utc(key: string) {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d));
}
function shortLabel(key: string, bucket: Bucket) {
  return utc(key).toLocaleDateString("ar-EG", bucket === "day" ? { day: "numeric", month: "short", timeZone: "UTC" } : { month: "short", year: "2-digit", timeZone: "UTC" });
}
function fullLabel(key: string, bucket: Bucket) {
  return utc(key).toLocaleDateString("ar-EG", bucket === "day" ? { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" } : { month: "long", year: "numeric", timeZone: "UTC" });
}

// Round the axis to friendly numbers (…٠ / ٢٥٠ / ٥٠٠ / ١٠٠٠…) so the grid lines mean something.
function niceScale(min: number, max: number) {
  const span = Math.max(max - min, 1);
  const raw = span / 4;
  const pow = Math.pow(10, Math.floor(Math.log10(raw)));
  const f = raw / pow;
  const step = (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * pow;
  const lo = Math.floor(min / step) * step;
  const hi = Math.ceil(max / step) * step;
  const ticks: number[] = [];
  for (let v = lo; v <= hi + step / 2; v += step) ticks.push(Math.round(v * 100) / 100);
  return { lo, hi: hi === lo ? lo + step : hi, ticks };
}

const clamp = (n: number, a: number, b: number) => Math.min(b, Math.max(a, n));

export function SalesTrendChart({ points, bucket, canViewFinancial }: { points: TrendPoint[]; bucket: Bucket; canViewFinancial: boolean }) {
  const [active, setActive] = useState<number | null>(null);
  const [show, setShow] = useState({ sales: true, profit: true });
  const [ready, setReady] = useState(false);
  const plotRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const id = requestAnimationFrame(() => setReady(true));
    return () => cancelAnimationFrame(id);
  }, []);

  const n = points.length;
  const showSales = show.sales;
  const showProfit = canViewFinancial && show.profit;

  const model = useMemo(() => {
    const sales = points.map((p) => Number(p.net_sales));
    const profit = points.map((p) => (p.net_profit == null ? null : Number(p.net_profit)));
    const visible: number[] = [0];
    if (showSales) visible.push(...sales);
    if (showProfit) visible.push(...profit.filter((v): v is number => v != null));
    const { lo, hi, ticks } = niceScale(Math.min(...visible), Math.max(...visible, 1));
    const totalSales = sales.reduce((a, b) => a + b, 0);
    const totalProfit = profit.reduce<number>((a, b) => a + (b ?? 0), 0);
    return { sales, profit, lo, hi, ticks, totalSales, totalProfit };
  }, [points, showSales, showProfit]);

  const { sales, profit, lo, hi, ticks, totalSales, totalProfit } = model;
  const toY = (v: number) => ((hi - v) / (hi - lo)) * 100; // % from the top of the plot
  const hasData = sales.some((v) => v !== 0) || profit.some((v) => v != null && v !== 0);

  if (n === 0 || !hasData) {
    return <p className="py-10 text-center text-sm text-charcoal/40">لا توجد مبيعات في هذه الفترة</p>;
  }

  const labelEvery = n <= 8 ? 1 : Math.ceil(n / 6);
  const margin = totalSales > 0 && canViewFinancial ? (totalProfit / totalSales) * 100 : null;
  const linePoints = profit.map((v, i) => (v == null ? null : `${((i + 0.5) / n) * 100},${toY(v)}`)).filter(Boolean).join(" ");
  const summary = `${bucket === "day" ? "المبيعات اليومية" : "المبيعات الشهرية"}: صافي المبيعات ${formatMoney(totalSales)} ج.م${canViewFinancial ? `، صافي الربح ${formatMoney(totalProfit)} ج.م` : ""}`;

  function indexFromPointer(clientX: number) {
    const r = plotRef.current?.getBoundingClientRect();
    if (!r || r.width === 0) return null;
    return clamp(Math.floor(((clientX - r.left) / r.width) * n), 0, n - 1);
  }
  function onKeyDown(e: React.KeyboardEvent) {
    const cur = active ?? n - 1;
    if (e.key === "ArrowRight") setActive(clamp(cur + 1, 0, n - 1));
    else if (e.key === "ArrowLeft") setActive(clamp(cur - 1, 0, n - 1));
    else if (e.key === "Home") setActive(0);
    else if (e.key === "End") setActive(n - 1);
    else if (e.key === "Escape") setActive(null);
    else return;
    e.preventDefault();
  }

  const a = active != null ? points[active] : null;
  const activeLeft = active != null ? ((active + 0.5) / n) * 100 : 0;

  return (
    <div>
      {/* Period totals — the same two numbers as the cards above, so the chart can be checked at a glance */}
      <div className="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat label="صافي المبيعات" value={`${formatMoney(totalSales)} ج.م`} />
        {canViewFinancial && <Stat label="صافي الربح" value={`${formatMoney(totalProfit)} ج.م`} negative={isNegativeMoney(totalProfit)} />}
        {canViewFinancial && margin != null && <Stat label="هامش صافي الربح" value={`${pct.format(margin)}٪`} negative={margin < 0} className="col-span-2 sm:col-span-1" />}
      </div>

      <figure aria-label={summary} className="m-0">
        <div className="flex gap-2" dir="ltr">
          {/* y axis */}
          <div className="relative h-52 w-11 shrink-0 text-[0.625rem] text-charcoal/40" aria-hidden="true">
            {ticks.map((t) => (
              <span key={t} className="absolute right-0 -translate-y-1/2 tabular-nums" style={{ top: `${toY(t)}%` }}>
                {compact.format(t)}
              </span>
            ))}
          </div>

          <div className="min-w-0 flex-1">
            <div
              ref={plotRef}
              tabIndex={0}
              role="group"
              aria-label={`${summary}. استخدم الأسهم للتنقل بين ${bucket === "day" ? "الأيام" : "الشهور"}`}
              className="relative h-52 cursor-crosshair touch-pan-y rounded-lg outline-none focus-visible:ring-2 focus-visible:ring-sage/40"
              onPointerMove={(e) => setActive(indexFromPointer(e.clientX))}
              onPointerDown={(e) => setActive(indexFromPointer(e.clientX))}
              onPointerLeave={(e) => e.pointerType === "mouse" && setActive(null)}
              onFocus={() => setActive((c) => c ?? n - 1)}
              onBlur={() => setActive(null)}
              onKeyDown={onKeyDown}
            >
              {/* grid + zero line */}
              {ticks.map((t) => (
                <div key={t} className={`absolute inset-x-0 border-t ${t === 0 ? "border-charcoal/25" : "border-dashed border-borderSoft"}`} style={{ top: `${toY(t)}%` }} aria-hidden="true" />
              ))}

              {/* active column */}
              {active != null && <div className="absolute inset-y-0 rounded bg-sageSoft/70" style={{ left: `${(active / n) * 100}%`, width: `${100 / n}%` }} aria-hidden="true" />}

              {/* net-sales bars */}
              {showSales &&
                sales.map((v, i) => {
                  const top = toY(Math.max(v, 0));
                  const h = Math.max(Math.abs(toY(Math.min(v, 0)) - toY(Math.max(v, 0))), v === 0 ? 0 : 1);
                  return (
                    <div key={points[i].bucket_date} className="absolute flex justify-center" style={{ left: `${(i / n) * 100}%`, width: `${100 / n}%`, top: 0, bottom: 0 }} aria-hidden="true">
                      <div
                        className={`absolute w-[70%] max-w-[1.5rem] rounded-t-[3px] transition-[top,height,background-color] duration-500 ease-out motion-reduce:transition-none ${active === i ? "bg-sage/45" : "bg-sage/25"}`}
                        style={ready ? { top: `${top}%`, height: `${h}%` } : { top: `${toY(0)}%`, height: "0%" }}
                      />
                    </div>
                  );
                })}

              {/* net-profit line */}
              {showProfit && (
                <>
                  <svg className="pointer-events-none absolute inset-0 h-full w-full overflow-visible" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
                    <polyline points={linePoints} fill="none" stroke="#344E41" strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" vectorEffect="non-scaling-stroke" className={`transition-opacity duration-500 motion-reduce:transition-none ${ready ? "opacity-100" : "opacity-0"}`} />
                  </svg>
                  {profit.map((v, i) =>
                    v != null && (active === i || (i === n - 1 && active == null) || n <= 14) ? (
                      <span
                        key={points[i].bucket_date}
                        className={`pointer-events-none absolute h-2.5 w-2.5 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white ${v < 0 ? "bg-rose" : "bg-sage"} ${active === i ? "scale-125" : ""}`}
                        style={{ left: `${((i + 0.5) / n) * 100}%`, top: `${toY(v)}%` }}
                        aria-hidden="true"
                      />
                    ) : null,
                  )}
                </>
              )}

              {/* tooltip — mouse, touch and keyboard */}
              {a && (
                <div
                  className="pointer-events-none absolute top-1 z-10 w-48 rounded-xl border border-borderSoft bg-white px-3 py-2.5 text-xs shadow-lg"
                  style={activeLeft > 55 ? { right: `${100 - activeLeft + 1.5}%` } : { left: `${activeLeft + 1.5}%` }}
                  dir="rtl"
                  role="status"
                >
                  <p className="mb-1.5 font-medium text-charcoal">{fullLabel(a.bucket_date, bucket)}</p>
                  <Row label="صافي المبيعات" value={a.net_sales} />
                  {canViewFinancial && a.gross_profit != null && <Row label="إجمالي الربح" value={a.gross_profit} muted />}
                  {canViewFinancial && a.overhead != null && <Row label="مصروفات وعمولات" value={-a.overhead} muted />}
                  {canViewFinancial && a.net_profit != null && (
                    <div className="mt-1.5 border-t border-borderSoft pt-1.5">
                      <Row label="صافي الربح" value={a.net_profit} strong />
                    </div>
                  )}
                </div>
              )}
            </div>

            {/* x axis */}
            <div className="relative mt-2 h-4 text-[0.625rem] text-charcoal/40" aria-hidden="true">
              {points.map((p, i) =>
                i % labelEvery === 0 ? (
                  <span key={p.bucket_date} className="absolute -translate-x-1/2 whitespace-nowrap" style={{ left: `${((i + 0.5) / n) * 100}%` }}>
                    {shortLabel(p.bucket_date, bucket)}
                  </span>
                ) : null,
              )}
            </div>
          </div>
        </div>

        {/* legend doubles as show/hide toggles; bars vs line, so colour is never the only cue */}
        <figcaption className="mt-4 flex flex-wrap items-center gap-2 text-[0.6875rem] text-charcoal/60">
          <button type="button" aria-pressed={showSales} onClick={() => setShow((s) => ({ ...s, sales: !s.sales }))} className={`flex items-center gap-1.5 rounded-full border px-2.5 py-1 transition-colors ${showSales ? "border-sage/30 bg-sageSoft/60 text-charcoal" : "border-borderSoft text-charcoal/40"}`}>
            <span className="h-2.5 w-2.5 rounded-sm bg-sage/30" /> صافي المبيعات
          </button>
          {canViewFinancial && (
            <button type="button" aria-pressed={showProfit} onClick={() => setShow((s) => ({ ...s, profit: !s.profit }))} className={`flex items-center gap-1.5 rounded-full border px-2.5 py-1 transition-colors ${showProfit ? "border-sage/30 bg-sageSoft/60 text-charcoal" : "border-borderSoft text-charcoal/40"}`}>
              <span className="h-0.5 w-3.5 rounded bg-sage" /> صافي الربح
            </button>
          )}
          {canViewFinancial && <span className="text-charcoal/35">صافي الربح = إجمالي الربح − المصروفات − العمولات المستحقة</span>}
        </figcaption>

        <table className="sr-only">
          <caption>{summary}</caption>
          <thead>
            <tr>
              <th>الفترة</th>
              <th>صافي المبيعات</th>
              {canViewFinancial && <th>صافي الربح</th>}
            </tr>
          </thead>
          <tbody>
            {points.map((p) => (
              <tr key={p.bucket_date}>
                <td>{fullLabel(p.bucket_date, bucket)}</td>
                <td>{formatMoney(Number(p.net_sales))}</td>
                {canViewFinancial && <td>{p.net_profit == null ? "—" : formatMoney(Number(p.net_profit))}</td>}
              </tr>
            ))}
          </tbody>
        </table>
      </figure>
    </div>
  );
}

function Stat({ label, value, negative, className = "" }: { label: string; value: string; negative?: boolean; className?: string }) {
  return (
    <div className={`rounded-xl bg-paper px-4 py-3 ${className}`}>
      <p className="text-[0.6875rem] text-charcoal/45">{label}</p>
      <p className={`mt-1 text-base font-semibold tracking-tight ${negative ? "text-rose" : "text-charcoal"}`} dir="ltr">
        {value}
      </p>
    </div>
  );
}

function Row({ label, value, muted, strong }: { label: string; value: number; muted?: boolean; strong?: boolean }) {
  return (
    <div className={`flex items-center justify-between gap-3 py-0.5 ${muted ? "text-charcoal/50" : "text-charcoal"} ${strong ? "font-semibold" : ""}`}>
      <span>{label}</span>
      <span dir="ltr" className={`tabular-nums ${strong && isNegativeMoney(value) ? "text-rose" : ""}`}>
        {formatMoney(value)} ج.م
      </span>
    </div>
  );
}
