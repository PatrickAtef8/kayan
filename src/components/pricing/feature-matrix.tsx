import clsx from "clsx";
import { Check, Minus } from "lucide-react";
import { MODULE_FEATURES, PACKAGE_MODULE_ORDER, INCLUDED_IN_EVERY_PACKAGE, type PackageConfig } from "@/config/pricing.config";
import { formatMoney } from "@/lib/money";

// The "what is in each plan" comparison (two plans: the perpetual license and the monthly subscription), exactly as the customer sees it on /pricing and on the checkout page.
// No prices here on purpose: prices are edited by the Super Admin and shown on the plan cards. The same component
// is used by the public pricing page, the owner's checkout page AND the admin "Packages" page, so what the admin
// previews is, by construction, what the customer sees. It has no state, so it works in server and client trees.

const limitCell = (n: number | null) => (n === null ? "بلا حد" : <span className="num">{formatMoney(n, 0)}</span>);

export function FeatureMatrix({ packages, sq = "", title = "ما يشمله كل خيار" }: { packages: PackageConfig[]; sq?: string; title?: string }) {
  return (
    <section aria-labelledby="matrix-title" className={clsx("border border-borderSoft bg-white/60", sq)}>
      <h2 id="matrix-title" className="border-b border-borderSoft px-5 py-4 text-base font-semibold text-charcoal">{title}</h2>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[34rem] text-sm">
          <thead>
            <tr className="text-xs text-charcoal/50">
              <th scope="col" className="px-5 py-3 text-right font-medium"><span className="sr-only">الميزة</span></th>
              {packages.map((p) => <th key={p.key} scope="col" className="px-3 py-3 text-center font-medium text-charcoal">{p.name}</th>)}
            </tr>
          </thead>
          <tbody className="divide-y divide-borderSoft">
            {([["أعضاء الفريق النشطون", (p: PackageConfig) => limitCell(p.limits.maxMembers)], ["المخازن النشطة", (p: PackageConfig) => limitCell(p.limits.maxWarehouses)]] as const).map(([label, cell]) => (
              <tr key={label}><th scope="row" className="px-5 py-3 text-right font-normal text-charcoal/70">{label}</th>{packages.map((p) => <td key={p.key} className="px-3 py-3 text-center font-medium text-charcoal">{cell(p)}</td>)}</tr>
            ))}
            {PACKAGE_MODULE_ORDER.map((k) => (
              <tr key={k}>
                <th scope="row" className="px-5 py-3 text-right font-normal text-charcoal/70"><span className="block">{MODULE_FEATURES[k].label}</span><span className="block text-xs text-charcoal/40">{MODULE_FEATURES[k].detail}</span></th>
                {packages.map((p) => (
                  <td key={p.key} className="px-3 py-3 text-center">
                    {(p.modules as string[]).includes(k) ? <><Check size={17} strokeWidth={2.2} className="mx-auto text-sage" /><span className="sr-only">مشمولة</span></> : <><Minus size={17} className="mx-auto text-charcoal/25" /><span className="sr-only">غير مشمولة</span></>}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="border-t border-borderSoft px-5 py-4">
        <p className="mb-2 text-xs font-medium text-charcoal/60">في الخيارين</p>
        <ul className="grid gap-x-6 gap-y-1.5 text-sm text-charcoal/65 sm:grid-cols-2">
          {INCLUDED_IN_EVERY_PACKAGE.map((f) => <li key={f} className="flex items-start gap-2"><Check size={15} strokeWidth={2.2} className="mt-1 shrink-0 text-sage" />{f}</li>)}
        </ul>
      </div>
    </section>
  );
}
