"use client";

import { Money } from "@/components/ui/money";
import { useState, useTransition } from "react";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { setTreasuryOpeningBalance } from "./actions";


// The cash that was in the till BEFORE the first record in the system. Every balance is built on top of it.
export function OpeningBalanceCard({ openingBalance }: { openingBalance: number }) {
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState(openingBalance);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function save() {
    setError(null);
    startTransition(async () => {
      const result = await setTreasuryOpeningBalance(value);
      if (result.error) {
        setError(result.error);
        return;
      }
      setEditing(false);
    });
  }

  return (
    <Card className="mb-7 p-5 sm:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p className="text-xs text-charcoal/45">الرصيد الافتتاحي</p>
          <p className="mt-1 text-xl font-semibold tracking-tight text-charcoal"><Money value={openingBalance} /></p>
        </div>
        {!editing && (
          <Button type="button" onClick={() => { setValue(openingBalance); setError(null); setEditing(true); }}>
            تعديل
          </Button>
        )}
      </div>
      <p className="mt-3 text-xs leading-6 text-charcoal/45">
        هو المبلغ الذي كان في الخزنة قبل أن تبدأ التسجيل في النظام. الرصيد الحالي = الرصيد الافتتاحي + كل حركات الدخل − كل حركات المصروف.
      </p>
      {editing && (
        <div className="mt-4">
          <div className="flex flex-wrap items-end gap-3">
            <div className="w-full sm:w-60">
              <Input type="number" step="0.01" min="0" dir="ltr" value={value} onChange={(e) => setValue(Number(e.target.value))} />
            </div>
            <Button type="button" disabled={pending} onClick={save}>{pending ? "جارٍ الحفظ..." : "حفظ"}</Button>
            <button type="button" disabled={pending} onClick={() => setEditing(false)} className="text-xs text-charcoal/50 hover:text-charcoal">إلغاء</button>
          </div>
          <p className="mt-2 text-xs leading-6 text-charcoal/45">
            تغييره يغيّر الرصيد الحالي بنفس الفرق، ولا يمسّ أي حركة مسجلة. كل تعديل يُسجَّل في سجل المراجعة.
          </p>
          {error && <p className="mt-2 text-xs text-rose">{error}</p>}
        </div>
      )}
    </Card>
  );
}
