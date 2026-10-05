"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";

export async function createWarehouse(formData: FormData) {
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

  await supabase.from("warehouses").insert({
    organization_id: membership.organization_id,
    name,
    location: String(formData.get("location") || "") || null,
  });

  revalidatePath("/dashboard/warehouses");
}

export async function updateWarehouse(id: string, formData: FormData) {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return;

  const name = String(formData.get("name") || "").trim();
  if (!name) return;

  await supabase
    .from("warehouses")
    .update({ name, location: String(formData.get("location") || "") || null })
    .eq("id", id);

  revalidatePath("/dashboard/warehouses");
}

export async function deleteWarehouse(id: string) {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("warehouses").delete().eq("id", id);
  if (error) return { error: translateDbError(error, "warehouses") };

  revalidatePath("/dashboard/warehouses");
  return { error: null };
}
