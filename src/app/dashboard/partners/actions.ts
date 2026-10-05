"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";

async function getMembership(supabase: ReturnType<typeof createClient>) {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  return membership;
}

export async function createPartner(formData: FormData) {
  const supabase = createClient();
  const membership = await getMembership(supabase);
  if (!membership) return;

  const name = String(formData.get("name") || "").trim();
  if (!name) return;
  const phone = String(formData.get("phone") || "").trim() || null;

  await supabase.from("partners").insert({ organization_id: membership.organization_id, name, phone });
  revalidatePath("/dashboard/partners");
}

export async function updatePartner(id: string, formData: FormData) {
  const supabase = createClient();
  const membership = await getMembership(supabase);
  if (!membership) return;

  const name = String(formData.get("name") || "").trim();
  if (!name) return;
  const phone = String(formData.get("phone") || "").trim() || null;

  await supabase.from("partners").update({ name, phone }).eq("id", id);
  revalidatePath("/dashboard/partners");
}

export async function deletePartner(id: string) {
  const supabase = createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("partners").delete().eq("id", id);
  if (error) return { error: translateDbError(error, "partners") };

  revalidatePath("/dashboard/partners");
  return { error: null };
}

export async function recordPartnerWithdrawal(input: {
  partner_id: string;
  amount: number;
  withdrawal_date: string;
  description: string;
  notes: string;
}) {
  const supabase = createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  if (!input.partner_id || !(input.amount > 0)) return { error: "اختر الشريك وأدخل مبلغًا صحيحًا" };

  const { error } = await supabase.rpc("record_partner_withdrawal", {
    org_id: membership.organization_id,
    p_partner_id: input.partner_id,
    p_treasury_account_id: null,
    p_amount: input.amount,
    p_withdrawal_date: input.withdrawal_date || new Date().toISOString().slice(0, 10),
    p_description: input.description,
    p_notes: input.notes,
  });

  if (error) return { error: error.message };

  revalidatePath("/dashboard/partners");
  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard");
  return { error: null };
}
