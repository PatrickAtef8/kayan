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

export type SalesItemInput = {
  product_id: string;
  quantity: number;
  unit_price: number;
  discount_pct: number; // percentage of the line
};

export async function createSalesInvoice(input: {
  customer_id: string;
  warehouse_id: string;
  sales_rep_id: string;
  sales_channel?: string; // wholesale | retail | social — empty = derived from the customer's price tier by the database
  invoice_number: string;
  invoice_date: string;
  items: SalesItemInput[];
  discount_pct: number; // % off the invoice
  cash_discount_pct: number; // % off when something is paid now
  bonus_items: { product_id: string; quantity: number }[]; // entered by hand
  tax_total: number;
  amount_collected: number;
  payment_method: string;
  notes: string;
}) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  if (!input.customer_id || !input.warehouse_id) return { error: "اختر العميل والمخزن" };
  const items = input.items.filter((item) => item.product_id && item.quantity > 0);
  if (items.length === 0) return { error: "أضف صنفًا واحدًا على الأقل بكمية صحيحة" };

  const { error } = await supabase.rpc("create_sales_invoice", {
    org_id: membership.organization_id,
    p_customer_id: input.customer_id,
    p_warehouse_id: input.warehouse_id,
    p_invoice_number: input.invoice_number,
    p_invoice_date: input.invoice_date || new Date().toISOString().slice(0, 10),
    items,
    p_discount_pct: input.discount_pct || 0,
    p_tax_total: input.tax_total || 0,
    p_amount_collected: input.amount_collected || 0,
    p_payment_method: input.payment_method,
    p_notes: input.notes,
    p_sales_rep_id: input.sales_rep_id || null,
    p_sales_channel: input.sales_channel || null,
    p_cash_discount_pct: input.cash_discount_pct || 0,
    p_bonus_items: input.bonus_items.filter((b) => b.product_id && b.quantity > 0),
  });

  if (error) return { error: error.message };

  revalidatePath("/dashboard/sales");
  revalidatePath("/dashboard/customers");
  revalidatePath("/dashboard/inventory");
  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard");
  return { error: null };
}

// Records one more payment against ONE invoice. Each call adds its own row (amount + date)
// to customer_collections and its own treasury movement — earlier payments are never edited
// or replaced. The database re-checks everything (permission, that the invoice belongs to
// the customer, and that the amount does not exceed what is still owed) and flips the
// invoice to partial / paid; this action only shapes the input and the error message.
export async function recordInvoicePayment(input: {
  sales_invoice_id: string;
  amount: number;
  payment_date: string;
  payment_method: string;
  notes: string;
}) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const amount = Math.round(Number(input.amount) * 100) / 100;
  if (!Number.isFinite(amount) || amount <= 0) return { error: "أدخل مبلغًا صحيحًا أكبر من صفر" };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(input.payment_date || "")) return { error: "أدخل تاريخ دفع صحيحًا" };

  // the customer is read from the invoice itself, never trusted from the browser
  const { data: invoice } = await supabase
    .from("sales_invoices")
    .select("customer_id, invoice_date")
    .eq("id", input.sales_invoice_id)
    .eq("organization_id", membership.organization_id)
    .maybeSingle();
  if (!invoice) return { error: "الفاتورة غير موجودة" };
  if (input.payment_date < invoice.invoice_date) return { error: "تاريخ الدفعة لا يمكن أن يسبق تاريخ الفاتورة" };

  const { error } = await supabase.rpc("record_customer_collection", {
    org_id: membership.organization_id,
    p_customer_id: invoice.customer_id,
    p_sales_invoice_id: input.sales_invoice_id,
    p_amount: amount,
    p_collection_date: input.payment_date,
    p_payment_method: input.payment_method,
    p_reference: "",
    p_notes: input.notes,
  });
  if (error) return { error: error.message };

  revalidatePath("/dashboard/sales");
  revalidatePath("/dashboard/customers");
  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard/reports", "layout");
  revalidatePath("/dashboard");
  return { error: null };
}
