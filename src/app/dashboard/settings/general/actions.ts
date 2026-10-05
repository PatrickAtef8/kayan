"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export async function updateOrgName(formData: FormData) {
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

  await supabase.from("organizations").update({ name }).eq("id", membership.organization_id);

  revalidatePath("/dashboard/settings/general");
  revalidatePath("/dashboard");
}
