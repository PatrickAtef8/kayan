"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";
import { AUTH_ERROR, NAME_REQUIRED } from "@/lib/action-result";

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

export async function addOtherBalance(formData: FormData) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: AUTH_ERROR };

  const kind = String(formData.get("kind") || "asset");
  const name = String(formData.get("name") || "").trim();
  const amount = Number(formData.get("amount") || 0);
  const notes = String(formData.get("notes") || "").trim() || null;
  if (!name || !(amount > 0)) return { error: "أدخل الاسم ومبلغًا أكبر من صفر" };

  const { error } = await supabase.rpc("add_other_balance", {
    org_id: membership.organization_id,
    p_kind: kind,
    p_name: name,
    p_amount: amount,
    p_notes: notes,
  });
  if (error) return { error: translateDbError(error) };

  revalidatePath("/dashboard/reports/position");
  return { error: null };
}

export async function deactivateOtherBalance(id: string) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return;

  await supabase.rpc("deactivate_other_balance", { org_id: membership.organization_id, p_id: id });
  revalidatePath("/dashboard/reports/position");
}
