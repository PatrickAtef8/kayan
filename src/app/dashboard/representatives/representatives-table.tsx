"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { Pencil, Trash2, Power } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { ModernSelect } from "@/components/ui/select";
import { updateRepresentative, deleteRepresentative, toggleRepresentativeActive } from "./actions";
import { COMMISSION_BASIS_LABELS, COMMISSION_BASIS_OPTIONS } from "./commission-basis";
import type { Representative, MemberOption } from "./page";

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

export function RepresentativesTable({ representatives, members }: { representatives: Representative[]; members: MemberOption[] }) {
  const [editing, setEditing] = useState<Representative | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const [togglingId, setTogglingId] = useState<string | null>(null);

  function handleDelete() {
    if (!deletingId) return;
    startTransition(async () => {
      const result = await deleteRepresentative(deletingId);
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
      <DataTable<Representative>
        rows={representatives}
        getRowKey={(r) => r.id}
        emptyLabel="لا يوجد مندوبون بعد — أضف أول مندوب أعلاه"
        columns={[
          { header: "الاسم", render: (r) => <Link href={`/dashboard/reports/reps/${r.id}`} className={r.is_active ? "text-sage hover:underline" : "text-charcoal/35"}>{r.name}{r.is_active ? "" : " (موقوف)"}</Link> },
          { header: "الهاتف", render: (r) => <span dir="ltr">{r.phone ?? "—"}</span> },
          { header: "الراتب", render: (r) => <span dir="ltr">{money(r.fixed_salary)} ج.م</span> },
          { header: "بدل المواصلات", render: (r) => <span dir="ltr">{money(r.transportation_allowance)} ج.م</span> },
          { header: "Target شهري", render: (r) => <span dir="ltr">{money(r.monthly_target)} ج.م</span> },
          { header: "حد العمولة", render: (r) => <span dir="ltr">{r.min_target_for_commission > 0 ? `${money(r.min_target_for_commission)} ج.م` : "بدون حد"}</span> },
          { header: "العمولة", render: (r) => `${r.commission_rate}% من ${COMMISSION_BASIS_LABELS[r.commission_basis] ?? r.commission_basis}` },
          {
            header: "",
            render: (r) => (
              <div className="flex items-center justify-end gap-1">
                <button
                  onClick={() => {
                    setTogglingId(r.id);
                    startTransition(async () => {
                      await toggleRepresentativeActive(r.id, !r.is_active);
                      setTogglingId(null);
                    });
                  }}
                  disabled={pending && togglingId === r.id}
                  className={`cursor-pointer rounded-card p-1.5 ${r.is_active ? "text-ink/40 hover:bg-rose/10 hover:text-rose" : "text-ink/40 hover:bg-sageSoft/40 hover:text-sage"}`}
                  aria-label={r.is_active ? "إيقاف" : "تفعيل"}
                >
                  {pending && togglingId === r.id ? <Spinner size={14} /> : <Power size={15} strokeWidth={2} />}
                </button>
                <button onClick={() => setEditing(r)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-paper hover:text-ink" aria-label="تعديل">
                  <Pencil size={15} strokeWidth={2} />
                </button>
                <button onClick={() => setDeletingId(r.id)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-rose/10 hover:text-rose" aria-label="حذف">
                  <Trash2 size={15} strokeWidth={2} />
                </button>
              </div>
            ),
          },
        ]}
      />

      <Modal open={!!editing} onClose={() => setEditing(null)} title="تعديل بيانات المندوب">
        {editing && (
          <form action={updateRepresentative.bind(null, editing.id)} onSubmit={() => setEditing(null)} className="space-y-4">
            <Field label="اسم المندوب">
              <Input name="name" required defaultValue={editing.name} />
            </Field>
            <Field label="رقم الهاتف">
              <Input name="phone" dir="ltr" defaultValue={editing.phone ?? ""} />
            </Field>
            <Field label="الراتب الثابت">
              <Input name="fixed_salary" type="number" step="0.01" min="0" dir="ltr" defaultValue={editing.fixed_salary} />
            </Field>
            <Field label="بدل المواصلات">
              <Input name="transportation_allowance" type="number" step="0.01" min="0" dir="ltr" defaultValue={editing.transportation_allowance} />
            </Field>
            <Field label="نسبة العمولة (%)">
              <Input name="commission_rate" type="number" step="0.01" min="0" max="100" dir="ltr" defaultValue={editing.commission_rate} />
            </Field>
            <Field label="Target المبيعات الشهري (ج.م)">
              <Input name="monthly_target" type="number" step="0.01" min="0" dir="ltr" defaultValue={editing.monthly_target} />
            </Field>
            <Field label="الحد الأدنى لاستحقاق العمولة (ج.م/شهر)">
              <Input name="min_target_for_commission" type="number" step="0.01" min="0" dir="ltr" defaultValue={editing.min_target_for_commission} />
            </Field>
            <Field label="مستخدم النظام (دخول المندوب)">
              <ModernSelect name="user_id" defaultValue={editing.user_id ?? ""} placeholder="بدون" clearLabel="بدون" options={members} />
            </Field>
            <Field label="أساس احتساب العمولة">
              <ModernSelect name="commission_basis" allowClear={false} defaultValue={editing.commission_basis} options={COMMISSION_BASIS_OPTIONS} />
            </Field>
            <Button type="submit" className="w-full">
              حفظ التعديلات
            </Button>
          </form>
        )}
      </Modal>

      <ConfirmDialog
        open={!!deletingId}
        title="حذف المندوب؟"
        description="سيتم حذف بيانات هذا المندوب نهائيًا. الفواتير المرتبطة به ستبقى دون ربط بمندوب. لا يمكن التراجع عن هذا الإجراء."
        loading={pending}
        error={deleteError}
        onCancel={() => {
          setDeletingId(null);
          setDeleteError(null);
        }}
        onConfirm={handleDelete}
      />
    </>
  );
}
