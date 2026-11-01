"use server";

import { revalidatePath } from "next/cache";
import { translateDbError, safeErrorMessage } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";
import { AUTH_ERROR, NAME_REQUIRED } from "@/lib/action-result";
import { setOpeningBalance, canEditOpeningBalance } from "@/lib/opening-balance";
import { insertChunked, upsertChunked, type BulkItem } from "@/lib/bulk";

// Default payment terms in days (optional, 0-365): new purchase invoices get their due date from it.
function readTerms(formData: FormData): number | null {
  const raw = String(formData.get("payment_terms_days") || "").trim();
  if (!raw) return null;
  const n = Math.round(Number(raw));
  return Number.isFinite(n) ? Math.min(365, Math.max(0, n)) : null;
}

export async function createSupplier(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: AUTH_ERROR };

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (!membership) return { error: AUTH_ERROR };

  const name = String(formData.get("name") || "").trim();
  if (!name) return { error: NAME_REQUIRED };

  const { data: created, error } = await supabase
    .from("suppliers")
    .insert({
      organization_id: membership.organization_id,
      name,
      phone: String(formData.get("phone") || "") || null,
      payment_terms_days: readTerms(formData),
    })
    .select("id")
    .single();

  if (error || !created) return { error: translateDbError(error, "suppliers") };

  const opening = Number(formData.get("opening_balance") || 0);
  if (created && formData.has("opening_balance") && opening !== 0) {
    const ob = await setOpeningBalance(supabase, "supplier", created.id, opening);
    if (ob.error) return { error: `أُضيف المورد لكن تعذّر حفظ الرصيد الافتتاحي: ${ob.error}` };
  }

  revalidatePath("/dashboard/suppliers");
  return { error: null };
}

export async function updateSupplier(id: string, formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: AUTH_ERROR };

  const name = String(formData.get("name") || "").trim();
  if (!name) return { error: NAME_REQUIRED };

  const { error } = await supabase
    .from("suppliers")
    .update({
      name,
      phone: String(formData.get("phone") || "") || null,
      payment_terms_days: readTerms(formData),
    })
    .eq("id", id);
  if (error) return { error: translateDbError(error, "suppliers") };

  if (formData.has("opening_balance")) {
    const ob = await setOpeningBalance(supabase, "supplier", id, Number(formData.get("opening_balance") || 0));
    if (ob.error) return { error: ob.error };
  }

  revalidatePath("/dashboard/suppliers");
  return { error: null };
}

export async function deleteSupplier(id: string) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("suppliers").delete().eq("id", id);
  if (error) return { error: translateDbError(error, "suppliers") };

  revalidatePath("/dashboard/suppliers");
  return { error: null };
}

export async function recordSupplierPayment(input: {
  supplier_id: string;
  amount: number;
  payment_date: string;
  payment_method: string;
  reference: string;
  notes: string;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (!membership) return { error: "غير مصرح" };

  if (!input.supplier_id || !(input.amount > 0)) return { error: "أدخل مبلغًا صحيحًا" };

  const { error } = await supabase.rpc("record_supplier_payment", {
    org_id: membership.organization_id,
    p_supplier_id: input.supplier_id,
    p_purchase_invoice_id: null,
    p_amount: input.amount,
    p_payment_date: input.payment_date || new Date().toISOString().slice(0, 10),
    p_payment_method: input.payment_method,
    p_reference: input.reference,
    p_notes: input.notes,
  });

  if (error) return { error: safeErrorMessage(error) };

  revalidatePath("/dashboard/suppliers");
  revalidatePath("/dashboard/purchases");
  return { error: null };
}

export type SupplierImportRow = { name: string; phone: string; opening_balance: number };

// §56: suppliers + opening balances. Same skip-don't-merge rule as
// customers so re-importing can't double-count a payable.
// Import is postponed: there is no import screen right now (CSV was removed — users work with Excel and PDF only).
// This server action is kept, unchanged, for the upcoming Excel import; nothing calls it yet.
export async function importSuppliers(rows: SupplierImportRow[]) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { created: 0, skipped: [], error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (!membership) return { created: 0, skipped: [], error: "غير مصرح" };
  const orgId = membership.organization_id;

  if (rows.length > 2000) return { created: 0, skipped: [], error: "الحد الأقصى 2000 صف في الملف الواحد" };

  // Opening balances are balances: only finance roles may WRITE them (enforced by the database too).
  const canSetBalance = await canEditOpeningBalance(supabase, orgId);

  const { data: existing } = await supabase.from("suppliers").select("name").eq("organization_id", orgId);
  const existingNames = new Set((existing ?? []).map((s) => s.name.trim()));

  const skipped: { row: number; reason: string }[] = [];

  // Pass 1 — validate every row (same rules, same order, same messages as before).
  const items: BulkItem[] = [];
  const balanceByRow = new Map<number, number>();
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const name = row.name.trim();
    if (!name) {
      skipped.push({ row: i + 1, reason: "اسم المورد مطلوب" });
      continue;
    }
    if (existingNames.has(name)) {
      skipped.push({ row: i + 1, reason: `مورد بهذا الاسم موجود بالفعل: ${name}` });
      continue;
    }
    if (!Number.isFinite(row.opening_balance)) {
      skipped.push({ row: i + 1, reason: "الرصيد الافتتاحي غير صحيح" });
      continue;
    }
    existingNames.add(name);
    items.push({ row: i + 1, data: { organization_id: orgId, name, phone: row.phone.trim() || null } });
    balanceByRow.set(i + 1, row.opening_balance);
  }

  // Pass 2 — insert in chunks (one request per 200 suppliers instead of one per supplier).
  const { inserted, failed } = await insertChunked(supabase, "suppliers", items, "تعذر الإنشاء");
  for (const f of failed) skipped.push({ row: f.row, reason: f.error });

  // Pass 3 — opening balances in chunks; a refused chunk is retried row by row to report the exact row.
  if (canSetBalance) {
    const withBalance = inserted.filter((r) => (balanceByRow.get(r.row) ?? 0) !== 0);
    const results = await upsertChunked(supabase, "supplier_opening_balances", withBalance.map((r) => ({ supplier_id: r.id, amount: balanceByRow.get(r.row) })), "supplier_id");
    for (let c = 0; c < results.length; c++) {
      if (!results[c].error) continue;
      for (const r of withBalance.slice(c * 500, c * 500 + 500)) {
        const ob = await setOpeningBalance(supabase, "supplier", r.id, balanceByRow.get(r.row) as number);
        if (ob.error) skipped.push({ row: r.row, reason: `تم إنشاء المورد لكن تعذر حفظ الرصيد الافتتاحي: ${ob.error}` });
      }
    }
  }
  const created = inserted.length;
  skipped.sort((a, b) => a.row - b.row);

  revalidatePath("/dashboard/suppliers");
  return { created, skipped, error: null };
}
