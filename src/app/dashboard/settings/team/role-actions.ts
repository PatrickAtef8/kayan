"use server";

import { revalidatePath } from "next/cache";
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

export async function createCustomRole(name: string, permissionKeys: string[]) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.rpc("create_custom_role", {
    org_id: membership.organization_id,
    p_name: name.trim(),
    p_permission_keys: permissionKeys,
  });
  if (error) return { error: error.message };

  revalidatePath("/dashboard/settings/team");
  return { error: null };
}

export async function updateCustomRole(roleId: string, name: string, permissionKeys: string[]) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.rpc("update_custom_role", {
    org_id: membership.organization_id,
    p_role_id: roleId,
    p_name: name.trim(),
    p_permission_keys: permissionKeys,
  });
  if (error) return { error: error.message };

  revalidatePath("/dashboard/settings/team");
  return { error: null };
}

export async function deleteCustomRole(roleId: string) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.rpc("delete_custom_role", {
    org_id: membership.organization_id,
    p_role_id: roleId,
  });
  if (error) return { error: error.message };

  revalidatePath("/dashboard/settings/team");
  return { error: null };
}
