// Full company data export (one .xlsx, one sheet per kind of record). Everything about WHAT is exported lives here so it can be tested;
// the route handler (src/app/api/export/company/route.ts) does the authorization and the reading.
//
// Isolation: the route reads with the signed-in owner's own session (row-level security) AND filters every table by organization_id,
// so a second line of defence backs the database policy. Excel only (Kayan has no CSV); Arabic sheet names / headers; sheets are right-to-left.

export type ExportTable = { table: string; sheet: string; omit?: string[] };

// Sheet names: ≤ 31 characters, none of  \ / ? * [ ] :   (Excel rules)
export const EXPORT_TABLES: ExportTable[] = [
  { table: "customers", sheet: "العملاء" },
  { table: "suppliers", sheet: "الموردون" },
  { table: "product_categories", sheet: "تصنيفات المنتجات" },
  { table: "expense_categories", sheet: "تصنيفات المصروفات" },
  { table: "products", sheet: "المنتجات" },
  { table: "warehouses", sheet: "المخازن" },
  { table: "inventory_stock", sheet: "أرصدة المخزون" },
  { table: "inventory_movements", sheet: "حركات المخزون" },
  { table: "sales_invoices", sheet: "فواتير المبيعات" },
  { table: "sales_invoice_items", sheet: "أصناف المبيعات" },
  { table: "sales_returns", sheet: "مرتجعات المبيعات" },
  { table: "customer_collections", sheet: "تحصيلات العملاء" },
  { table: "purchase_invoices", sheet: "فواتير المشتريات" },
  { table: "purchase_invoice_items", sheet: "أصناف المشتريات" },
  { table: "purchase_returns", sheet: "مرتجعات المشتريات" },
  { table: "supplier_payments", sheet: "مدفوعات الموردين" },
  { table: "expenses", sheet: "المصروفات" },
  { table: "treasury_movements", sheet: "حركات الخزنة" },
  { table: "partners", sheet: "الشركاء" },
  { table: "partner_withdrawals", sheet: "سحوبات الشركاء" },
  { table: "sales_representatives", sheet: "المندوبون" },
  { table: "organization_users", sheet: "الفريق", omit: ["user_id"] },
  { table: "audit_logs", sheet: "سجل المراجعة", omit: ["user_id"] },
];

/** Columns that never go into a data export: tenant plumbing and anything credential-like. */
const ALWAYS_OMIT = new Set(["organization_id", "password", "token", "secret", "api_key"]);

export const MAX_ROWS_PER_SHEET = 50_000;
export const PAGE_SIZE = 1000; // the API's own page cap — the export pages through it, so it is not limited to 1000 rows

const HEADER_AR: Record<string, string> = {
  id: "المعرّف", name: "الاسم", phone: "الهاتف", email: "البريد", address: "العنوان", notes: "ملاحظات", created_at: "تاريخ الإنشاء", updated_at: "آخر تعديل",
  invoice_date: "تاريخ الفاتورة", invoice_number: "رقم الفاتورة", status: "الحالة", total: "الإجمالي", subtotal: "المجموع الفرعي", discount: "الخصم", paid_amount: "المدفوع",
  customer_id: "معرّف العميل", supplier_id: "معرّف المورد", product_id: "معرّف المنتج", warehouse_id: "معرّف المخزن", quantity: "الكمية", unit: "الوحدة", unit_price: "سعر الوحدة",
  unit_cost: "تكلفة الوحدة", amount: "المبلغ", payment_method: "طريقة الدفع", expense_date: "تاريخ المصروف", collection_date: "تاريخ التحصيل", payment_date: "تاريخ الدفع",
  movement_date: "تاريخ الحركة", return_date: "تاريخ المرتجع", sku: "الكود", barcode: "الباركود", action: "الإجراء", entity: "الكيان", display_name: "الاسم المعروض",
};
export const headerFor = (key: string) => HEADER_AR[key] ?? key;

export type SheetPlan = { sheet: string; keys: string[]; rows: unknown[][]; truncated: boolean };

export function safeSheetName(name: string, used: Set<string>): string {
  let base = name.replace(/[\\/?*[\]:]/g, " ").trim().slice(0, 31) || "Sheet";
  let n = base, i = 2;
  while (used.has(n.toLowerCase())) { const suffix = ` ${i++}`; n = base.slice(0, 31 - suffix.length) + suffix; }
  used.add(n.toLowerCase());
  return n;
}

/** Excel cell values: plain numbers / text / booleans; objects (jsonb) become JSON text; text is capped (a cell holds ≤ 32 767 characters). */
export function cellValue(v: unknown): string | number | boolean | null {
  if (v === null || v === undefined) return null;
  if (typeof v === "number" || typeof v === "boolean") return v;
  if (typeof v === "string") return v.length > 32000 ? v.slice(0, 32000) + "…" : v;
  try { return JSON.stringify(v).slice(0, 32000); } catch { return String(v); }
}

export function planSheet(def: ExportTable, records: Record<string, unknown>[], truncated: boolean): SheetPlan {
  const omit = new Set([...ALWAYS_OMIT, ...(def.omit ?? [])]);
  const keys: string[] = [];
  for (const r of records) for (const k of Object.keys(r)) if (!omit.has(k) && !keys.includes(k)) keys.push(k);
  // id first, created_at last: stable, readable order whatever the table's column order is
  keys.sort((a, b) => (a === "id" ? -1 : b === "id" ? 1 : a === "created_at" ? 1 : b === "created_at" ? -1 : 0));
  return { sheet: def.sheet, keys, rows: records.map((r) => keys.map((k) => cellValue(r[k]))), truncated };
}
