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

export async function adjustStock(input: { product_id: string; warehouse_id: string; quantity_delta: number; reason: string; expiry_date?: string }) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  if (!input.product_id || !input.warehouse_id) return { error: "اختر المنتج والمخزن" };
  if (!input.quantity_delta) return { error: "أدخل كمية التسوية (موجبة للزيادة، سالبة للنقص)" };
  if (!input.reason.trim()) return { error: "سبب التسوية مطلوب" };

  const { error } = await supabase.rpc("adjust_inventory_stock", {
    org_id: membership.organization_id,
    p_product_id: input.product_id,
    p_warehouse_id: input.warehouse_id,
    p_quantity_delta: input.quantity_delta,
    p_reason: input.reason,
    // an expiry date only applies to an increase (it creates a batch)
    p_expiry_date: input.quantity_delta > 0 && input.expiry_date ? input.expiry_date : null,
  });

  if (error) return { error: error.message };

  revalidatePath("/dashboard/inventory");
  revalidatePath("/dashboard/reports/inventory");
  return { error: null };
}

export type StockBatchInfo = { expiry_date: string | null; quantity: number };

// Read-only view of the batches behind one product's stock in one warehouse (earliest expiry
// first, undated last — the same order a decrease is deducted in). RLS applies as usual.
export async function getStockBatches(product_id: string, warehouse_id: string): Promise<{ batches: StockBatchInfo[]; error: string | null }> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { batches: [], error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  if (!product_id || !warehouse_id) return { batches: [], error: null };

  const { data, error } = await supabase
    .from("stock_batches")
    .select("expiry_date, quantity")
    .eq("organization_id", membership.organization_id)
    .eq("product_id", product_id)
    .eq("warehouse_id", warehouse_id)
    .order("expiry_date", { ascending: true, nullsFirst: false });
  if (error) return { batches: [], error: error.message };
  return { batches: (data ?? []).map((b) => ({ expiry_date: b.expiry_date as string | null, quantity: Number(b.quantity) })), error: null };
}

// Removes stock from ONE batch (expired, damaged, recalled …). It cannot exceed the batch's
// quantity and never touches any other batch — unlike a plain negative adjustment, which is FEFO.
export async function disposeBatch(input: { batch_id: string; quantity: number; reason: string }) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  if (!input.batch_id) return { error: "الدفعة غير محددة" };
  if (!(input.quantity > 0)) return { error: "أدخل كمية أكبر من صفر" };
  if (!input.reason.trim()) return { error: "سبب الإعدام مطلوب" };

  const { error } = await supabase.rpc("dispose_stock_batch", {
    org_id: membership.organization_id,
    p_batch_id: input.batch_id,
    p_quantity: input.quantity,
    p_reason: input.reason,
  });
  if (error) return { error: error.message };

  revalidatePath("/dashboard/inventory");
  revalidatePath("/dashboard/reports/inventory");
  revalidatePath("/dashboard/reports/inventory/expiry");
  return { error: null };
}

export type TransferLineInput = { product_id: string; quantity: number };

export async function createStockTransfer(input: {
  from_warehouse_id: string;
  to_warehouse_id: string;
  transfer_date: string;
  items: TransferLineInput[];
  notes: string;
}) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  if (!input.from_warehouse_id || !input.to_warehouse_id) return { error: "اختر مخزن المصدر والوجهة" };
  if (input.from_warehouse_id === input.to_warehouse_id) return { error: "لا يمكن النقل إلى نفس المخزن" };

  const items = input.items.filter((item) => item.product_id && item.quantity > 0);
  if (items.length === 0) return { error: "اختر صنفًا واحدًا على الأقل بكمية صحيحة" };

  const { error } = await supabase.rpc("create_stock_transfer", {
    org_id: membership.organization_id,
    p_from_warehouse_id: input.from_warehouse_id,
    p_to_warehouse_id: input.to_warehouse_id,
    p_transfer_date: input.transfer_date || new Date().toISOString().slice(0, 10),
    items,
    p_notes: input.notes || null,
  });

  if (error) return { error: error.message };

  revalidatePath("/dashboard/inventory");
  revalidatePath("/dashboard/reports/inventory");
  return { error: null };
}
