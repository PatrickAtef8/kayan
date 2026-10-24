import Link from "next/link";
import { notFound } from "next/navigation";
import { getSupabase, getMembership, NO_ORG_ID } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { StocktakeSheet, type SheetLine, type SheetSummary } from "./stocktake-sheet";

export default async function StocktakePage(props: { params: Promise<{ id: string }> }) {
  const { id } = await props.params;
  const supabase = await getSupabase();
  const membership = await getMembership();
  if (!membership) notFound();
  const orgId = membership?.organization_id ?? NO_ORG_ID;

  const [{ data: summary, error }, { data: lines }, { data: head }, { data: canCount }, { data: products }] = await Promise.all([
    supabase.rpc("stocktake_summary", { org_id: orgId, p_stocktake_id: id }),
    supabase.rpc("report_stocktake", { org_id: orgId, p_stocktake_id: id }),
    supabase.from("stocktakes").select("id, warehouses(name)").eq("id", id).eq("organization_id", orgId).maybeSingle(),
    supabase.rpc("has_permission", { target_org: orgId, perm_key: "inventory.adjust" }),
    supabase.from("products").select("id, name").eq("organization_id", orgId).eq("is_active", true).eq("track_inventory", true).order("name"),
  ]);
  if (error || !summary || !head) notFound();

  const wh = (head as unknown as { warehouses: { name: string } | { name: string }[] | null }).warehouses;
  const warehouseName = (Array.isArray(wh) ? wh[0]?.name : wh?.name) ?? "—";

  return (
    <div>
      <PageHeader
        title={`جرد المخزن — ${warehouseName}`}
        action={
          <Link href="/dashboard/inventory/stocktake" className="no-print rounded-xl border border-borderSoft bg-white px-4 py-2.5 text-sm font-medium text-charcoal hover:border-sage">
            كل عمليات الجرد
          </Link>
        }
      />
      <StocktakeSheet
        stocktakeId={id}
        summary={summary as unknown as SheetSummary}
        lines={((lines as unknown as SheetLine[]) ?? []).map((l) => ({
          ...l,
          system_qty: Number(l.system_qty),
          current_qty: Number(l.current_qty),
          counted_qty: l.counted_qty === null ? null : Number(l.counted_qty),
          unit_cost: l.unit_cost === null ? null : Number(l.unit_cost),
        }))}
        products={products ?? []}
        canCount={Boolean(canCount)}
      />
    </div>
  );
}
