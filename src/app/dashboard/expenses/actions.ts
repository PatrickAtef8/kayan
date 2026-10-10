"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
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

  return membership ? { ...membership, userId: user!.id } : null;
}

export async function createExpense(formData: FormData) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return;

  const amount = Number(formData.get("amount") || 0);
  if (!(amount > 0)) return;

  let categoryId = String(formData.get("category_id") || "") || null;
  const newCategory = String(formData.get("new_category") || "").trim();

  if (newCategory) {
    const { data: category } = await supabase
      .from("expense_categories")
      .insert({ organization_id: membership.organization_id, name: newCategory })
      .select("id")
      .single();
    categoryId = category?.id ?? null;
  }

  const expenseDate = String(formData.get("expense_date") || "") || new Date().toISOString().slice(0, 10);
  const paymentMethod = String(formData.get("payment_method") || "").trim() || null;
  const description = String(formData.get("description") || "").trim() || null;

  const expenseType = String(formData.get("expense_type") || "operating");
  const repId = String(formData.get("sales_rep_id") || "") || null;

  const { error } = await supabase.rpc("create_expense", {
    org_id: membership.organization_id,
    p_category_id: categoryId,
    p_treasury_account_id: null,
    p_amount: amount,
    p_expense_date: expenseDate,
    p_payment_method: paymentMethod,
    p_description: description,
    p_responsible_user: membership.userId,
    p_expense_type: expenseType,
    p_sales_rep_id: repId,
  });
  if (error) redirect(`/dashboard/expenses?error=${encodeURIComponent(error.message)}`);

  revalidatePath("/dashboard/expenses");
  revalidatePath("/dashboard/reports/reps");
  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard");
}
