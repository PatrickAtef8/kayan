"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import clsx from "clsx";
import { Check, Eye, TriangleAlert } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import { ConfirmAction } from "./confirm-action";
import { FeatureMatrix } from "@/components/pricing/feature-matrix";
import { savePricing, resetPricing, restorePricingVersion } from "@/app/admin/actions";
import { MODULE_FEATURES, PACKAGE_MODULE_ORDER, type PackageConfig, type PackageModuleKey } from "@/config/pricing.config";
import type { EditablePackage } from "@/lib/billing/pricing";

type Pkg = { key: string; name: string; config: PackageConfig; current: EditablePackage; shipped: EditablePackage; licensees: number };
type HistoryRow = { id: number; action: string; created_at: string; applied_to_existing: number; note: string | null };
type Draft = { license: string; hosting: string; monthly: string; maxMembers: string; maxWarehouses: string; modules: PackageModuleKey[] };

const toText = (n: number | null) => (n === null ? "" : String(n));
const numOrNull = (t: string) => (t.trim() === "" ? null : Number(t));
// a price field left EMPTY is invalid (NaN), never silently 0 — only a typed "0" means free
const priceOf = (t: string) => (t.trim() === "" ? Number.NaN : Number(t));
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
const limitOf = (text: string, fallback: number | null): number | null => {
  if (text.trim() === "") return null;
  const n = Number(text);
  return Number.isInteger(n) && n >= 1 ? n : fallback;
};
const DATE = new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short" });
const ACTION_LABEL: Record<string, string> = { save: "حفظ", reset: "استعادة الأصلية", restore: "استعادة نسخة" };

const field = "w-full rounded-xl border border-borderSoft bg-white px-3 py-2 text-sm outline-none focus:border-sage focus:ring-2 focus:ring-sage/20";

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="block text-xs font-medium text-charcoal/70">{label}</span>
      {children}
      {hint ? <span className="mt-1 block text-[0.6875rem] leading-4 text-charcoal/40">{hint}</span> : null}
    </label>
  );
}

