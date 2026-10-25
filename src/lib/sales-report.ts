import { formatMoney } from "@/lib/money";
// Shared by the three sales report pages (by rep / channel / product): URL params → RPC arguments,
// plus the display helpers that must stay identical across them.
import type { SupabaseClient } from "@supabase/supabase-js";

export type SalesSearchParams = { from?: string; to?: string; all?: string; warehouse?: string; rep?: string; channel?: string };

export type SalesRow = {
  group_id: string;
  group_label: string;
  invoices: number;
  customers: number;
  products: number;
  billed_qty: number;
  bonus_qty: number;
  returned_qty: number;
  net_qty: number;
  units_per_carton: number | null;
  whole_cartons: number | null;
  remainder_units: number | null;
  cartons: number;
  loose_units: number;
  gross_sales: number;
  discounts: number;
  returns_value: number;
  net_revenue: number;
  total_count: number;
};

export const CHANNELS = [
  { value: "wholesale", label: "جملة" },
  { value: "retail", label: "تجزئة" },
  { value: "social", label: "سوشيال ميديا" },
];

const ISO = /^\d{4}-\d{2}-\d{2}$/;

// No dates → the current month (Cairo). `all=1` → every period. An explicit from/to always wins.
export function resolveRange(sp: SalesSearchParams): { from: string | null; to: string | null } {
  const from = sp.from && ISO.test(sp.from) ? sp.from : null;
  const to = sp.to && ISO.test(sp.to) ? sp.to : null;
  if (from || to) return { from, to };
  if (sp.all === "1") return { from: null, to: null };
  const today = new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Cairo" });
  return { from: `${today.slice(0, 8)}01`, to: today };
}

export function parseFilters(sp: SalesSearchParams) {
  const { from, to } = resolveRange(sp);
  const channel = CHANNELS.some((c) => c.value === sp.channel) ? (sp.channel as string) : null;
  return { from, to, warehouse: sp.warehouse || null, rep: sp.rep || null, channel };
}

export type SalesFilters = ReturnType<typeof parseFilters>;

export async function loadSalesRows(supabase: SupabaseClient, orgId: string, group: "rep" | "channel" | "product" | "customer", f: SalesFilters, limit = 1000) {
  const { data } = await supabase.rpc("report_sales_by", {
    org_id: orgId,
    p_group: group,
    p_from: f.from,
    p_to: f.to,
    p_warehouse: f.warehouse,
    p_rep: f.rep,
    p_channel: f.channel,
    p_limit: limit,
    p_offset: 0,
  });
  return ((data as SalesRow[] | null) ?? []).map((r) => ({
    ...r,
    invoices: Number(r.invoices),
    customers: Number(r.customers),
    products: Number(r.products),
    billed_qty: Number(r.billed_qty),
    bonus_qty: Number(r.bonus_qty),
    returned_qty: Number(r.returned_qty),
    net_qty: Number(r.net_qty),
    units_per_carton: r.units_per_carton === null ? null : Number(r.units_per_carton),
    whole_cartons: r.whole_cartons === null ? null : Number(r.whole_cartons),
    remainder_units: r.remainder_units === null ? null : Number(r.remainder_units),
    cartons: Number(r.cartons),
    loose_units: Number(r.loose_units),
    gross_sales: Number(r.gross_sales),
    discounts: Number(r.discounts),
    returns_value: Number(r.returns_value),
    net_revenue: Number(r.net_revenue),
    total_count: Number(r.total_count),
  }));
}

export const money = (n: number) => formatMoney(n);
export const qty = (n: number) => Number(n).toLocaleString("ar-EG", { maximumFractionDigits: 3 });
export const cartonsText = (n: number) => Number(n).toLocaleString("ar-EG", { maximumFractionDigits: 2 });

// One product: "6 كرتونة + 5 قطعة" from its own packaging configuration; "—" when it has none.
export function productCartons(r: SalesRow): string {
  if (r.units_per_carton === null || r.whole_cartons === null) return "—";
  const rest = Number(r.remainder_units ?? 0);
  return `${qty(r.whole_cartons)} كرتونة${rest > 0 ? ` + ${qty(rest)} قطعة` : ""}`;
}

// Keeps every query-string param, overriding the given ones (empty string removes a param).
export function withParams(sp: SalesSearchParams, patch: Record<string, string>): string {
  const merged: Record<string, string> = { ...(sp as Record<string, string>), ...patch };
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(merged)) if (v) p.set(k, v);
  const s = p.toString();
  return s ? `?${s}` : "";
}

export async function loadFilterOptions(supabase: SupabaseClient, orgId: string) {
  const [{ data: warehouses }, { data: reps }] = await Promise.all([
    supabase.from("warehouses").select("id, name").eq("organization_id", orgId).eq("is_active", true).order("name"),
    supabase.from("sales_representatives").select("id, name").eq("organization_id", orgId).order("name"),
  ]);
  return { warehouses: (warehouses ?? []) as { id: string; name: string }[], reps: (reps ?? []) as { id: string; name: string }[] };
}
