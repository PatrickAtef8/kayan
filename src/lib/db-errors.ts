// Every "delete X" action in this app used to do
// `await supabase.from(table).delete().eq("id", id)` and ignore the
// result entirely. Most of this app's core tables reference each other
// with `on delete restrict` on purpose (§48 historical-data-integrity: a
// customer with sales history, a product with stock movements, etc. must
// not disappear out from under real transactions) — but a blocked delete
// throws a Postgres foreign-key-violation, and with the result ignored,
// the row silently stayed exactly as it was while the UI acted like
// nothing was wrong. This turns that error into something a person can
// actually act on, tuned per-entity so it names what's actually
// attached rather than a generic "can't delete this."
type PostgrestErrorLike = { code?: string; message?: string; details?: string | null; hint?: string | null } | null | undefined;

// Column / constraint names -> the label the person sees on the form. Used so a duplicate
// error says WHICH box is repeated (and with which value) instead of a generic sentence.
const FIELD_LABELS: Record<string, string> = {
  barcode: "الباركود",
  sku: "كود الصنف (SKU)",
  name: "الاسم",
  code: "الكود",
  phone: "رقم الهاتف",
  email: "البريد الإلكتروني",
  min_amount: "الحد الأدنى للشريحة",
  invoice_number: "رقم الفاتورة",
  number: "الرقم",
};

/**
 * Describes a unique-violation precisely, e.g. «الباركود "6221234" مستخدم بالفعل في سجل آخر».
 * Postgres reports `Key (organization_id, barcode)=(<org>, 6221234) already exists.` in `details`
 * and the constraint/index name in `message`; both are parsed here. Returns null when nothing can be identified.
 */
export function describeDuplicate(error: PostgrestErrorLike): string | null {
  if (!error) return null;
  const text = `${error.message ?? ""} ${error.details ?? ""}`;
  let cols: string[] = [];
  let vals: string[] = [];
  const key = /Key \(([^)]+)\)=\(([\s\S]+)\) already exists/.exec(text);
  if (key) {
    cols = key[1].split(",").map((c) => c.trim());
    vals = key[2].split(",").map((v) => v.trim());
  }
  // Drop the tenant column — the person doesn't need to see "organization_id".
  const pairs = cols
    .map((c, i) => ({ col: c, val: vals[i] ?? "" }))
    .filter((p) => p.col !== "organization_id" && p.col !== "org_id");
  if (pairs.length === 0) {
    const constraint = /(?:constraint|index) "([^"]+)"/.exec(text)?.[1] ?? "";
    const hit = Object.keys(FIELD_LABELS).find((k) => new RegExp(`(^|_)${k}(_|$)`).test(constraint));
    return hit ? `${FIELD_LABELS[hit]} مستخدم بالفعل في سجل آخر — غيّره أو راجع السجل المكرر.` : null;
  }
  const parts = pairs.map((p) => `${FIELD_LABELS[p.col] ?? p.col}${p.val ? ` "${p.val}"` : ""}`);
  return `${parts.join(" + ")} مستخدم بالفعل في سجل آخر — غيّره أو راجع السجل المكرر.`;
}

const RESTRICT_MESSAGE: Record<string, string> = {
  customers: "لا يمكن حذف هذا العميل لأن لديه فواتير أو تحصيلات مسجلة — يمكنك تعديل بياناته بدلاً من حذفه.",
  suppliers: "لا يمكن حذف هذا المورد لأن لديه فواتير أو مدفوعات مسجلة — يمكنك تعديل بياناته بدلاً من حذفه.",
  products: "لا يمكن حذف هذا المنتج لوجود حركات مخزون أو فواتير تتضمنه — يمكنك إلغاء تفعيله بدلاً من حذفه.",
  warehouses: "لا يمكن حذف هذا المخزن لوجود أرصدة أو فواتير مرتبطة به.",
  partners: "لا يمكن حذف هذا الشريك لوجود عمليات سحب مسجلة باسمه.",
  sales_representatives: "لا يمكن حذف هذا المندوب لوجود فواتير بيع مسجلة باسمه — يمكنك إلغاء تفعيله بدلاً من حذفه.",
  expense_categories: "لا يمكن حذف هذا التصنيف لوجود مصروفات مسجلة تحته.",
  roles: "لا يمكن حذف هذا الدور لوجود أعضاء مُسندين إليه.",
};

export function translateDbError(error: PostgrestErrorLike, table?: string): string {
  if (!error) return "حدث خطأ غير متوقع";

  // 23503 = foreign_key_violation (Postgres SQLSTATE)
  if (error.code === "23503") {
    return (table && RESTRICT_MESSAGE[table]) || "لا يمكن الحذف لوجود بيانات أخرى مرتبطة بهذا السجل.";
  }
  // 23505 = unique_violation
  if (error.code === "23505") {
    return describeDuplicate(error) ?? "يوجد سجل آخر بنفس البيانات بالفعل.";
  }
  // 42501 / PGRST301-ish = RLS denied the row (permission, not a missing row)
  if (error.code === "42501" || error.code === "PGRST301") {
    return "ليس لديك صلاحية تنفيذ هذا الإجراء.";
  }

  return safeErrorMessage(error);
}

const ARABIC = /[\u0600-\u06FF]/;

/**
 * What a person may be shown for a database error.
 * The RPCs raise their business messages in Arabic on purpose ("المخزون غير كافٍ …"): those pass through untouched. Anything else —
 * an English Postgres message, a constraint / column / table name, a SQLSTATE detail — is internal and is replaced by a generic
 * sentence; the original goes to the server log so it can still be diagnosed.
 */
export function safeErrorMessage(error: PostgrestErrorLike): string {
  const msg = error?.message?.trim() ?? "";
  if (msg && ARABIC.test(msg)) return msg;
  switch (error?.code) {
    case "42501": case "PGRST301": return "ليس لديك صلاحية تنفيذ هذا الإجراء.";
    case "23505": return describeDuplicate(error) ?? "يوجد سجل آخر بنفس البيانات بالفعل.";
    case "23503": return "لا يمكن تنفيذ العملية لوجود بيانات مرتبطة بهذا السجل.";
    case "23502": case "23514": case "22P02": case "22003": case "22001": return "البيانات المُدخلة غير صالحة. راجعها وحاول مرة أخرى.";
  }
  if (/row-level security/i.test(msg)) return "ليس لديك صلاحية تنفيذ هذا الإجراء.";
  if (msg) console.error("database error (hidden from the user):", { code: error?.code, message: msg });
  return "حدث خطأ غير متوقع. حاول مرة أخرى.";
}
