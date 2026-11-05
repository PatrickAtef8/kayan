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

  return membership;
}

export type PurchaseItemInput = {
  product_id: string;
  quantity: number;
  unit_cost: number;
  discount_pct: number; // percentage of the line
  expiry_date?: string; // optional, YYYY-MM-DD — tracked per inventory batch
};

export async function createPurchaseInvoice(input: {
  supplier_id: string;
  warehouse_id: string;
  invoice_number: string;
  invoice_date: string;
  due_date?: string; // optional; empty = from the supplier's default payment terms
  items: PurchaseItemInput[];
  discount_pct: number; // % off the invoice
  cash_discount_pct: number; // % off when something is paid now
  bonus_items: { product_id: string; quantity: number }[]; // entered by hand
  tax_total: number;
  amount_paid: number;
  payment_method: string;
  notes: string;
  shortage_report_id?: string; // set when the invoice is created from a stock-shortage report
  confirm_additional?: boolean; // the owner confirmed he needs ANOTHER purchase although purchases already on their way cover the shortage
}): Promise<{ error: string | null; warning?: string; linkedShortage?: boolean }> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  if (!input.supplier_id || !input.warehouse_id) return { error: "اختر المورد والمخزن" };
  // empty expiry fields are dropped so the batch is simply recorded without a date
  const items = input.items
    .filter((item) => item.product_id && item.quantity > 0)
    .map(({ expiry_date, ...item }) => (expiry_date ? { ...item, expiry_date } : item));
  if (items.length === 0) return { error: "أضف صنفًا واحدًا على الأقل بكمية صحيحة" };

  // Created from a shortage report: look BEFORE saving. If purchases already on their way cover the shortage, a second one
  // is almost certainly a duplicate click or a forgotten order — it is saved only after an explicit confirmation.
  // (A purchase that does not yet cover the need, e.g. after a partial receipt, never asks.)
  if (input.shortage_report_id && !input.confirm_additional) {
    const { data: check, error: checkError } = await supabase.rpc("shortage_purchase_precheck", { org_id: membership.organization_id, p_report_id: input.shortage_report_id });
    if (checkError) return { error: safeErrorMessage(checkError) };
    const c = check as { covered?: boolean; incoming?: number; available?: number; needed?: number } | null;
    if (c?.covered) {
      return { error: `يوجد بالفعل فاتورة شراء قائمة لهذا البلاغ (الكمية في الطريق: ${c.incoming}) تغطي العجز — المتاح ${c.available} + في الطريق ${c.incoming} من المطلوب ${c.needed}. لم تُحفظ فاتورة جديدة. لو تحتاج فاتورة إضافية فعلًا فعّل خانة التأكيد ثم احفظ.` };
    }
  }

  const common = {
    org_id: membership.organization_id,
    p_supplier_id: input.supplier_id,
    p_warehouse_id: input.warehouse_id,
    p_invoice_number: input.invoice_number,
    p_invoice_date: input.invoice_date || cairoDate(),
    items,
    p_discount_pct: input.discount_pct || 0,
    p_tax_total: input.tax_total || 0,
    p_amount_paid: input.amount_paid || 0,
    p_payment_method: input.payment_method,
    p_notes: input.notes,
    p_cash_discount_pct: input.cash_discount_pct || 0,
    p_bonus_items: input.bonus_items.filter((b) => b.product_id && b.quantity > 0),
    p_due_date: input.due_date || null,
  };

  // Created from a shortage report: saving the invoice and tying it to the report is ONE database transaction.
  // If the link is refused, the invoice is rolled back too — there is never an invoice saved without its report.
  const warning: string | undefined = undefined;
  let linkedShortage = false;
  if (input.shortage_report_id) {
    const { error } = await supabase.rpc("create_purchase_invoice_for_shortage", {
      ...common,
      p_report_id: input.shortage_report_id,
      p_additional: !!input.confirm_additional,
    });
    if (error) return { error: `لم تُحفظ فاتورة الشراء: ${error.message}` };
    linkedShortage = true;
  } else {
    const { error } = await supabase.rpc("create_purchase_invoice", common);
    if (error) return { error: safeErrorMessage(error) };
  }

  revalidatePath("/dashboard/purchases");
  revalidatePath("/dashboard/suppliers");
  revalidatePath("/dashboard/inventory");
  revalidatePath("/dashboard/products");
  revalidatePath("/dashboard/shortages");
  revalidatePath("/dashboard");
  return { error: null, warning, linkedShortage };
}

// Records one more payment against ONE purchase invoice. Each call adds its own row
// (amount + date) to supplier_payments and its own treasury movement — earlier payments are
// never edited or replaced. The database re-checks permission, that the invoice belongs to
// the supplier and that the amount does not exceed what is still owed, and flips the invoice
// to partial / paid; this action only shapes the input and the error message.
export async function recordPurchaseInvoicePayment(input: {
  purchase_invoice_id: string;
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

  // the supplier is read from the invoice itself, never trusted from the browser
  const { data: invoice } = await supabase
    .from("purchase_invoices")
    .select("supplier_id, invoice_date")
    .eq("id", input.purchase_invoice_id)
    .eq("organization_id", membership.organization_id)
    .maybeSingle();
  if (!invoice) return { error: "الفاتورة غير موجودة" };
  if (input.payment_date < invoice.invoice_date) return { error: "تاريخ الدفعة لا يمكن أن يسبق تاريخ الفاتورة" };

  const { error } = await supabase.rpc("record_supplier_payment", {
    org_id: membership.organization_id,
    p_supplier_id: invoice.supplier_id,
    p_purchase_invoice_id: input.purchase_invoice_id,
    p_amount: amount,
    p_payment_date: input.payment_date,
    p_payment_method: input.payment_method,
    p_reference: "",
    p_notes: input.notes,
  });
  if (error) return { error: safeErrorMessage(error) };

  revalidatePath("/dashboard/purchases");
  revalidatePath("/dashboard/suppliers");
  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard/reports", "layout");
  revalidatePath("/dashboard");
  return { error: null };
}
