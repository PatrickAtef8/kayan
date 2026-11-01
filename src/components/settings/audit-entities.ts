// Plain (non-"use client") module on purpose: the audit page (a Server Component) needs these
// values at render time. Anything exported from a "use client" file reaches a Server Component
// only as a client reference, so calling .find() on it throws.
export const ENTITY_OPTIONS = [
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
  { value: "stocktake", label: "جرد مخزني" },
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
  { value: "license", label: "ترخيص الباقة" },
  { value: "billing_order", label: "طلب دفع" },
];

