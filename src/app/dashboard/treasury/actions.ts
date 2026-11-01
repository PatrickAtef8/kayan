"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { safeErrorMessage } from "@/lib/db-errors";

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

export async function recordTreasuryMovement(input: {
  direction: "in" | "out";
  amount: number;
  movement_date: string;
  description: string;
}) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  if (!(input.amount > 0)) return { error: "أدخل مبلغًا صحيحًا" };

  const { error } = await supabase.rpc("record_treasury_movement", {
    org_id: membership.organization_id,
    p_treasury_account_id: null,
    p_direction: input.direction,
    p_amount: input.amount,
    p_movement_date: input.movement_date || new Date().toISOString().slice(0, 10),
    p_description: input.description,
  });

  if (error) return { error: safeErrorMessage(error) };

  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard");
  return { error: null };
}

export async function setTreasuryOpeningBalance(amount: number) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  if (!Number.isFinite(amount) || amount < 0) return { error: "أدخل مبلغًا صحيحًا (صفر أو أكثر)" };

  const { error } = await supabase.rpc("set_treasury_opening_balance", { org_id: membership.organization_id, p_amount: amount });
  if (error) return { error: safeErrorMessage(error) };

  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard");
  return { error: null };
}
