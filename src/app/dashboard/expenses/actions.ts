"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { safeErrorMessage } from "@/lib/db-errors";
import { cairoDate } from "@/lib/report-period";

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

export type ExpenseInput = {
  expense_type: string;
  sales_rep_id: string;
  category_id: string; // an existing category …
  new_category: string; // … or a new one (wins when filled in)
  amount: number;
  expense_date: string;
  payment_method: string;
  description: string;
};

const REP_TYPES = ["rep_expense", "salary", "commission_payout"];

export async function createExpense(input: ExpenseInput) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const amount = Math.round(Number(input.amount) * 100) / 100;
  if (!Number.isFinite(amount) || amount <= 0) return { error: "أدخل مبلغًا أكبر من صفر" };

  const expenseType = input.expense_type || "operating";
  const repId = REP_TYPES.includes(expenseType) ? input.sales_rep_id || null : null; // an operating expense never carries a rep
  if (REP_TYPES.includes(expenseType) && !repId) return { error: "اختر المندوب المعني بهذا المصروف" };

  // the category is only a label for the reports; reuse one with the same name instead of
  // failing on the unique (organization, name) rule and silently saving the expense without it
  let categoryId = input.category_id || null;
  const newCategory = input.new_category.trim();
  if (newCategory) {
    const { data: existing } = await supabase
      .from("expense_categories")
      .select("id")
      .eq("organization_id", membership.organization_id)
      .ilike("name", newCategory.replace(/[\%_]/g, "\$&"))
      .limit(1)
      .maybeSingle();
    if (existing) {
      categoryId = existing.id;
    } else {
      const { data: created, error: catError } = await supabase
        .from("expense_categories")
        .insert({ organization_id: membership.organization_id, name: newCategory })
        .select("id")
        .single();
      if (catError || !created) return { error: "تعذّر إنشاء التصنيف الجديد" };
      categoryId = created.id;
    }
  }

  const { error } = await supabase.rpc("create_expense", {
    org_id: membership.organization_id,
    p_category_id: categoryId,
    p_treasury_account_id: null,
    p_amount: amount,
    p_expense_date: input.expense_date || cairoDate(),
    p_payment_method: input.payment_method.trim() || null,
    p_description: input.description.trim() || null,
    p_responsible_user: membership.userId,
    p_expense_type: expenseType,
    p_sales_rep_id: repId,
  });
  if (error) return { error: safeErrorMessage(error) };

  revalidatePath("/dashboard/expenses");
  revalidatePath("/dashboard/reports", "layout");
  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard");
  return { error: null };
}

// Deletes an expense for good: the database function removes its treasury movement and attachment records in the same transaction and writes
// «expense.deleted» to the audit trail, so the treasury balance, the reports, the dashboard and rep balances all move back by themselves.
export async function deleteExpense(id: string) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.rpc("delete_expense", { org_id: membership.organization_id, p_expense_id: id });
  if (error) return { error: safeErrorMessage(error) };

  revalidatePath("/dashboard/expenses");
  revalidatePath("/dashboard/reports", "layout");
  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard/representatives");
  revalidatePath("/dashboard/settings/audit");
  revalidatePath("/dashboard");
  return { error: null };
}
