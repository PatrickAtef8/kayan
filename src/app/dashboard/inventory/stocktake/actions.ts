"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

// Every rule (permissions, staleness, batch-specific adjustments, costing, audit) lives in the
// database functions (0039). These actions only forward the call and surface the Arabic message.

async function context() {
  const supabase = await createClient();
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
  if (!membership) return null;
  return { supabase, orgId: membership.organization_id as string };
}

const NOT_SIGNED_IN = { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

function refresh(id?: string) {
  revalidatePath("/dashboard/inventory/stocktake");
  if (id) revalidatePath(`/dashboard/inventory/stocktake/${id}`);
  revalidatePath("/dashboard/inventory");
  revalidatePath("/dashboard/reports/inventory");
  revalidatePath("/dashboard/reports/inventory/expiry");
}

export async function startStocktake(input: { warehouse_id: string; notes: string }) {
  const ctx = await context();
  if (!ctx) return { ...NOT_SIGNED_IN, id: null as string | null };
  if (!input.warehouse_id) return { error: "اختر المخزن", id: null };
  const { data, error } = await ctx.supabase.rpc("start_stocktake", {
    org_id: ctx.orgId,
    p_warehouse_id: input.warehouse_id,
    p_notes: input.notes || null,
  });
  if (error) return { error: error.message, id: null };
  refresh();
  return { error: null, id: data as string };
}

export async function saveStocktakeCounts(input: { stocktake_id: string; counts: { line_id: string; counted_qty: number | null }[] }) {
  const ctx = await context();
  if (!ctx) return NOT_SIGNED_IN;
  const { error } = await ctx.supabase.rpc("save_stocktake_counts", {
    org_id: ctx.orgId,
    p_stocktake_id: input.stocktake_id,
    p_counts: input.counts,
  });
  if (error) return { error: error.message };
  refresh(input.stocktake_id);
  return { error: null };
}

export async function addStocktakeFound(input: { stocktake_id: string; product_id: string; expiry_date: string; quantity: number }) {
  const ctx = await context();
  if (!ctx) return NOT_SIGNED_IN;
  if (!input.product_id) return { error: "اختر المنتج" };
  if (!(input.quantity > 0)) return { error: "أدخل كمية أكبر من صفر" };
  const { error } = await ctx.supabase.rpc("add_stocktake_found", {
    org_id: ctx.orgId,
    p_stocktake_id: input.stocktake_id,
    p_product_id: input.product_id,
    p_expiry: input.expiry_date || null,
    p_counted: input.quantity,
  });
  if (error) return { error: error.message };
  refresh(input.stocktake_id);
  return { error: null };
}

export async function removeStocktakeFound(input: { stocktake_id: string; line_id: string }) {
  const ctx = await context();
  if (!ctx) return NOT_SIGNED_IN;
  const { error } = await ctx.supabase.rpc("remove_stocktake_found", { org_id: ctx.orgId, p_line_id: input.line_id });
  if (error) return { error: error.message };
  refresh(input.stocktake_id);
  return { error: null };
}

export async function reconcileStocktake(stocktakeId: string) {
  const ctx = await context();
  if (!ctx) return NOT_SIGNED_IN;
  const { error } = await ctx.supabase.rpc("reconcile_stocktake", { org_id: ctx.orgId, p_stocktake_id: stocktakeId });
  if (error) return { error: error.message };
  refresh(stocktakeId);
  return { error: null };
}

export async function applyStocktake(stocktakeId: string) {
  const ctx = await context();
  if (!ctx) return { ...NOT_SIGNED_IN, applied: 0 };
  const { data, error } = await ctx.supabase.rpc("apply_stocktake", { org_id: ctx.orgId, p_stocktake_id: stocktakeId });
  if (error) return { error: error.message, applied: 0 };
  refresh(stocktakeId);
  return { error: null, applied: Number(data) };
}

export async function cancelStocktake(stocktakeId: string) {
  const ctx = await context();
  if (!ctx) return NOT_SIGNED_IN;
  const { error } = await ctx.supabase.rpc("cancel_stocktake", { org_id: ctx.orgId, p_stocktake_id: stocktakeId });
  if (error) return { error: error.message };
  refresh(stocktakeId);
  return { error: null };
}
