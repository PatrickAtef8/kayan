"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";
import { AUTH_ERROR, NAME_REQUIRED } from "@/lib/action-result";

export async function createWarehouse(formData: FormData) {
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

  const { error } = await supabase.from("warehouses").insert({
    organization_id: membership.organization_id,
    name,
    location: String(formData.get("location") || "") || null,
  });
  if (error) return { error: translateDbError(error, "warehouses") };

  revalidatePath("/dashboard/warehouses");
  return { error: null };
}

export async function updateWarehouse(id: string, formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: AUTH_ERROR };

  const name = String(formData.get("name") || "").trim();
  if (!name) return { error: NAME_REQUIRED };

  const { error } = await supabase
    .from("warehouses")
    .update({ name, location: String(formData.get("location") || "") || null })
    .eq("id", id);
  if (error) return { error: translateDbError(error, "warehouses") };

  revalidatePath("/dashboard/warehouses");
  return { error: null };
}

export async function deleteWarehouse(id: string) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("warehouses").delete().eq("id", id);
  if (error) return { error: translateDbError(error, "warehouses") };

  revalidatePath("/dashboard/warehouses");
  return { error: null };
}
