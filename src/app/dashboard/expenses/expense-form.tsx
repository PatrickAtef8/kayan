"use client";

import { useState, useTransition } from "react";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { PAYMENT_METHODS, DEFAULT_PAYMENT_METHOD } from "@/lib/payment-methods";
import { createExpense } from "./actions";
import { EXPENSE_TYPES } from "./expense-types";

const NEW_CATEGORY = "__new__";

function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

// Two different questions, asked in this order:
//   1. نوع المصروف  — WHAT is being paid. It changes the accounting (treasury / profit) and
//                      whether a representative is needed. Always required.
//   2. التصنيف      — only a label to group expenses in the reports (rent, electricity …).
//                      Optional and never changes any number.
export function ExpenseForm({ categories, reps }: { categories: { id: string; name: string }[]; reps: { id: string; name: string }[] }) {
  const [type, setType] = useState<string>("operating");
  const [repId, setRepId] = useState("");
  const [category, setCategory] = useState("");
  const [newCategory, setNewCategory] = useState("");
  const [amount, setAmount] = useState("");
  const [date, setDate] = useState(today);
  const [method, setMethod] = useState<string>(DEFAULT_PAYMENT_METHOD);
  const [description, setDescription] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);
  const [pending, startTransition] = useTransition();

  const info = EXPENSE_TYPES.find((t) => t.value === type) ?? EXPENSE_TYPES[0];
  const value = Number(amount);

  function submit() {
    setError(null);
    setSuccess(false);
    if (!(value > 0)) return setError("أدخل مبلغًا أكبر من صفر");
    if (info.needsRep && !repId) return setError("اختر المندوب المعني بهذا المصروف");
    if (category === NEW_CATEGORY && !newCategory.trim()) return setError("اكتب اسم التصنيف الجديد أو اختر تصنيفًا موجودًا");
    startTransition(async () => {
      const result = await createExpense({
        expense_type: type,
        sales_rep_id: info.needsRep ? repId : "",
        category_id: category === NEW_CATEGORY ? "" : category,
        new_category: category === NEW_CATEGORY ? newCategory : "",
        amount: value,
        expense_date: date,
        payment_method: method,
        description,
      });
      if (result.error) return setError(result.error);
      setAmount("");
      setDescription("");
      setCategory("");
      setNewCategory("");
      setSuccess(true);
    });
  }

  return (
    <Card className="mb-7 p-5 sm:p-6">
      <div className="space-y-6">
        {/* 1. type */}
        <section>
          <h3 className="text-sm font-medium text-charcoal">١. ما نوع المصروف؟</h3>
          <p className="mb-3 mt-1 text-xs text-charcoal/50">النوع يحدّد طريقة حسابه في الخزنة والأرباح.</p>
          <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
            {EXPENSE_TYPES.map((t) => {
              const active = t.value === type;
              return (
                <button
                  key={t.value}
                  type="button"
                  onClick={() => setType(t.value)}
                  aria-pressed={active}
                  className={`rounded-xl border px-4 py-3 text-right transition-colors ${active ? "border-sage bg-sageSoft/40" : "border-borderSoft bg-white hover:border-sage/50"}`}
                >
                  <div className="text-sm font-medium text-charcoal">{t.label}</div>
                  <div className="mt-0.5 text-[0.6875rem] text-charcoal/50">{t.examples}</div>
                  <div className={`mt-1.5 text-[0.6875rem] ${active ? "text-sage" : "text-charcoal/40"}`}>{t.effect}</div>
                </button>
              );
            })}
          </div>
          {info.needsRep && (
            <div className="mt-3 max-w-sm">
              <Field label="المندوب المعني (مطلوب)">
                <ModernSelect value={repId} onChange={setRepId} allowClear={false} placeholder="اختر المندوب" options={reps.map((r) => ({ value: r.id, label: r.name }))} />
              </Field>
            </div>
          )}
        </section>

        {/* 2. category */}
        <section>
          <h3 className="text-sm font-medium text-charcoal">٢. تصنيف للتقارير <span className="font-normal text-charcoal/40">(اختياري)</span></h3>
          <p className="mb-3 mt-1 text-xs text-charcoal/50">وسم لتجميع المصروفات المتشابهة في التقارير، مثل «إيجار» أو «كهرباء». لا يغيّر أي حساب.</p>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field label="التصنيف">
              <ModernSelect
                value={category}
                onChange={setCategory}
                placeholder="بدون تصنيف"
                clearLabel="بدون تصنيف"
                options={[...categories.map((c) => ({ value: c.id, label: c.name })), { value: NEW_CATEGORY, label: "+ إضافة تصنيف جديد…" }]}
              />
            </Field>
            {category === NEW_CATEGORY && (
              <Field label="اسم التصنيف الجديد">
                <Input value={newCategory} onChange={(e) => setNewCategory(e.target.value)} placeholder="مثال: إيجار" autoFocus />
              </Field>
            )}
          </div>
        </section>

        {/* 3. details */}
        <section>
          <h3 className="mb-3 text-sm font-medium text-charcoal">٣. تفاصيل الدفع</h3>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <Field label="المبلغ (ج.م)">
              <Input type="number" step="0.01" min="0" dir="ltr" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
            </Field>
            <Field label="تاريخ الدفع">
              <Input type="date" dir="ltr" value={date} onChange={(e) => setDate(e.target.value)} />
            </Field>
            <Field label="طريقة الدفع">
              <ModernSelect value={method} onChange={setMethod} allowClear={false} options={PAYMENT_METHODS.map((m) => ({ value: m, label: m }))} />
            </Field>
            <div className="col-span-full">
              <Field label="ملاحظة (اختياري)">
                <Input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="مثال: إيجار شهر أكتوبر" />
              </Field>
            </div>
          </div>
        </section>

        <div className="flex flex-wrap items-center gap-3">
          <Button type="button" disabled={pending} onClick={submit}>
            {pending ? "جارٍ الحفظ..." : "تسجيل المصروف"}
          </Button>
          {value > 0 && !error && (
            <span className="text-xs text-charcoal/50">
              سيُسجَّل <span dir="ltr">{value.toLocaleString("ar-EG", { minimumFractionDigits: 2 })} ج.م</span> كـ«{info.label}» — {info.effect.split(" (")[0]}.
            </span>
          )}
          {error && <span className="text-xs text-rose">{error}</span>}
          {success && <span className="text-xs text-sage">تم تسجيل المصروف</span>}
        </div>
      </div>
    </Card>
  );
}
