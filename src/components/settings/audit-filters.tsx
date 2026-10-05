"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { ModernSelect } from "@/components/ui/select";

const ENTITY_OPTIONS = [
  { value: "", label: "كل الأنواع" },
  { value: "sales_invoice", label: "فاتورة بيع" },
  { value: "sales_return", label: "مرتجع بيع" },
  { value: "purchase_invoice", label: "فاتورة شراء" },
  { value: "purchase_return", label: "مرتجع شراء" },
  { value: "customer_collection", label: "تحصيل" },
  { value: "supplier_payment", label: "دفعة مورد" },
  { value: "expense", label: "مصروف" },
  { value: "partner_withdrawal", label: "سحب شريك" },
  { value: "treasury_movement", label: "حركة خزنة" },
  { value: "inventory_adjustment", label: "تسوية مخزون" },
  { value: "stock_transfer", label: "نقل بين مخازن" },
  { value: "attachment", label: "مرفق" },
  { value: "product_price", label: "تغيير سعر" },
  { value: "customer", label: "عميل" },
  { value: "supplier", label: "مورد" },
  { value: "product", label: "منتج" },
  { value: "warehouse", label: "مخزن" },
  { value: "sales_representative", label: "مندوب" },
  { value: "partner", label: "شريك" },
  { value: "role", label: "دور" },
  { value: "user", label: "مستخدم" },
  { value: "module", label: "وحدة" },
  { value: "organization", label: "المؤسسة" },
];

export function AuditFilters({ entity }: { entity: string }) {
  const router = useRouter();
  const searchParams = useSearchParams();

  function setEntity(value: string) {
    const params = new URLSearchParams(searchParams.toString());
    if (value) params.set("entity", value);
    else params.delete("entity");
    router.push(`?${params.toString()}`, { scroll: false });
  }

  return (
    <div className="w-48 shrink-0">
      <ModernSelect value={entity} onChange={setEntity} allowClear={false} options={ENTITY_OPTIONS} />
    </div>
  );
}

export { ENTITY_OPTIONS };
