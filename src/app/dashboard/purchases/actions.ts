"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

async function getMembership(supabase: ReturnType<typeof createClient>) {
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

export type PurchaseItemInput = {
  product_id: string;
  quantity: number;
  unit_cost: number;
  discount_pct: number; // percentage of the line
};

export async function createPurchaseInvoice(input: {
  supplier_id: string;
  warehouse_id: string;
  invoice_number: string;
  invoice_date: string;
  items: PurchaseItemInput[];
  discount_pct: number; // % off the invoice
  cash_discount_pct: number; // % off when something is paid now
  bonus_items: { product_id: string; quantity: number }[]; // entered by hand
  tax_total: number;
  amount_paid: number;
  payment_method: string;
  notes: string;
}) {
  const supabase = createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  if (!input.supplier_id || !input.warehouse_id) return { error: "اختر المورد والمخزن" };
  const items = input.items.filter((item) => item.product_id && item.quantity > 0);
  if (items.length === 0) return { error: "أضف صنفًا واحدًا على الأقل بكمية صحيحة" };

  const { error } = await supabase.rpc("create_purchase_invoice", {
    org_id: membership.organization_id,
    p_supplier_id: input.supplier_id,
    p_warehouse_id: input.warehouse_id,
    p_invoice_number: input.invoice_number,
    p_invoice_date: input.invoice_date || new Date().toISOString().slice(0, 10),
    items,
    p_discount_pct: input.discount_pct || 0,
    p_tax_total: input.tax_total || 0,
    p_amount_paid: input.amount_paid || 0,
    p_payment_method: input.payment_method,
    p_notes: input.notes,
    p_cash_discount_pct: input.cash_discount_pct || 0,
    p_bonus_items: input.bonus_items.filter((b) => b.product_id && b.quantity > 0),
  });

  if (error) return { error: error.message };

  revalidatePath("/dashboard/purchases");
  revalidatePath("/dashboard/suppliers");
  revalidatePath("/dashboard/inventory");
  revalidatePath("/dashboard/products");
  return { error: null };
}
