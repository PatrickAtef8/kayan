"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";

export async function createSupplier(formData: FormData) {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return;

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (!membership) return;

  const name = String(formData.get("name") || "").trim();
  if (!name) return;

  await supabase.from("suppliers").insert({
    organization_id: membership.organization_id,
    name,
    phone: String(formData.get("phone") || "") || null,
    opening_balance: Number(formData.get("opening_balance") || 0),
  });

  revalidatePath("/dashboard/suppliers");
}

export async function updateSupplier(id: string, formData: FormData) {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return;

  const name = String(formData.get("name") || "").trim();
  if (!name) return;

  await supabase
    .from("suppliers")
    .update({ name, phone: String(formData.get("phone") || "") || null, opening_balance: Number(formData.get("opening_balance") || 0) })
    .eq("id", id);

  revalidatePath("/dashboard/suppliers");
}

export async function deleteSupplier(id: string) {
  const supabase = createClient();
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
  const supabase = createClient();
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
  const supabase = createClient();
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

    const { error } = await supabase.from("suppliers").insert({
      organization_id: orgId,
      name,
      phone: row.phone.trim() || null,
      opening_balance: row.opening_balance,
    });
    if (error) {
      skipped.push({ row: i + 1, reason: error.message });
      continue;
    }
    existingNames.add(name);
    created++;
  }

  revalidatePath("/dashboard/suppliers");
  return { created, skipped, error: null };
}
