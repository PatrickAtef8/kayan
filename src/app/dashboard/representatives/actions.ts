"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";

async function getMembership(supabase: Awaited<ReturnType<typeof createClient>>) {
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

function readFields(formData: FormData) {
  const name = String(formData.get("name") || "").trim();
  const phone = String(formData.get("phone") || "").trim() || null;
  const fixedSalary = Number(formData.get("fixed_salary") || 0);
  const transportationAllowance = Number(formData.get("transportation_allowance") || 0);
  const commissionBasis = String(formData.get("commission_basis") || "net_sales");
  const commissionRate = Number(formData.get("commission_rate") || 0);
  const monthlyTarget = Number(formData.get("monthly_target") || 0);
  const minTarget = Number(formData.get("min_target_for_commission") || 0);
  const userId = String(formData.get("user_id") || "") || null;
  return { name, phone, fixedSalary, transportationAllowance, commissionBasis, commissionRate, monthlyTarget, minTarget, userId };
}

export async function createRepresentative(formData: FormData) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return;

  const fields = readFields(formData);
  if (!fields.name) return;

  await supabase.from("sales_representatives").insert({
    organization_id: membership.organization_id,
    name: fields.name,
    phone: fields.phone,
    fixed_salary: fields.fixedSalary,
    transportation_allowance: fields.transportationAllowance,
    commission_basis: fields.commissionBasis,
    commission_rate: fields.commissionRate,
    monthly_target: fields.monthlyTarget,
    min_target_for_commission: fields.minTarget,
    user_id: fields.userId,
  });

  revalidatePath("/dashboard/representatives");
}

export async function updateRepresentative(id: string, formData: FormData) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return;

  const fields = readFields(formData);
  if (!fields.name) return;

  await supabase
    .from("sales_representatives")
    .update({
      name: fields.name,
      phone: fields.phone,
      fixed_salary: fields.fixedSalary,
      transportation_allowance: fields.transportationAllowance,
      commission_basis: fields.commissionBasis,
      commission_rate: fields.commissionRate,
      monthly_target: fields.monthlyTarget,
      min_target_for_commission: fields.minTarget,
      user_id: fields.userId,
    })
    .eq("id", id);

  revalidatePath("/dashboard/representatives");
}

export async function toggleRepresentativeActive(id: string, isActive: boolean) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return;

  await supabase.from("sales_representatives").update({ is_active: isActive }).eq("id", id);
  revalidatePath("/dashboard/representatives");
  revalidatePath("/dashboard/sales");
}

export async function deleteRepresentative(id: string) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("sales_representatives").delete().eq("id", id);
  if (error) return { error: translateDbError(error, "sales_representatives") };

  revalidatePath("/dashboard/representatives");
  return { error: null };
}
