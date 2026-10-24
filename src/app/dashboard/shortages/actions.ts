"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

async function getOrg(supabase: Awaited<ReturnType<typeof createClient>>) {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const { data } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  return data?.organization_id ?? null;
}

export type SellableRow = { tracked: boolean; available: number | null };

// What can be sold right now from one warehouse (on hand − reserved by undispatched invoices − expired).
// One number per product; the database function refuses anyone who may not invoice and never returns cost.
export async function getSellableStock(warehouseId: string): Promise<{ error: string | null; stock: Record<string, SellableRow> }> {
  const supabase = await createClient();
  const orgId = await getOrg(supabase);
  if (!orgId) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا", stock: {} };
  if (!warehouseId) return { error: null, stock: {} };
  const { data, error } = await supabase.rpc("get_sellable_stock", { org_id: orgId, p_warehouse_id: warehouseId });
  if (error) return { error: error.message, stock: {} };
  const stock: Record<string, SellableRow> = {};
  for (const r of (data ?? []) as { product_id: string; tracked: boolean; available: number | string | null }[]) {
    stock[r.product_id] = { tracked: r.tracked, available: r.available == null ? null : Number(r.available) };
  }
  return { error: null, stock };
}

export type ShortageResult = { error: string | null; duplicate?: boolean; created?: boolean; status?: string };

// The available quantity is measured by the database at this moment — only the needed quantity comes from the browser.
export async function reportStockShortage(input: { productId: string; warehouseId: string; neededQty: number; note?: string }): Promise<ShortageResult> {
  const supabase = await createClient();
  const orgId = await getOrg(supabase);
  if (!orgId) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  const needed = Math.round(Number(input.neededQty) * 1000) / 1000;
  if (!Number.isFinite(needed) || needed <= 0) return { error: "أدخل الكمية المطلوبة" };
  const { data, error } = await supabase.rpc("report_stock_shortage", {
    org_id: orgId,
    p_product_id: input.productId,
    p_warehouse_id: input.warehouseId,
    p_needed_qty: needed,
    p_note: input.note?.trim() || null,
  });
  if (error) return { error: error.message };
  revalidatePath("/dashboard/shortages");
  revalidatePath("/dashboard");
  const r = data as { created: boolean; duplicate: boolean; status: string };
  return { error: null, created: r.created, duplicate: r.duplicate, status: r.status };
}

export async function setShortageStatus(input: { reportId: string; status: "new" | "in_progress" | "resolved"; note?: string }) {
  const supabase = await createClient();
  const orgId = await getOrg(supabase);
  if (!orgId) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  const { error } = await supabase.rpc("set_stock_shortage_status", {
    org_id: orgId,
    p_report_id: input.reportId,
    p_status: input.status,
    p_owner_note: input.note?.trim() || null,
  });
  if (error) return { error: error.message };
  revalidatePath("/dashboard/shortages");
  revalidatePath("/dashboard");
  return { error: null };
}
