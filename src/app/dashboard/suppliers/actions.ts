"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";
import { AUTH_ERROR, NAME_REQUIRED } from "@/lib/action-result";
import { setOpeningBalance, canEditOpeningBalance } from "@/lib/opening-balance";

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

  if (error) return { error: error.message };

  revalidatePath("/dashboard/suppliers");
  revalidatePath("/dashboard/purchases");
  return { error: null };
}

export type SupplierImportRow = { name: string; phone: string; opening_balance: number };

// §56: suppliers + opening balances. Same skip-don't-merge rule as
// customers so re-importing can't double-count a payable.
export async function importSuppliersCsv(rows: SupplierImportRow[]) {
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

  let created = 0;
  const skipped: { row: number; reason: string }[] = [];

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

    const { data: inserted, error } = await supabase
      .from("suppliers")
      .insert({
        organization_id: orgId,
        name,
        phone: row.phone.trim() || null,
      })
      .select("id")
      .single();
    if (error || !inserted) {
      skipped.push({ row: i + 1, reason: error?.message ?? "تعذر الإنشاء" });
      continue;
    }
    if (canSetBalance && row.opening_balance !== 0) {
      const ob = await setOpeningBalance(supabase, "supplier", inserted.id, row.opening_balance);
      if (ob.error) skipped.push({ row: i + 1, reason: `تم إنشاء المورد لكن تعذر حفظ الرصيد الافتتاحي: ${ob.error}` });
    }
    existingNames.add(name);
    created++;
  }

  revalidatePath("/dashboard/suppliers");
  return { created, skipped, error: null };
}
