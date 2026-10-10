"use client";

import { useState, useTransition } from "react";
import { Pencil, Trash2 } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { updateProduct, deleteProduct } from "./actions";

type ProductRow = {
  id: string;
  name: string;
  sku: string | null;
  unit: string;
  category_id: string | null;
  product_categories: { name: string } | null;
  product_prices: { cost: number; selling_price: number; wholesale_price: number | null; distributor_price: number | null }[];
};

type Category = { id: string; name: string };

export function ProductsTable({ products, categories, canViewCost, canEditCost }: { products: ProductRow[]; categories: Category[]; canViewCost: boolean; canEditCost: boolean }) {
  const [editing, setEditing] = useState<ProductRow | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function handleDelete() {
    if (!deletingId) return;
    startTransition(async () => {
      const result = await deleteProduct(deletingId);
      if (result?.error) {
        setDeleteError(result.error);
        return;
      }
      setDeletingId(null);
      setDeleteError(null);
    });
  }

  const editingPrice = editing?.product_prices?.[0];

  return (
    <>
      <DataTable<ProductRow>
        rows={products}
        getRowKey={(p) => p.id}
        emptyLabel="لا توجد منتجات بعد — أضف أول منتج أعلاه"
        columns={[
          { header: "المنتج", render: (p) => p.name },
          { header: "الكود", render: (p) => <span dir="ltr">{p.sku ?? "—"}</span> },
          { header: "التصنيف", render: (p) => p.product_categories?.name ?? "—" },
          { header: "الوحدة", render: (p) => p.unit },
          { header: "سعر البيع", render: (p) => <span dir="ltr">{(p.product_prices?.[0]?.selling_price ?? 0).toFixed(2)} ج.م</span> },
          {
            header: "",
            render: (p) => (
              <div className="flex items-center justify-end gap-1">
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

      <Modal open={!!editing} onClose={() => setEditing(null)} title="تعديل بيانات المنتج">
        {editing && (
          <form action={updateProduct.bind(null, editing.id)} onSubmit={() => setEditing(null)} className="space-y-4">
            <Field label="اسم المنتج">
              <Input name="name" required defaultValue={editing.name} />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="كود المنتج (SKU)">
                <Input name="sku" dir="ltr" defaultValue={editing.sku ?? ""} />
              </Field>
              <Field label="وحدة القياس">
                <Input name="unit" defaultValue={editing.unit} />
              </Field>
            </div>
            <Field label="التصنيف">
              <ModernSelect name="category_id" defaultValue={editing.category_id ?? ""} options={categories.map((c) => ({ value: c.id, label: c.name }))} />
            </Field>
            <Field label="أو تصنيف جديد">
              <Input name="new_category" placeholder="اتركه فارغًا للإبقاء على التصنيف الحالي" />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              {canViewCost && (<Field label="التكلفة">
                <Input name="cost" type="number" step="0.01" dir="ltr" readOnly={!canEditCost} defaultValue={editingPrice?.cost ?? 0} />
              </Field>)}
              <Field label="سعر البيع (تجزئة)">
                <Input name="selling_price" type="number" step="0.01" dir="ltr" defaultValue={editingPrice?.selling_price ?? 0} />
              </Field>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <Field label="سعر الجملة (اختياري)">
                <Input name="wholesale_price" type="number" step="0.01" dir="ltr" defaultValue={editingPrice?.wholesale_price ?? ""} placeholder="بلا — يُستخدم سعر التجزئة" />
              </Field>
              <Field label="سعر الموزع (اختياري)">
                <Input name="distributor_price" type="number" step="0.01" dir="ltr" defaultValue={editingPrice?.distributor_price ?? ""} placeholder="بلا — يُستخدم سعر التجزئة" />
              </Field>
            </div>
            <Button type="submit" className="w-full">
              حفظ التعديلات
            </Button>
          </form>
        )}
      </Modal>

      <ConfirmDialog
        open={!!deletingId}
        title="حذف المنتج؟"
        description="سيتم حذف هذا المنتج وسعره نهائيًا. لا يمكن التراجع عن هذا الإجراء."
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
