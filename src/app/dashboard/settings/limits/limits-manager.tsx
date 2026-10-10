"use client";

import { useState, useTransition } from "react";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { saveRoleLimit, resetRoleLimit } from "./actions";
import type { RoleRow, LimitRow } from "./page";

// Built-in behaviour when an Owner/Admin has not configured a role yet.
const isBuiltInUnlimited = (key: string | null) => key === "owner" || key === "admin";

function RoleLimitRow({ role, limit }: { role: RoleRow; limit?: LimitRow }) {
  const configured = !!limit;
  const defaultUnlimited = isBuiltInUnlimited(role.key);
  const [unlimited, setUnlimited] = useState(configured ? limit!.max_discount_pct === null : defaultUnlimited);
  const [pct, setPct] = useState<number>(configured && limit!.max_discount_pct !== null ? Number(limit!.max_discount_pct) : 0);
  const [bonus, setBonus] = useState(configured ? limit!.can_give_manual_bonus : defaultUnlimited);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const run = (fn: () => Promise<{ error: string | null }>) => {
    setError(null);
    startTransition(async () => {
      const r = await fn();
      if (r.error) setError(r.error);
    });
  };

  return (
    <tr className="border-t border-borderSoft align-middle">
      <td className="px-4 py-3 text-sm font-medium text-charcoal">
        {role.name}
        <div className="text-xs font-normal text-charcoal/40">{configured ? "مُعدَّل" : "الإعداد الافتراضي"}</div>
      </td>
      <td className="px-4 py-3">
        <div className="flex items-center gap-3">
          <label className="flex items-center gap-1.5 text-sm">
            <input type="checkbox" checked={unlimited} onChange={(e) => setUnlimited(e.target.checked)} />
            بلا حد أقصى
          </label>
          <Input type="number" min="0" max="100" step="0.01" dir="ltr" className="w-24" disabled={unlimited} value={unlimited ? "" : pct} onChange={(e) => setPct(Number(e.target.value))} />
          {!unlimited && <span className="text-sm text-charcoal/60">%</span>}
        </div>
      </td>
      <td className="px-4 py-3">
        <label className="flex items-center gap-1.5 text-sm">
          <input type="checkbox" checked={bonus} onChange={(e) => setBonus(e.target.checked)} />
          يسمح بالبونص اليدوي
        </label>
      </td>
      <td className="px-4 py-3">
        <div className="flex items-center justify-end gap-2">
          {error && <span className="text-xs text-rose">{error}</span>}
          <Button type="button" disabled={pending} onClick={() => run(() => saveRoleLimit({ roleId: role.id, unlimited, maxPct: pct, canGiveBonus: bonus }))}>حفظ</Button>
          {configured && (
            <button type="button" disabled={pending} onClick={() => run(() => resetRoleLimit(role.id))} className="text-xs text-charcoal/50 underline hover:text-charcoal">
              استعادة الافتراضي
            </button>
          )}
        </div>
      </td>
    </tr>
  );
}

export function LimitsManager({ roles, limits }: { roles: RoleRow[]; limits: LimitRow[] }) {
  return (
    <div className="space-y-6">
      <section>
        <h2 className="mb-1 text-base font-semibold text-charcoal">حدود الخصم والبونص لكل دور</h2>
        <p className="mb-2 text-xs text-charcoal/50">
          حدد أقصى خصم مسموح لكل دور، سواء خصم الصنف أو خصم الفاتورة أو خصم الدفع الفوري أو البيع بسعر أقل من سعر القائمة (يُحسب على أقل سعر مسجل للصنف). اختر «بلا حد أقصى» لرفع القيد عن الدور.
        </p>
        <p className="mb-4 text-xs text-charcoal/50">
          خصومات الشرائح التلقائية سياسة للشركة ولا تُحسب ضمن هذا الحد. الأدوار غير المُعدَّلة: المالك والمدير بلا حد، وباقي الأدوار 0% ولا بونص يدوي حتى تضبطها.
        </p>
        <Card className="overflow-x-auto p-0">
          <table className="w-full text-right">
            <thead>
              <tr className="text-xs text-charcoal/50">
                <th className="px-4 py-3 font-medium">الدور</th>
                <th className="px-4 py-3 font-medium">أقصى خصم</th>
                <th className="px-4 py-3 font-medium">البونص</th>
                <th className="px-4 py-3" />
              </tr>
            </thead>
            <tbody>
              {roles.map((r) => (
                <RoleLimitRow key={r.id} role={r} limit={limits.find((l) => l.role_id === r.id)} />
              ))}
            </tbody>
          </table>
        </Card>
      </section>
    </div>
  );
}
