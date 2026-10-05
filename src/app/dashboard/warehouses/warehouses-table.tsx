"use client";

import { useState, useTransition } from "react";
import { Pencil, Trash2 } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { updateWarehouse, deleteWarehouse } from "./actions";

type Warehouse = { id: string; name: string; location: string | null };

export function WarehousesTable({ warehouses }: { warehouses: Warehouse[] }) {
  const [editing, setEditing] = useState<Warehouse | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function handleDelete() {
    if (!deletingId) return;
    startTransition(async () => {
      const result = await deleteWarehouse(deletingId);
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
      <DataTable<Warehouse>
        rows={warehouses}
        getRowKey={(w) => w.id}
        emptyLabel="لا توجد مخازن بعد — أضف أول مخزن أعلاه"
        columns={[
          { header: "الاسم", render: (w) => w.name },
          { header: "الموقع", render: (w) => w.location ?? "—" },
          {
            header: "",
            render: (w) => (
              <div className="flex items-center justify-end gap-1">
                <button onClick={() => setEditing(w)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-paper hover:text-ink" aria-label="تعديل">
                  <Pencil size={15} strokeWidth={2} />
                </button>
                <button onClick={() => setDeletingId(w.id)} className="cursor-pointer rounded-card p-1.5 text-ink/40 hover:bg-rose/10 hover:text-rose" aria-label="حذف">
                  <Trash2 size={15} strokeWidth={2} />
                </button>
              </div>
            ),
          },
        ]}
      />

      <Modal open={!!editing} onClose={() => setEditing(null)} title="تعديل بيانات المخزن">
        {editing && (
          <form action={updateWarehouse.bind(null, editing.id)} onSubmit={() => setEditing(null)} className="space-y-4">
            <Field label="اسم المخزن">
              <Input name="name" required defaultValue={editing.name} />
            </Field>
            <Field label="الموقع">
              <Input name="location" defaultValue={editing.location ?? ""} />
            </Field>
            <Button type="submit" className="w-full">
              حفظ التعديلات
            </Button>
          </form>
        )}
      </Modal>

      <ConfirmDialog
        open={!!deletingId}
        title="حذف المخزن؟"
        description="سيتم حذف هذا المخزن نهائيًا. لا يمكن التراجع عن هذا الإجراء."
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
