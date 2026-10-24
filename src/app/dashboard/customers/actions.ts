"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";
import { AUTH_ERROR, NAME_REQUIRED } from "@/lib/action-result";
import { setOpeningBalance, canEditOpeningBalance } from "@/lib/opening-balance";

// Customers are created, assigned to reps and deleted by the OWNER only. The database enforces this
// (policies + triggers); the check here gives a clear message before the request is even sent.
async function ownerOnly(supabase: Awaited<ReturnType<typeof createClient>>, orgId: string): Promise<string | null> {
  const { data } = await supabase.rpc("my_role_key", { target_org: orgId });
  return data === "owner" ? null : "إنشاء العملاء وتعيينهم للمناديب من صلاحيات المالك فقط";
}

// Server Action: runs with the caller's own session (cookies), so the
// insert is still governed by RLS — this isn't a privileged bypass.
export async function createCustomer(formData: FormData) {
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
  const denied = await ownerOnly(supabase, membership.organization_id);
  if (denied) return { error: denied };

  const name = String(formData.get("name") || "").trim();
  if (!name) return { error: NAME_REQUIRED };

  const { data: created, error } = await supabase
    .from("customers")
    .insert({
    organization_id: membership.organization_id,
    name,
    phone: String(formData.get("phone") || "") || null,
    customer_type: String(formData.get("customer_type") || "") || null,
    price_tier: String(formData.get("price_tier") || "") || "retail",
    // a rep creating a customer gets them assigned by the database; admins choose
    ...(formData.has("sales_rep_id") ? { sales_rep_id: String(formData.get("sales_rep_id") || "") || null } : {}),
  })
    .select("id")
    .single();

  if (error || !created) return { error: translateDbError(error, "customers") };

  // opening balance lives in its own protected table (0032); the database decides who may write it
  const opening = Number(formData.get("opening_balance") || 0);
  if (created && formData.has("opening_balance") && opening !== 0) {
    const ob = await setOpeningBalance(supabase, "customer", created.id, opening);
    if (ob.error) return { error: `أُضيف العميل لكن تعذّر حفظ الرصيد الافتتاحي: ${ob.error}` };
  }

  revalidatePath("/dashboard/customers");
  return { error: null };
}

export async function updateCustomer(id: string, formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: AUTH_ERROR };

  const name = String(formData.get("name") || "").trim();
  if (!name) return { error: NAME_REQUIRED };

  const { error } = await supabase
    .from("customers")
    .update({
      name,
      phone: String(formData.get("phone") || "") || null,
      customer_type: String(formData.get("customer_type") || "") || null,
      price_tier: String(formData.get("price_tier") || "") || "retail",
      ...(formData.has("sales_rep_id") ? { sales_rep_id: String(formData.get("sales_rep_id") || "") || null } : {}),
    })
    .eq("id", id);
  if (error) return { error: translateDbError(error, "customers") };

  if (formData.has("opening_balance")) {
    const ob = await setOpeningBalance(supabase, "customer", id, Number(formData.get("opening_balance") || 0));
    if (ob.error) return { error: ob.error };
  }

  revalidatePath("/dashboard/customers");
  return { error: null };
}

export async function deleteCustomer(id: string) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("customers").delete().eq("id", id);
  if (error) return { error: translateDbError(error, "customers") };

  revalidatePath("/dashboard/customers");
  return { error: null };
}

export async function recordCustomerCollection(input: {
  customer_id: string;
  amount: number;
  collection_date: string;
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

  if (!input.customer_id || !(input.amount > 0)) return { error: "أدخل مبلغًا صحيحًا" };

  const { error } = await supabase.rpc("record_customer_collection", {
    org_id: membership.organization_id,
    p_customer_id: input.customer_id,
    p_sales_invoice_id: null,
    p_amount: input.amount,
    p_collection_date: input.collection_date || new Date().toISOString().slice(0, 10),
    p_payment_method: input.payment_method,
    p_reference: input.reference,
    p_notes: input.notes,
  });

  if (error) return { error: error.message };

  revalidatePath("/dashboard/customers");
  revalidatePath("/dashboard/sales");
  return { error: null };
}

export type CustomerImportRow = { name: string; phone: string; customer_type: string; price_tier: string; opening_balance: number };

const TIER_ALIASES: Record<string, string> = {
  retail: "retail", "تجزئة": "retail",
  wholesale: "wholesale", "جملة": "wholesale",
  distributor: "distributor", "موزع": "distributor",
};

// §56: customers + opening balances in one pass. Rows with a name already
// in the org are skipped (not merged) so re-importing a file can't
// double-count an opening balance.
export async function importCustomersCsv(rows: CustomerImportRow[]) {
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
  const denied = await ownerOnly(supabase, orgId);
  if (denied) return { created: 0, skipped: [], error: denied };

  if (rows.length > 2000) return { created: 0, skipped: [], error: "الحد الأقصى 2000 صف في الملف الواحد" };

  // Opening balances are balances: only finance roles may WRITE them (enforced by the database too).
  const canSetBalance = await canEditOpeningBalance(supabase, orgId);

  const { data: existing } = await supabase.from("customers").select("name").eq("organization_id", orgId);
  const existingNames = new Set((existing ?? []).map((c) => c.name.trim()));

  let created = 0;
  const skipped: { row: number; reason: string }[] = [];

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const name = row.name.trim();
    if (!name) {
      skipped.push({ row: i + 1, reason: "اسم العميل مطلوب" });
      continue;
    }
    if (existingNames.has(name)) {
      skipped.push({ row: i + 1, reason: `عميل بهذا الاسم موجود بالفعل: ${name}` });
      continue;
    }
    if (!Number.isFinite(row.opening_balance)) {
      skipped.push({ row: i + 1, reason: "الرصيد الافتتاحي غير صحيح" });
      continue;
    }

    const { data: inserted, error } = await supabase
      .from("customers")
      .insert({
        organization_id: orgId,
        name,
        phone: row.phone.trim() || null,
        customer_type: row.customer_type.trim() || null,
        price_tier: TIER_ALIASES[row.price_tier.trim().toLowerCase()] ?? "retail",
      })
      .select("id")
      .single();
    if (error || !inserted) {
      skipped.push({ row: i + 1, reason: error?.message ?? "تعذر الإنشاء" });
      continue;
    }
    if (canSetBalance && row.opening_balance !== 0) {
      const ob = await setOpeningBalance(supabase, "customer", inserted.id, row.opening_balance);
      if (ob.error) skipped.push({ row: i + 1, reason: `تم إنشاء العميل لكن تعذر حفظ الرصيد الافتتاحي: ${ob.error}` });
    }
    existingNames.add(name);
    created++;
  }

  revalidatePath("/dashboard/customers");
  return { created, skipped, error: null };
}
