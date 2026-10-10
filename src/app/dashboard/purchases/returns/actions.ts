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

// Invoice picker for the "new return" control: top matches only, fetched on
// demand. Searches the invoice number and the supplier name. RLS still
// applies; the org filter just lets Postgres use the (organization_id, created_at) index.
export async function searchPurchaseInvoices(query: string): Promise<{ value: string; label: string }[]> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return [];
  const orgId = membership.organization_id as string;
  // strip characters that have meaning inside a PostgREST filter expression
  const q = query.replace(/[%,()*\\]/g, " ").trim().slice(0, 60);

  let request = supabase
    .from("purchase_invoices")
    .select("id, invoice_number, invoice_date, suppliers(name)")
    .eq("organization_id", orgId)
    .order("created_at", { ascending: false })
    .limit(30);

  if (q) {
    const { data: parties } = await supabase.from("suppliers").select("id").eq("organization_id", orgId).ilike("name", `%${q}%`).limit(50);
    const ids = (parties ?? []).map((p) => p.id);
    request = request.or(ids.length > 0 ? `invoice_number.ilike.%${q}%,supplier_id.in.(${ids.join(",")})` : `invoice_number.ilike.%${q}%`);
  }

  const { data } = await request;
  return (data ?? []).map((inv) => ({
    value: inv.id,
    label: `${inv.invoice_number ?? inv.invoice_date} — ${(inv.suppliers as unknown as { name: string } | null)?.name ?? "—"}`,
  }));
}

export type ReturnablePurchaseItem = {
  purchase_invoice_item_id: string;
  product_id: string;
  product_name: string;
  quantity: number;
  already_returned: number;
  bonus_quantity: number;
  is_bonus: boolean;
  returnable: number;
  on_hand: number;
  unit_cost: number;
  line_total: number;
  tax_alloc: number; // this line's share of the invoice tax (reversed with the goods)
  tax_returned: number; // part of that share already reversed by earlier returns
};

export async function getReturnablePurchaseItems(purchaseInvoiceId: string): Promise<{ items: ReturnablePurchaseItem[]; error: string | null }> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { items: [], error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { data, error } = await supabase.rpc("get_returnable_purchase_items", {
    org_id: membership.organization_id,
    p_purchase_invoice_id: purchaseInvoiceId,
  });

  if (error) return { items: [], error: error.message };
  return { items: (data as ReturnablePurchaseItem[]) ?? [], error: null };
}

export type PurchaseReturnLineInput = { purchase_invoice_item_id: string; quantity: number };

export async function createPurchaseReturn(input: {
  purchase_invoice_id: string;
  return_date: string;
  items: PurchaseReturnLineInput[];
  cash_refund: number;
  notes: string;
}) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const items = input.items.filter((item) => item.purchase_invoice_item_id && item.quantity > 0);
  if (items.length === 0) return { error: "اختر صنفًا واحدًا على الأقل بكمية صحيحة" };

  const { error } = await supabase.rpc("create_purchase_return", {
    org_id: membership.organization_id,
    p_purchase_invoice_id: input.purchase_invoice_id,
    p_return_date: input.return_date || new Date().toISOString().slice(0, 10),
    items,
    p_cash_refund: input.cash_refund || 0,
    p_notes: input.notes || null,
  });

  if (error) return { error: error.message };

  revalidatePath("/dashboard/purchases");
  revalidatePath("/dashboard/purchases/returns");
  revalidatePath("/dashboard/suppliers");
  revalidatePath("/dashboard/inventory");
  revalidatePath("/dashboard/treasury");
  revalidatePath("/dashboard/reports/inventory");
  revalidatePath("/dashboard/reports/suppliers");
  revalidatePath("/dashboard");
  return { error: null };
}
