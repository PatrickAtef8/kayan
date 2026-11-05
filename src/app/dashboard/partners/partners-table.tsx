"use client";

import { useState, useTransition } from "react";
import { Pencil, Trash2, Wallet } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ActionForm, SubmitButton } from "@/components/ui/action-form";
import { updatePartner, deletePartner, recordPartnerWithdrawal } from "./actions";
import type { Partner } from "./page";
import { cairoDate } from "@/lib/report-period";

export function PartnersTable({ partners }: { partners: Partner[] }) {
  const [editing, setEditing] = useState<Partner | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [withdrawingFor, setWithdrawingFor] = useState<Partner | null>(null);
  const [pending, startTransition] = useTransition();

  function handleDelete() {
    if (!deletingId) return;
    startTransition(async () => {
      const result = await deletePartner(deletingId);
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
      <DataTable<Partner>
        rows={partners}
        getRowKey={(p) => p.id}
        emptyLabel="لا يوجد شركاء بعد — أضف أول شريك أعلاه"
        columns={[
          { header: "الاسم", render: (p) => p.name },
          { header: "الهاتف", render: (p) => <span dir="ltr">{p.phone ?? "—"}</span> },
          {
            header: "",
            render: (p) => (
              <div className="flex items-center justify-end gap-1">
                <button onClick={() => setWithdrawingFor(p)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-sageSoft/40 hover:text-sage" aria-label="تسجيل سحب">
                  <Wallet size={15} strokeWidth={2} />
                </button>
                <button onClick={() => setEditing(p)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-paper hover:text-ink" aria-label="تعديل">
                  <Pencil size={15} strokeWidth={2} />
                </button>
                <button onClick={() => setDeletingId(p.id)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-rose/10 hover:text-rose" aria-label="حذف">
                  <Trash2 size={15} strokeWidth={2} />
                </button>
              </div>
            ),
          },
        ]}
      />

      <Modal open={!!editing} onClose={() => setEditing(null)} title="تعديل بيانات الشريك">
        {editing && (
          <ActionForm action={updatePartner.bind(null, editing.id)} onSuccess={() => setEditing(null)} resetOnSuccess={false} className="space-y-4">
            <Field label="اسم الشريك">
              <Input name="name" required defaultValue={editing.name} />
            </Field>
            <Field label="رقم الهاتف">
              <Input name="phone" dir="ltr" defaultValue={editing.phone ?? ""} />
            </Field>
            <SubmitButton pendingText="جارٍ حفظ التعديلات..." className="w-full">حفظ التعديلات</SubmitButton>
          </ActionForm>
        )}
      </Modal>

      <ConfirmDialog
        open={!!deletingId}
        title="حذف الشريك؟"
        description="سيتم حذف بيانات هذا الشريك نهائيًا. لا يمكن التراجع عن هذا الإجراء."
        loading={pending}
        error={deleteError}
        onCancel={() => {
          setDeletingId(null);
          setDeleteError(null);
        }}
        onConfirm={handleDelete}
      />

      <WithdrawalModal partner={withdrawingFor} onClose={() => setWithdrawingFor(null)} />
    </>
  );
}

function WithdrawalModal({ partner, onClose }: { partner: Partner | null; onClose: () => void }) {
  const [amount, setAmount] = useState(0);
  const [date, setDate] = useState(() => cairoDate());
  const [description, setDescription] = useState("");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    if (!partner) return;
    setError(null);
    startTransition(async () => {
      const result = await recordPartnerWithdrawal({
        partner_id: partner.id,
        amount,
        withdrawal_date: date,
        description,
        notes,
      });
      if (result?.error) {
        setError(result.error);
        return;
      }
      setAmount(0);
      setDescription("");
      setNotes("");
      onClose();
    });
  }

  return (
    <Modal open={!!partner} onClose={onClose} title={partner ? `تسجيل سحب لـ ${partner.name}` : "تسجيل سحب"}>
      <div className="space-y-4">
        <Field label="المبلغ">
          <Input type="number" step="0.01" min="0" dir="ltr" value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
        </Field>
        <Field label="تاريخ السحب">
          <Input type="date" dir="ltr" value={date} onChange={(e) => setDate(e.target.value)} />
        </Field>
        <Field label="الوصف">
          <Input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="اختياري" />
        </Field>
        <Field label="ملاحظات">
          <Input value={notes} onChange={(e) => setNotes(e.target.value)} />
        </Field>
        {error && <p className="text-xs text-rose">{error}</p>}
        <Button type="button" className="w-full" disabled={pending} onClick={submit}>
          {pending ? "جارٍ الحفظ..." : "تسجيل السحب"}
        </Button>
      </div>
    </Modal>
  );
}
