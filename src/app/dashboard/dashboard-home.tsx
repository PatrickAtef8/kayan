"use client";

import { Money } from "@/components/ui/money";
import { useState } from "react";
import Link from "next/link";
import { m, AnimatePresence } from "framer-motion";
import { MotionProvider } from "@/components/motion-provider";
import { TrendingUp, Wallet, Users, Truck, Boxes, Landmark, ChevronDown, Check, Plus, Clock } from "lucide-react";
import { formatMoney, isNegativeMoney } from "@/lib/money";
import { PeriodPicker } from "@/components/ui/period-picker";
import type { PeriodSel } from "@/lib/report-period";
import { StatValue } from "@/components/ui/stat-value";
import { DashboardAnalytics, type DashboardAnalyticsData } from "./dashboard-analytics";

function money(n: number) {
  return formatMoney(n);
}

type ActivityRow = { occurred_at: string; kind: string; label: string; amount: number };

const ACTIVITY_LABEL: Record<string, string> = {
  sale: "فاتورة بيع",
  sales_return: "مرتجع بيع",
  purchase: "فاتورة شراء",
  purchase_return: "مرتجع شراء",
  collection: "تحصيل",
  supplier_payment: "دفعة مورد",
  expense: "مصروف",
};

const ACTIVITY_SIGN: Record<string, 1 | -1> = {
  sale: 1,
  sales_return: -1,
  purchase: -1,
  purchase_return: 1,
  collection: 1,
  supplier_payment: -1,
  expense: -1,
};

function timeAgo(iso: string) {
  const diffMs = Date.now() - new Date(iso).getTime();
  const minutes = Math.round(diffMs / 60000);
  if (minutes < 1) return "الآن";
  if (minutes < 60) return `منذ ${minutes} د`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `منذ ${hours} س`;
  const days = Math.round(hours / 24);
  return `منذ ${days} يوم`;
}