export function PackageEditor({ packages, history, custom }: { packages: Pkg[]; history: HistoryRow[]; custom: boolean }) {
  const router = useRouter();
  const [state, setState] = useState<Record<string, Draft>>(
    Object.fromEntries(packages.map((p) => [p.key, { license: toText(p.current.licenseEgp), hosting: toText(p.current.hostingMonthlyEgp), monthly: toText(p.current.subscriptionMonthlyEgp), maxMembers: toText(p.current.maxMembers), maxWarehouses: toText(p.current.maxWarehouses), modules: [...p.current.modules] }])),
  );
  const [applyExisting, setApplyExisting] = useState(false);
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const set = (k: string, patch: Partial<Draft>) => setState((s) => ({ ...s, [k]: { ...s[k], ...patch } }));

  const collected = useMemo<Record<string, EditablePackage>>(() => Object.fromEntries(packages.map((p) => {
    const s = state[p.key];
    const oneTime = p.key === "one_time";
    return [p.key, { licenseEgp: oneTime ? priceOf(s.license) : null, hostingMonthlyEgp: oneTime ? priceOf(s.hosting) : null, subscriptionMonthlyEgp: oneTime ? null : priceOf(s.monthly), maxMembers: numOrNull(s.maxMembers), maxWarehouses: numOrNull(s.maxWarehouses), modules: PACKAGE_MODULE_ORDER.filter((m) => s.modules.includes(m)) }];
  })), [packages, state]);

  const dirty = packages.some((p) => !same(collected[p.key], { ...p.current, modules: PACKAGE_MODULE_ORDER.filter((m) => p.current.modules.includes(m)) }));
  const affected = packages
    .filter((p) => !same(collected[p.key].modules, PACKAGE_MODULE_ORDER.filter((m) => p.current.modules.includes(m))) || collected[p.key].maxMembers !== p.current.maxMembers || collected[p.key].maxWarehouses !== p.current.maxWarehouses)
    .reduce((n, p) => n + p.licensees, 0);

  // What the customer will see once this is saved: the SAME component the public pricing page uses.
  const preview = useMemo<PackageConfig[]>(() => packages.map((p) => ({
    ...p.config,
    modules: PACKAGE_MODULE_ORDER.filter((m) => state[p.key].modules.includes(m)),
    limits: { maxMembers: limitOf(state[p.key].maxMembers, p.config.limits.maxMembers), maxWarehouses: limitOf(state[p.key].maxWarehouses, p.config.limits.maxWarehouses) },
  })), [packages, state]);

  function save() {
    setMsg(null);
    start(async () => {
      try {
        const r = await savePricing({ packages: collected, applyExisting, note });
        if (r.error) setMsg({ ok: false, text: r.error });
        else { setMsg({ ok: true, text: r.message ?? "حُفظت الإعدادات." }); setApplyExisting(false); setNote(""); router.refresh(); }
      } catch { setMsg({ ok: false, text: "تعذّر الاتصال بالخادم." }); }
    });
  }

  return (
    <div className="space-y-6">
      {/* ---- one card per plan (the perpetual license, the monthly subscription): prices, limits, modules ------------------------------------------------ */}
      <div className="grid gap-4 lg:grid-cols-2">
        {packages.map((p) => {
          const s = state[p.key];
          const edited = !same(collected[p.key], { ...p.shipped, modules: PACKAGE_MODULE_ORDER.filter((m) => p.shipped.modules.includes(m)) });
          return (
            <Card key={p.key} className="flex flex-col p-5">
              <div className="flex items-start justify-between gap-3 border-b border-borderSoft pb-4">
                <div>
                  <h2 className="text-lg font-semibold text-charcoal">{p.name}</h2>
                  <p className="mt-0.5 text-xs text-charcoal/45">{p.licensees === 0 ? "لا توجد شركات على هذه الباقة" : `${p.licensees} شركة عليها`}</p>
                </div>
                {edited && <span className="shrink-0 bg-amber-50 px-2 py-1 text-[0.6875rem] font-medium text-amber-800">معدّلة عن الأصلية</span>}
              </div>

              <fieldset className="border-b border-borderSoft py-4">
                <legend className="mb-3 text-xs font-semibold text-charcoal">الأسعار (ج.م)</legend>
                <div className="space-y-3">
                {p.key === "one_time" ? (
                  <>
                    <Field label="الرخصة الدائمة" hint="تُدفع مرة واحدة">
                      <input inputMode="decimal" className={clsx(field, "num mt-1")} value={s.license} onChange={(e) => set(p.key, { license: e.target.value })} />
                    </Field>
                    <Field label="الاستضافة والصيانة شهريًا" hint="مع الرخصة الدائمة. بند واحد شهريًا، يُدفع بشكل منفصل. اكتب 0 لجعل الاستضافة والصيانة مجانية.">
                      <input inputMode="decimal" className={clsx(field, "num mt-1")} value={s.hosting} onChange={(e) => set(p.key, { hosting: e.target.value })} />
                    </Field>
                    {s.hosting.trim() !== "" && Number(s.hosting) === 0 && (
                      <p className="rounded-xl bg-sageSoft/60 p-3 text-xs leading-5 text-charcoal/70">الاستضافة والصيانة <b>مجانية</b>: من يشتري الرخصة يدفع سعرها فقط ولا يدفع أي استضافة أو صيانة، ولا يظهر له تجديد. وأصحاب الرخصة الحاليون لا يُغلق عليهم الدخول بسبب الاستضافة طالما بقي السعر 0.</p>
                    )}
                  </>
                ) : (
                  <Field label="الاشتراك الشهري الشامل" hint="سعر واحد كل شهر: يشمل الدخول والاستضافة والصيانة">
                    <input inputMode="decimal" className={clsx(field, "num mt-1")} value={s.monthly} onChange={(e) => set(p.key, { monthly: e.target.value })} />
                  </Field>
                )}
                </div>
              </fieldset>

              <fieldset className="border-b border-borderSoft py-4">
                <legend className="mb-3 text-xs font-semibold text-charcoal">الحدود</legend>
                <div className="grid grid-cols-2 gap-3">
                  <Field label="أعضاء الفريق"><input inputMode="numeric" placeholder="بلا حد" className={clsx(field, "num mt-1")} value={s.maxMembers} onChange={(e) => set(p.key, { maxMembers: e.target.value })} /></Field>
                  <Field label="المخازن"><input inputMode="numeric" placeholder="بلا حد" className={clsx(field, "num mt-1")} value={s.maxWarehouses} onChange={(e) => set(p.key, { maxWarehouses: e.target.value })} /></Field>
                </div>
                <p className="mt-2 text-[0.6875rem] text-charcoal/40">اترك الخانة فارغة لتكون «بلا حد».</p>
              </fieldset>

              <fieldset className="pt-4">
                <legend className="mb-3 text-xs font-semibold text-charcoal">الوحدات المتاحة</legend>
                <div className="space-y-2">
                  {PACKAGE_MODULE_ORDER.map((m) => {
                    const on = s.modules.includes(m);
                    return (
                      <label key={m} className="flex cursor-pointer items-center gap-2.5 text-sm">
                        <input type="checkbox" checked={on} onChange={() => set(p.key, { modules: on ? s.modules.filter((x) => x !== m) : [...s.modules, m] })} className="h-4 w-4 accent-[#344E41]" />
                        <span className={on ? "text-charcoal" : "text-charcoal/40"}>{MODULE_FEATURES[m].label}</span>
                      </label>
                    );
                  })}
                </div>
              </fieldset>
            </Card>
          );
        })}
      </div>

      {/* ---- save ------------------------------------------------------------------------------------------ */}
      <Card className="p-5">
        <label className="flex items-start gap-2.5 text-sm">
          <input type="checkbox" checked={applyExisting} onChange={(e) => setApplyExisting(e.target.checked)} className="mt-0.5 h-4 w-4 shrink-0 accent-[#344E41]" />
          <span>
            <span className="font-medium">طبّق الحدود والوحدات على الشركات التي اشترت هذه الباقة بالفعل</span>
            <span className="mt-1 block text-xs leading-5 text-charcoal/50">
              افتراضيًا تسري التغييرات على الشراء الجديد فقط. عند التفعيل تُحدَّث الشركات الحالية{affected ? ` (حتى ${affected} شركة)` : ""}، ولا يُعطَّل شيء تستخدمه: تُمنع الإضافات الجديدة فقط. الأسعار لا تؤثر على من اشترى.
            </span>
          </span>
        </label>
        <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} placeholder="ملاحظة اختيارية تُسجَّل مع التغيير" className={clsx(field, "mt-4")} />
        {msg && <p role="alert" className={clsx("mt-3 flex items-start gap-2 text-sm", msg.ok ? "text-sage" : "text-rose")}>{msg.ok ? <Check size={16} className="mt-0.5 shrink-0" /> : <TriangleAlert size={16} className="mt-0.5 shrink-0" />}{msg.text}</p>}
        <div className="mt-4 flex flex-wrap items-center gap-3">
          <button type="button" onClick={save} disabled={pending || !dirty} className="inline-flex items-center gap-2 rounded-xl bg-charcoal px-6 py-2.5 text-sm font-medium text-ivory hover:bg-sage disabled:cursor-not-allowed disabled:opacity-50">{pending ? <><Spinner />جارٍ الحفظ…</> : "حفظ التغييرات"}</button>
          <ConfirmAction label="استعادة الإعدادات الأصلية" title="استعادة الإعدادات الأصلية؟" description="ستعود أسعار الخيارين وحدودهما ووحداتهما إلى القيم المكتوبة في النظام عند الشحن. لا يتأثر أي عميل اشترى بالفعل، ويبقى سجل النسخ محفوظًا." confirmLabel="استعادة" run={resetPricing} disabled={!custom} />
          <span className="text-xs text-charcoal/40">{dirty ? "لديك تغييرات غير محفوظة." : "لا توجد تغييرات غير محفوظة."}</span>
        </div>
      </Card>

      {/* ---- what the customer sees (live, no prices) ------------------------------------------------------- */}
      <div>
        <div className="mb-3 flex items-center gap-2 text-sm text-charcoal/55"><Eye size={16} className="shrink-0" /><span>هكذا يظهر الخياران للعميل في صفحة الأسعار وصفحة الدفع{dirty ? " — تتحدّث مباشرة مع ما تعدّله هنا قبل الحفظ" : ""}.</span></div>
        <FeatureMatrix packages={preview} sq="rounded-2xl" />
      </div>

      {/* ---- history ---------------------------------------------------------------------------------------- */}
      <Card className="overflow-hidden p-0 sm:p-0">
        <h2 className="border-b border-borderSoft px-5 py-4 text-base font-semibold">سجل التغييرات</h2>
        {history.length === 0 ? <p className="px-5 py-8 text-center text-sm text-charcoal/45">لم تُجرَ أي تغييرات: الإعدادات هي الأصلية.</p> : (
          <ul className="divide-y divide-borderSoft text-sm">{history.map((h) => (
            <li key={h.id} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3">
              <span className="min-w-0">
                <span className="font-medium">{ACTION_LABEL[h.action] ?? h.action}</span>
                {h.applied_to_existing ? <span className="text-xs text-charcoal/50"> · طُبّق على {h.applied_to_existing} شركة</span> : null}
                {h.note ? <span className="block text-xs text-charcoal/45">{h.note}</span> : null}
              </span>
              <span className="flex items-center gap-3">
                <span className="text-xs text-charcoal/45">{DATE.format(new Date(h.created_at))}</span>
                {h.action !== "reset" && <ConfirmAction label="استعادة هذه النسخة" title="استعادة هذه النسخة؟" description="ستُحفظ إعدادات هذه النسخة كإعدادات حالية (دون تطبيقها على الشركات الحالية)." confirmLabel="استعادة" run={() => restorePricingVersion(h.id)} />}
              </span>
            </li>
          ))}</ul>
        )}
      </Card>
    </div>
  );
}
