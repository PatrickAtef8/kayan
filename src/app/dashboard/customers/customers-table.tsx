"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { Pencil, Trash2, Wallet, BarChart3 } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ActionForm, SubmitButton } from "@/components/ui/action-form";
import { ModernSelect } from "@/components/ui/select";
import { updateCustomer, deleteCustomer, recordCustomerCollection } from "./actions";
import type { CustomerBalance } from "./page";

const PRICE_TIER_OPTIONS = [
  { value: "retail", label: "تجزئة" },
  { value: "wholesale", label: "جملة" },
  { value: "distributor", label: "موزع" },
];
const PRICE_TIER_LABEL: Record<string, string> = { retail: "تجزئة", wholesale: "جملة", distributor: "موزع" };

type Customer = {
  id: string;
  name: string;
  phone: string | null;
  customer_type: string | null;
  price_tier: string;
  opening_balance: number;
  credit_status: string;
  sales_rep_id: string | null;
  sales_representatives: { name: string } | null;
};

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

export function CustomersTable({ customers, balances, reps, canViewBalance, canAssignRep, canCollect }: { customers: Customer[]; balances: CustomerBalance[]; reps: { id: string; name: string }[]; canViewBalance: boolean; canAssignRep: boolean; canCollect: boolean }) {
  const [editing, setEditing] = useState<Customer | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [collectingFor, setCollectingFor] = useState<Customer | null>(null);
  const [pending, startTransition] = useTransition();

  const balanceOf = (id: string) => balances.find((b) => b.customer_id === id)?.balance ?? 0;

  function handleDelete() {
    if (!deletingId) return;
    startTransition(async () => {
      const result = await deleteCustomer(deletingId);
      if (result?.error) {
        setDeleteError(result.error);
        return;
      }
      setDeletingId(null);
      setDeleteError(null);
    });
  }

  return (
    <>
      <DataTable<Customer>
        rows={customers}
        getRowKey={(c) => c.id}
        emptyLabel="لا يوجد عملاء بعد — أضف أول عميل أعلاه"
        columns={[
          { header: "الاسم", render: (c) => <Link href={`/dashboard/reports/customers/${c.id}`} className="text-sage hover:underline">{c.name}</Link> },
          { header: "المندوب", render: (c) => c.sales_representatives?.name ?? "—" },
          { header: "الهاتف", render: (c) => <span dir="ltr">{c.phone ?? "—"}</span> },
          { header: "النوع", render: (c) => c.customer_type ?? "—" },
          { header: "مستوى السعر", render: (c) => PRICE_TIER_LABEL[c.price_tier] ?? c.price_tier },
          {
            header: "الحالة الائتمانية",
            render: (c) => (
              <span className={c.credit_status === "blocked" ? "text-rose" : c.credit_status === "watch" ? "text-brass" : "text-moss"}>
                {c.credit_status === "good" ? "جيدة" : c.credit_status === "watch" ? "مراقبة" : "محظور"}
              </span>
            ),
          },
          ...(canViewBalance
            ? [
                {
                  header: "الرصيد المستحق",
                  render: (c: Customer) => {
                    const bal = balanceOf(c.id);
                    return (
                      <span dir="ltr" className={bal > 0 ? "font-medium text-rose" : "text-charcoal/50"}>
                        {money(bal)} ج.م
                      </span>
                    );
                  },
                },
              ]
            : []),
          {
            header: "",
            render: (c) => (
              <div className="flex items-center justify-end gap-1">
                {canCollect && (
                  <button onClick={() => setCollectingFor(c)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-sageSoft/40 hover:text-sage" aria-label="تسجيل تحصيل">
                    <Wallet size={15} strokeWidth={2} />
                  </button>
                )}
                <button onClick={() => setEditing(c)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-paper hover:text-ink" aria-label="تعديل">
                  <Pencil size={15} strokeWidth={2} />
                </button>
                <button onClick={() => setDeletingId(c.id)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-rose/10 hover:text-rose" aria-label="حذف">
                  <Trash2 size={15} strokeWidth={2} />
                </button>
              </div>
            ),
          },
        ]}
      />

      <Modal open={!!editing} onClose={() => setEditing(null)} title="تعديل بيانات العميل">
        {editing && (
          <ActionForm action={updateCustomer.bind(null, editing.id)} onSuccess={() => setEditing(null)} resetOnSuccess={false} className="space-y-4">
            <Field label="اسم العميل">
              <Input name="name" required defaultValue={editing.name} />
            </Field>
            <Field label="رقم الهاتف">
              <Input name="phone" dir="ltr" defaultValue={editing.phone ?? ""} />
            </Field>
            <Field label="نوع العميل">
              <Input name="customer_type" defaultValue={editing.customer_type ?? ""} />
            </Field>
            <Field label="مستوى السعر">
              <ModernSelect name="price_tier" defaultValue={editing.price_tier} allowClear={false} options={PRICE_TIER_OPTIONS} />
            </Field>
            {canAssignRep && (
              <Field label="المندوب المسؤول">
                <ModernSelect name="sales_rep_id" defaultValue={editing.sales_rep_id ?? ""} placeholder="بدون مندوب" clearLabel="بدون مندوب" options={reps.map((r) => ({ value: r.id, label: r.name }))} />
                {reps.length === 0 && <p className="mt-1.5 text-xs text-rose">لا يوجد مناديب بعد — أضف مندوبًا من صفحة المندوبين أو اربط مستخدمًا من الإعدادات ← الفريق.</p>}
              </Field>
            )}
            {canViewBalance && (
              <Field label="الرصيد الافتتاحي">
                <Input name="opening_balance" type="number" step="0.01" dir="ltr" defaultValue={editing.opening_balance} />
              </Field>
            )}
            <SubmitButton pendingText="جارٍ حفظ التعديلات..." className="w-full">حفظ التعديلات</SubmitButton>
          </ActionForm>
        )}
      </Modal>

      <ConfirmDialog
        open={!!deletingId}
        title="حذف العميل؟"
        description="سيتم حذف بيانات هذا العميل نهائيًا. لا يمكن التراجع عن هذا الإجراء."
        loading={pending}
        error={deleteError}
        onCancel={() => {
          setDeletingId(null);
          setDeleteError(null);
        }}
        onConfirm={handleDelete}
      />

      <CollectionModal customer={collectingFor} onClose={() => setCollectingFor(null)} />
    </>
  );
}

function CollectionModal({ customer, onClose }: { customer: Customer | null; onClose: () => void }) {
  const [amount, setAmount] = useState(0);
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [method, setMethod] = useState("نقدًا");
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    if (!customer) return;
    setError(null);
    startTransition(async () => {
      const result = await recordCustomerCollection({
        customer_id: customer.id,
        amount,
        collection_date: date,
        payment_method: method,
        reference,
        notes,
      });
      if (result?.error) {
        setError(result.error);
        return;
      }
      setAmount(0);
      setReference("");
      setNotes("");
      onClose();
    });
  }

  return (
    <Modal open={!!customer} onClose={onClose} title={customer ? `تسجيل تحصيل من ${customer.name}` : "تسجيل تحصيل"}>
      <div className="space-y-4">
        <Field label="المبلغ">
          <Input type="number" step="0.01" min="0" dir="ltr" value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
        </Field>
        <Field label="تاريخ التحصيل">
          <Input type="date" dir="ltr" value={date} onChange={(e) => setDate(e.target.value)} />
        </Field>
        <Field label="طريقة الدفع">
          <Input value={method} onChange={(e) => setMethod(e.target.value)} placeholder="نقدًا، تحويل بنكي..." />
        </Field>
        <Field label="مرجع (اختياري)">
          <Input value={reference} onChange={(e) => setReference(e.target.value)} />
        </Field>
        <Field label="ملاحظات">
          <Input value={notes} onChange={(e) => setNotes(e.target.value)} />
        </Field>
        {error && <p className="text-xs text-rose">{error}</p>}
        <Button type="button" className="w-full" disabled={pending} onClick={submit}>
          {pending ? "جارٍ الحفظ..." : "تسجيل التحصيل"}
        </Button>
      </div>
    </Modal>
  );
}