function DashboardHomeContent({
  period,
  hasProducts,
  canViewFinancial,
  totalSales,
  netProfit,
  treasuryBalance,
  customerReceivable,
  supplierPayable,
  inventoryValue,
  recentActivity,
  analytics,
}: {
  period: PeriodSel;
  hasProducts: boolean;
  canViewFinancial: boolean;
  totalSales: number;
  netProfit: number;
  treasuryBalance: number;
  customerReceivable: number;
  supplierPayable: number;
  inventoryValue: number;
  recentActivity: ActivityRow[];
  analytics: DashboardAnalyticsData;
}) {
  const [showMore, setShowMore] = useState(false);

  const locked = { value: "—", note: "غير مصرح بعرض هذا المؤشر" };
  const CARDS = [
    { label: "صافي المبيعات", value: money(totalSales), unit: "ج.م", icon: TrendingUp, note: period.label },
    canViewFinancial
      ? { label: "صافي الربح", value: money(netProfit), unit: "ج.م", negative: isNegativeMoney(netProfit), icon: Landmark, note: period.label }
      : { label: "صافي الربح", icon: Landmark, ...locked },
    canViewFinancial
      ? { label: "رصيد الخزنة", value: money(treasuryBalance), unit: "ج.م", icon: Wallet, note: "الرصيد الحالي", negative: isNegativeMoney(treasuryBalance) }
      : { label: "رصيد الخزنة", icon: Wallet, ...locked },
    canViewFinancial
      ? { label: "فلوس عند العملاء", value: money(customerReceivable), unit: "ج.م", icon: Users, note: "الرصيد الحالي" }
      : { label: "فلوس عند العملاء", icon: Users, ...locked },
    canViewFinancial
      ? { label: "فلوس للموردين", value: money(supplierPayable), unit: "ج.م", icon: Truck, note: "الرصيد الحالي" }
      : { label: "فلوس للموردين", icon: Truck, ...locked },
    canViewFinancial
      ? { label: "قيمة المخزون", value: money(inventoryValue), unit: "ج.م", icon: Boxes, note: "الرصيد الحالي" }
      : { label: "قيمة المخزون", icon: Boxes, ...locked },
  ];
  const visibleCards = showMore ? CARDS : CARDS.slice(0, 3);

  return (
    <div className="mx-auto min-w-0 max-w-5xl pb-12 pt-0 sm:pb-16 sm:pt-4">
      <div className="mb-8 flex items-start justify-between gap-4 sm:mb-10 sm:gap-6">
        <div className="min-w-0">
          <p className="mb-3 text-xs font-medium text-sage">مركز العمل</p>
          <h1 className="text-2xl font-semibold tracking-[-0.03em] text-charcoal sm:text-4xl">نظرة واضحة على يومك.</h1>
          <p className="mt-3 max-w-lg text-sm leading-7 text-charcoal/50">كل ما تحتاجه لتبدأ، في مكان واحد وبدون تشتيت.</p>
        </div>
        <div className="hidden w-48 shrink-0 sm:block">
          <PeriodPicker sel={period} />
        </div>
      </div>

      {!hasProducts && (
        <m.section initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.35 }} className="mb-10 rounded-2xl border border-sage/20 bg-sageSoft/35 p-5 sm:flex sm:items-center sm:justify-between sm:p-6">
          <div>
            <div className="mb-2 flex items-center gap-2 text-xs font-medium text-sage">
              <span className="h-1.5 w-1.5 rounded-full bg-sage" />
              خطوة واحدة للبدء
            </div>
            <h2 className="text-xl font-semibold text-charcoal">أضف أول منتج إلى مساحة العمل</h2>
            <p className="mt-2 text-sm text-charcoal/50">بعدها ستظهر مؤشراتك الحقيقية تلقائيًا.</p>
          </div>
          <Link href="/dashboard/products?new=1" className="mt-5 inline-flex items-center justify-center gap-2 rounded-xl bg-charcoal px-4 py-3 text-xs font-medium text-ivory transition-colors hover:bg-sage sm:mt-0">
            <Plus size={16} />
            إضافة منتج
          </Link>
        </m.section>
      )}

      <div className="mb-4 flex items-end justify-between gap-3">
        <div>
          <p className="text-xs font-medium text-charcoal/40">ملخص سريع</p>
          <h2 className="mt-1 text-xl font-semibold text-charcoal">أهم مؤشراتك</h2>
        </div>
        <span className="shrink-0 text-[0.6875rem] text-charcoal/35">تتحدث تلقائيًا</span>
      </div>
      <div className="mb-4 sm:hidden">
        <PeriodPicker sel={period} />
      </div>

      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {visibleCards.map((card, index) => {
          const Icon = card.icon;
          return (
            <m.div key={card.label} layout initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: index * 0.04, duration: 0.28 }} className={`group min-w-0 rounded-2xl border border-borderSoft bg-white p-4 transition-shadow duration-300 hover:shadow-[0_12px_30px_rgba(28,28,26,0.06)] sm:p-5 ${index === visibleCards.length - 1 && visibleCards.length % 2 === 1 ? "sm:col-span-2 xl:col-span-1" : ""}`}>
              <div className="mb-6 flex items-center justify-between sm:mb-9">
                <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-sageSoft text-sage">
                  <Icon size={18} strokeWidth={1.8} />
                </div>
                <span className="text-[0.625rem] text-charcoal/30" dir="ltr">{(index + 1).toLocaleString("ar-EG", { minimumIntegerDigits: 2 })}</span>
              </div>
              <p className="text-xs text-charcoal/50">{card.label}</p>
              {"unit" in card ? <StatValue className="mt-2" value={card.value} unit={card.unit} negative={"negative" in card && !!card.negative} /> : <p className="mt-2 text-2xl font-semibold text-charcoal/30 sm:text-3xl">{card.value}</p>}
              <p className="mt-1 text-[0.6875rem] text-charcoal/35">{card.note}</p>
            </m.div>
          );
        })}
      </div>
      <button onClick={() => setShowMore((value) => !value)} className="mx-auto mt-5 flex items-center gap-2 rounded-lg px-3 py-2 text-xs text-charcoal/45 transition-colors hover:bg-paper hover:text-charcoal">
        {showMore ? "عرض أقل" : "عرض باقي المؤشرات"}
        <ChevronDown size={15} className={`transition-transform ${showMore ? "rotate-180" : ""}`} />
      </button>

      <AnimatePresence initial={false}>
        {showMore && (
          <m.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: "auto" }} exit={{ opacity: 0, height: 0 }} className="mt-10 overflow-hidden border-t border-borderSoft pt-8">
            <div className="flex items-center gap-2 text-xs text-charcoal/45">
              <Check size={15} className="text-sage" />
              يمكنك تفعيل الوحدات التي تحتاجها فقط من القائمة الجانبية.
            </div>
          </m.div>
        )}
      </AnimatePresence>

      <DashboardAnalytics data={analytics} period={period} canViewFinancial={canViewFinancial} />

      {recentActivity.length > 0 && (
        <div className="mt-10 border-t border-borderSoft pt-8">
          <div className="mb-4">
            <p className="text-xs font-medium text-charcoal/40">آخر التحركات</p>
            <h2 className="mt-1 text-xl font-semibold text-charcoal">أحدث العمليات</h2>
          </div>
          <div className="overflow-hidden rounded-2xl border border-borderSoft bg-white">
            {recentActivity.map((row, index) => {
              const sign = ACTIVITY_SIGN[row.kind] ?? 1;
              return (
                <div
                  key={`${row.kind}-${row.occurred_at}-${index}`}
                  className={`flex items-center justify-between gap-3 px-3.5 py-3.5 sm:gap-4 sm:px-5 ${index !== recentActivity.length - 1 ? "border-b border-borderSoft" : ""}`}
                >
                  <div className="flex min-w-0 items-center gap-3">
                    <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-paper text-charcoal/40">
                      <Clock size={14} strokeWidth={1.8} />
                    </div>
                    <div className="min-w-0">
                      <p className="truncate text-sm text-charcoal">{ACTIVITY_LABEL[row.kind] ?? row.kind}</p>
                      <p className="truncate text-xs text-charcoal/40">{row.label}</p>
                    </div>
                  </div>
                  <div className="shrink-0 text-left">
                    <p className={`num text-sm font-medium ${sign > 0 ? "text-sage" : "text-rose"}`} dir="ltr">
                      {sign > 0 ? "+" : "-"}
                      <Money value={row.amount} />
                    </p>
                    <p className="text-[0.6875rem] text-charcoal/35">{timeAgo(row.occurred_at)}</p>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}

export function DashboardHome(props: React.ComponentProps<typeof DashboardHomeContent>) {
  return (
    <MotionProvider>
      <DashboardHomeContent {...props} />
    </MotionProvider>
  );
}
