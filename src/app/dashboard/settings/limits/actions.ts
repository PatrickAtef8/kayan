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
  const { data } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  return { supabase, orgId: (data?.organization_id as string | undefined) ?? null };
}

const done = () => revalidatePath("/dashboard/settings/limits");

// unlimited = true  -> max_discount_pct stored as NULL (no cap)
// The database enforces manage_settings and the 0–100 range; this is only early feedback.
export async function saveRoleLimit(input: { roleId: string; unlimited: boolean; maxPct: number; canGiveBonus: boolean }) {
  const { supabase, orgId } = await getOrg();
  if (!orgId) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  if (!input.roleId) return { error: "الدور غير صحيح" };
  if (!input.unlimited && !(Number.isFinite(input.maxPct) && input.maxPct >= 0 && input.maxPct <= 100)) {
    return { error: "الحد الأقصى للخصم يجب أن يكون بين 0 و 100" };
  }
  const { error } = await supabase.from("role_sales_limits").upsert(
    {
      organization_id: orgId,
      role_id: input.roleId,
      max_discount_pct: input.unlimited ? null : input.maxPct,
      can_give_manual_bonus: !!input.canGiveBonus,
    },
    { onConflict: "organization_id,role_id" }
  );
  if (error) return { error: safeErrorMessage(error) };
  done();
  return { error: null };
}

// Back to the built-in default (Owner/Admin unlimited, everyone else 0% and no manual bonus).
export async function resetRoleLimit(roleId: string) {
  const { supabase, orgId } = await getOrg();
  if (!orgId) return { error: "غير مصرح" };
  const { error } = await supabase.from("role_sales_limits").delete().eq("organization_id", orgId).eq("role_id", roleId);
  if (error) return { error: safeErrorMessage(error) };
  done();
  return { error: null };
}
