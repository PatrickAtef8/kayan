"use client";

import { useState, useTransition } from "react";
import { Pencil, Trash2, Wallet } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { updateSupplier, deleteSupplier, recordSupplierPayment } from "./actions";
import type { SupplierBalance } from "./page";

type Supplier = { id: string; name: string; phone: string | null; opening_balance: number };

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

export function SuppliersTable({ suppliers, balances }: { suppliers: Supplier[]; balances: SupplierBalance[] }) {
  const [editing, setEditing] = useState<Supplier | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [payingFor, setPayingFor] = useState<Supplier | null>(null);
  const [pending, startTransition] = useTransition();

  const balanceOf = (id: string) => balances.find((b) => b.supplier_id === id)?.balance ?? 0;

  function handleDelete() {
    if (!deletingId) return;
    startTransition(async () => {
      const result = await deleteSupplier(deletingId);
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
      <DataTable<Supplier>
        rows={suppliers}
        getRowKey={(s) => s.id}
        emptyLabel="لا يوجد موردون بعد — أضف أول مورد أعلاه"
        columns={[
          { header: "الاسم", render: (s) => s.name },
          { header: "الهاتف", render: (s) => <span dir="ltr">{s.phone ?? "—"}</span> },
          {
            header: "الرصيد المستحق",
            render: (s) => {
              const bal = balanceOf(s.id);
              return (
                <span dir="ltr" className={bal > 0 ? "font-medium text-rose" : "text-charcoal/50"}>
                  {money(bal)} ج.م
                </span>
              );
            },
          },
          {
            header: "",
            render: (s) => (
              <div className="flex items-center justify-end gap-1">
                <button onClick={() => setPayingFor(s)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-sageSoft/40 hover:text-sage" aria-label="تسجيل دفعة">
                  <Wallet size={15} strokeWidth={2} />
                </button>
                <button onClick={() => setEditing(s)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-paper hover:text-ink" aria-label="تعديل">
                  <Pencil size={15} strokeWidth={2} />
                </button>
                <button onClick={() => setDeletingId(s.id)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-rose/10 hover:text-rose" aria-label="حذف">
                  <Trash2 size={15} strokeWidth={2} />
                </button>
              </div>
            ),
          },
        ]}
      />

      <Modal open={!!editing} onClose={() => setEditing(null)} title="تعديل بيانات المورد">
        {editing && (
          <form action={updateSupplier.bind(null, editing.id)} onSubmit={() => setEditing(null)} className="space-y-4">
            <Field label="اسم المورد">
              <Input name="name" required defaultValue={editing.name} />
            </Field>
            <Field label="رقم الهاتف">
              <Input name="phone" dir="ltr" defaultValue={editing.phone ?? ""} />
            </Field>
            <Field label="الرصيد الافتتاحي">
              <Input name="opening_balance" type="number" step="0.01" dir="ltr" defaultValue={editing.opening_balance} />
            </Field>
            <Button type="submit" className="w-full">
              حفظ التعديلات
            </Button>
          </form>
        )}
      </Modal>

      <ConfirmDialog
        open={!!deletingId}
        title="حذف المورد؟"
        description="سيتم حذف بيانات هذا المورد نهائيًا. لا يمكن التراجع عن هذا الإجراء."
        loading={pending}
        error={deleteError}
        onCancel={() => {
          setDeletingId(null);
          setDeleteError(null);
        }}
        onConfirm={handleDelete}
      />

      <PaymentModal supplier={payingFor} onClose={() => setPayingFor(null)} />
    </>
  );
}

function PaymentModal({ supplier, onClose }: { supplier: Supplier | null; onClose: () => void }) {
  const [amount, setAmount] = useState(0);
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [method, setMethod] = useState("نقدًا");
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    if (!supplier) return;
    setError(null);
    startTransition(async () => {
      const result = await recordSupplierPayment({
        supplier_id: supplier.id,
        amount,
        payment_date: date,
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
    <Modal open={!!supplier} onClose={onClose} title={supplier ? `تسجيل دفعة إلى ${supplier.name}` : "تسجيل دفعة"}>
      <div className="space-y-4">
        <Field label="المبلغ">
          <Input type="number" step="0.01" min="0" dir="ltr" value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
        </Field>
        <Field label="تاريخ الدفع">
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
          {pending ? "جارٍ الحفظ..." : "تسجيل الدفعة"}
        </Button>
      </div>
    </Modal>
  );
}
