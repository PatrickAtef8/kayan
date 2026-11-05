"use server";

import { createClient } from "@/lib/supabase/server";
import { getMembership } from "@/lib/org-context";
import { searchEntityPage, sortByIds, fallbackOrFilter } from "@/lib/entity-search";

// Server-side search for the invoice forms' pickers (customer, supplier, product). The forms used to receive EVERY customer / supplier /
// product as a prop — which silently stopped at 1000 rows (the API's page cap) and shipped the whole catalogue to the browser. Now each
// picker asks for one short page of matches as the person types (Arabic spellings treated alike: migration 0069), and nothing is capped.
//
// Authorization is unchanged: these run as the signed-in user, so row-level security decides what they can see (a rep only finds their own
// customers, a role that may not read costs gets no cost) and the organization comes from their membership, never from the browser.

const LIMIT = 30;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const clean = (q: unknown) => String(q ?? "").slice(0, 80);

type Ctx = { supabase: Awaited<ReturnType<typeof createClient>>; orgId: string };
async function ctx(): Promise<Ctx | null> {
  const supabase = await createClient();
  const m = await getMembership();
  return m ? { supabase, orgId: m.organization_id as string } : null;
}

/** The ids of one page of matches (database search; plain contains-filter if the search function is not installed). */
async function matchIds(c: Ctx, table: "customers" | "suppliers" | "products", q: string): Promise<string[]> {
  const found = await searchEntityPage(c.supabase, c.orgId, table, q, 1, LIMIT);
  if (found) return found.ids;
  let req = c.supabase.from(table).select("id").eq("organization_id", c.orgId).order("name").limit(LIMIT);
  const f = fallbackOrFilter(table === "products" ? ["name", "sku", "barcode"] : ["name", "phone"], q);
  if (f) req = req.or(f);
  return ((await req).data ?? []).map((r) => (r as { id: string }).id);
}

export type CustomerPick = { id: string; name: string; price_tier: string; sales_rep_id: string | null };
export type SalesProductPick = { id: string; name: string; unit: string; selling_price: number; wholesale_price: number | null; distributor_price: number | null };
export type SupplierPick = { id: string; name: string; payment_terms_days: number | null };
export type PurchaseProductPick = { id: string; name: string; unit: string; cost: number };

export async function searchCustomerPicks(query: string): Promise<CustomerPick[]> {
  const c = await ctx();
  if (!c) return [];
  const ids = await matchIds(c, "customers", clean(query));
  if (!ids.length) return [];
  const { data } = await c.supabase.from("customers").select("id, name, price_tier, sales_rep_id").eq("organization_id", c.orgId).in("id", ids);
  return sortByIds((data ?? []) as CustomerPick[], ids);
}

export async function searchSupplierPicks(query: string): Promise<SupplierPick[]> {
  const c = await ctx();
  if (!c) return [];
  const ids = await matchIds(c, "suppliers", clean(query));
  if (!ids.length) return [];
  const { data } = await c.supabase.from("suppliers").select("id, name, payment_terms_days").eq("organization_id", c.orgId).in("id", ids);
  return sortByIds((data ?? []) as SupplierPick[], ids);
}

export async function searchSalesProductPicks(query: string): Promise<SalesProductPick[]> {
  const c = await ctx();
  if (!c) return [];
  return loadSalesProducts(c, await matchIds(c, "products", clean(query)));
}

async function loadSalesProducts(c: Ctx, ids: string[]): Promise<SalesProductPick[]> {
  if (!ids.length) return [];
  const [{ data: products }, { data: prices }] = await Promise.all([
    c.supabase.from("products").select("id, name, unit").eq("organization_id", c.orgId).in("id", ids),
    c.supabase.from("product_sale_prices").select("product_id, selling_price, wholesale_price, distributor_price").eq("organization_id", c.orgId).in("product_id", ids),
  ]);
  const price = new Map((prices ?? []).map((p) => [p.product_id as string, p]));
  const rows = (products ?? []).map((p) => {
    const pr = price.get(p.id as string);
    return { id: p.id as string, name: p.name as string, unit: p.unit as string, selling_price: Number(pr?.selling_price ?? 0), wholesale_price: pr?.wholesale_price == null ? null : Number(pr.wholesale_price), distributor_price: pr?.distributor_price == null ? null : Number(pr.distributor_price) };
  });
  return sortByIds(rows, ids);
}

export async function searchPurchaseProductPicks(query: string): Promise<PurchaseProductPick[]> {
  const c = await ctx();
  if (!c) return [];
  return loadPurchaseProducts(c, await matchIds(c, "products", clean(query)));
}

async function loadPurchaseProducts(c: Ctx, ids: string[]): Promise<PurchaseProductPick[]> {
  if (!ids.length) return [];
  const [{ data: products }, { data: costs }] = await Promise.all([
    c.supabase.from("products").select("id, name, unit").eq("organization_id", c.orgId).in("id", ids),
    // protected cost table: roles that may not read cost get no rows back and simply start from 0 (unchanged behaviour)
    c.supabase.from("product_costs").select("product_id, cost").eq("organization_id", c.orgId).in("product_id", ids),
  ]);
  const cost = new Map((costs ?? []).map((r) => [r.product_id as string, Number(r.cost)]));
  return sortByIds((products ?? []).map((p) => ({ id: p.id as string, name: p.name as string, unit: p.unit as string, cost: cost.get(p.id as string) ?? 0 })), ids);
}

/** Pre-selected products (a shortage report's product): loaded by id so the form can show them without a search. */
export async function getPurchaseProductPicks(ids: string[]): Promise<PurchaseProductPick[]> {
  const c = await ctx();
  const safe = (Array.isArray(ids) ? ids : []).filter((i) => typeof i === "string" && UUID.test(i)).slice(0, 20);
  return c ? loadPurchaseProducts(c, safe) : [];
}
