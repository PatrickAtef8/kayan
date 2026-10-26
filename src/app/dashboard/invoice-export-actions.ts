"use server";

import { createClient } from "@/lib/supabase/server";
import { containsPattern } from "@/lib/doc-search";
import type { ListFilters, ListResult } from "@/lib/export/model";

// Export of the invoice LISTS (all invoices matching the page's search / date filters — not just the 20 on screen).
// Same rules as the pages: runs as the signed-in user (RLS decides what exists for them), inside their organisation, and —
// like every report export — only for members with the reports.export permission. A single invoice document is exported
// from the browser from the row the user already sees (no server call), see components/ui/invoice-export-buttons.tsx.

const MAX_ROWS = 2000;
const CHUNK = 150; // ids per request (keeps the URL short)
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const STATUS: Record<string, string> = { paid: "مدفوعة", partial: "مدفوعة جزئيًا", unpaid: "غير مدفوعة" };

type Supabase = Awaited<ReturnType<typeof createClient>>;

async function authorize(supabase: Supabase): Promise<{ orgId: string } | { error: string }> {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "انتهت الجلسة. سجّل الدخول من جديد." };
  const { data: membership } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).eq("status", "active").order("created_at", { ascending: true }).limit(1).maybeSingle();
  if (!membership) return { error: "لا توجد عضوية فعّالة." };
  const { data: allowed } = await supabase.rpc("has_permission", { target_org: membership.organization_id, perm_key: "reports.export" });
  if (!allowed) return { error: "ليس لديك صلاحية التصدير." };
  return { orgId: membership.organization_id as string };
}

function clean(f: ListFilters) {
  return {
    q: typeof f.q === "string" ? f.q.trim().slice(0, 100) : "",
    from: typeof f.from === "string" && DATE.test(f.from) ? f.from : undefined,
    to: typeof f.to === "string" && DATE.test(f.to) ? f.to : undefined,
  };
}

const r2 = (v: number) => Math.round(v * 100) / 100;
// identical to sales_invoice_remaining() / purchase_invoice_remaining(): total − paid − credit notes + cash refunds
const remaining = (total: number, paid: number, ret: { total: number; cash: number } | undefined) => Math.max(0, r2(total - paid - (ret?.total ?? 0) + (ret?.cash ?? 0)));

async function returnsFor(supabase: Supabase, orgId: string, table: "sales_returns" | "purchase_returns", fk: "sales_invoice_id" | "purchase_invoice_id", ids: string[]) {
  const map = new Map<string, { total: number; cash: number }>();
  for (let i = 0; i < ids.length; i += CHUNK) {
    const { data } = await supabase.from(table).select(`${fk}, total, cash_refunded`).eq("organization_id", orgId).in(fk, ids.slice(i, i + CHUNK));
    for (const r of (data ?? []) as unknown as Record<string, unknown>[]) {
      const key = r[fk] as string;
      const cur = map.get(key) ?? { total: 0, cash: 0 };
      cur.total += Number(r.total);
      cur.cash += Number(r.cash_refunded);
      map.set(key, cur);
    }
  }
  return map;
}

const TRUNCATED = `تم تصدير أحدث ${MAX_ROWS.toLocaleString("ar-EG")} فاتورة فقط — ضيّق نطاق التاريخ لتصدير الباقي.`;

type SalesRow = { id: string; invoice_number: string | null; invoice_date: string; total: number; amount_paid: number; payment_status: string; customers: { name: string } | null; sales_representatives: { name: string } | null; warehouses: { name: string } | null };

export async function exportSalesInvoiceList(filters: ListFilters): Promise<ListResult> {
  const supabase = await createClient();
  const auth = await authorize(supabase);
  if ("error" in auth) return { ok: false, error: auth.error };
  const { q, from, to } = clean(filters);

  let query = supabase
    .from("sales_invoices")
    .select("id, invoice_number, invoice_date, total, amount_paid, payment_status, customers(name), sales_representatives(name), warehouses(name)")
    .eq("organization_id", auth.orgId)
    .order("invoice_date", { ascending: false })
    .order("created_at", { ascending: false })
    .range(0, MAX_ROWS); // one more than the limit, to know whether the list was cut
  if (q) query = query.ilike("invoice_number", containsPattern(q));
  if (from) query = query.gte("invoice_date", from);
  if (to) query = query.lte("invoice_date", to);
  const { data, error } = await query;
  if (error) return { ok: false, error: "تعذّر تحميل الفواتير." };

  const all = (data ?? []) as unknown as SalesRow[];
  const truncated = all.length > MAX_ROWS;
  const list = truncated ? all.slice(0, MAX_ROWS) : all;
  const returns = await returnsFor(supabase, auth.orgId, "sales_returns", "sales_invoice_id", list.map((r) => r.id));

  const rows = list.map((r) => {
    const ret = returns.get(r.id);
    return [r.invoice_date, r.invoice_number ?? "", r.customers?.name ?? "", r.sales_representatives?.name ?? "", r.warehouses?.name ?? "", Number(r.total), Number(r.amount_paid), ret?.total ?? 0, remaining(Number(r.total), Number(r.amount_paid), ret), STATUS[r.payment_status] ?? r.payment_status];
  });
  return { ok: true, rows, note: truncated ? TRUNCATED : undefined };
}

type PurchaseRow = { id: string; invoice_number: string | null; invoice_date: string; total: number; amount_paid: number; payment_status: string; suppliers: { name: string } | null; warehouses: { name: string } | null };

export async function exportPurchaseInvoiceList(filters: ListFilters): Promise<ListResult> {
  const supabase = await createClient();
  const auth = await authorize(supabase);
  if ("error" in auth) return { ok: false, error: auth.error };
  const { q, from, to } = clean(filters);

  let query = supabase
    .from("purchase_invoices")
    .select("id, invoice_number, invoice_date, total, amount_paid, payment_status, suppliers(name), warehouses(name)")
    .eq("organization_id", auth.orgId)
    .order("invoice_date", { ascending: false })
    .order("created_at", { ascending: false })
    .range(0, MAX_ROWS);
  if (q) query = query.ilike("invoice_number", containsPattern(q));
  if (from) query = query.gte("invoice_date", from);
  if (to) query = query.lte("invoice_date", to);
  const { data, error } = await query;
  if (error) return { ok: false, error: "تعذّر تحميل الفواتير." };

  const all = (data ?? []) as unknown as PurchaseRow[];
  const truncated = all.length > MAX_ROWS;
  const list = truncated ? all.slice(0, MAX_ROWS) : all;
  const returns = await returnsFor(supabase, auth.orgId, "purchase_returns", "purchase_invoice_id", list.map((r) => r.id));

  const rows = list.map((r) => {
    const ret = returns.get(r.id);
    return [r.invoice_date, r.invoice_number ?? "", r.suppliers?.name ?? "", r.warehouses?.name ?? "", Number(r.total), Number(r.amount_paid), ret?.total ?? 0, remaining(Number(r.total), Number(r.amount_paid), ret), STATUS[r.payment_status] ?? r.payment_status];
  });
  return { ok: true, rows, note: truncated ? TRUNCATED : undefined };
}
