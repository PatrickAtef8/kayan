"use client";

import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { AsyncSearchSelect } from "@/components/ui/async-search-select";
import { ReturnFormModal } from "./return-form-modal";
import { searchSalesInvoices } from "./actions";

export function NewReturnButton() {
  const [selected, setSelected] = useState<{ id: string; label: string } | null>(null);
  const [open, setOpen] = useState(false);

  return (
    <div className="mb-7 flex flex-wrap items-end gap-3">
      <div className="w-64">
        <AsyncSearchSelect value={selected?.id ?? ""} selectedLabel={selected?.label} onChange={(id, label) => setSelected({ id, label })} search={searchSalesInvoices} placeholder="اختر فاتورة بيع" searchPlaceholder="ابحث برقم الفاتورة أو الاسم..." />
      </div>
      <Button type="button" disabled={!selected} onClick={() => setOpen(true)} className="flex items-center gap-1.5">
        <Plus size={15} strokeWidth={2.2} />
        تسجيل مرتجع
      </Button>

      {selected && <ReturnFormModal open={open} onClose={() => setOpen(false)} salesInvoiceId={selected.id} invoiceLabel={selected.label} />}
    </div>
  );
}
