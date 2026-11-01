"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { safeErrorMessage } from "@/lib/db-errors";

async function getOrg() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { supabase, orgId: null as string | null };
  const { data } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).eq("status", "active").order("created_at", { ascending: true }).limit(1).maybeSingle();
  return { supabase, orgId: (data?.organization_id as string | undefined) ?? null };
}

const done = () => revalidatePath("/dashboard/settings/discounts");

export async function addTier(input: { applies_to: "sales" | "purchases"; min_amount: number; discount_pct: number }) {
  const { supabase, orgId } = await getOrg();
  if (!orgId) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  if (!(input.min_amount > 0) || !(input.discount_pct > 0)) return { error: "أدخل حدًا أدنى ونسبة خصم أكبر من صفر" };
  if (input.discount_pct > 100) return { error: "نسبة الخصم لا يمكن أن تزيد عن 100%" };
  const { error } = await supabase.from("discount_tiers").insert({ ...input, organization_id: orgId });
  if (error) return { error: error.code === "23505" ? "توجد شريحة بنفس الحد الأدنى بالفعل" : error.message };
  done();
  return { error: null };
}

export async function deleteTier(id: string) {
  const { supabase, orgId } = await getOrg();
  if (!orgId) return { error: "غير مصرح" };
  const { error } = await supabase.from("discount_tiers").delete().eq("id", id).eq("organization_id", orgId);
  if (error) return { error: safeErrorMessage(error) };
  done();
  return { error: null };
}

export async function toggleTier(id: string, isActive: boolean) {
  const { supabase, orgId } = await getOrg();
  if (!orgId) return { error: "غير مصرح" };
  const { error } = await supabase.from("discount_tiers").update({ is_active: isActive }).eq("id", id).eq("organization_id", orgId);
  if (error) return { error: safeErrorMessage(error) };
  done();
  return { error: null };
}
