import Link from "next/link";
import { getSupabase, getMembership, NO_ORG_ID } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { DataTable } from "@/components/ui/data-table";
import { StartStocktakeForm } from "./start-stocktake-form";

type Row = {
  id: string;
  status: "counting" | "applied" | "cancelled";
  notes: string | null;
  started_at: string;
  closed_at: string | null;
  warehouses: { name: string } | { name: string }[] | null;
};

const STATUS_LABEL = { counting: "جارٍ الجرد", applied: "تم الاعتماد", cancelled: "ملغي" } as const;
const STATUS_STYLE = { counting: "bg-amber-100 text-amber-700", applied: "bg-sageSoft text-sage", cancelled: "bg-paper text-charcoal/55" } as const;
const dt = (d: string) => new Date(d).toLocaleString("ar-EG", { timeZone: "Africa/Cairo", dateStyle: "medium", timeStyle: "short" });

export default async function StocktakeListPage() {
  const supabase = await getSupabase();
  const membership = await getMembership();
  const orgId = membership?.organization_id ?? NO_ORG_ID;

  const [{ data }, { data: canAdjust }, { data: warehouses }] = await Promise.all([
    supabase.from("stocktakes").select("id, status, notes, started_at, closed_at, warehouses(name)").eq("organization_id", orgId).order("started_at", { ascending: false }).limit(100),
    membership ? supabase.rpc("has_permission", { target_org: orgId, perm_key: "inventory.adjust" }) : Promise.resolve({ data: false }),
    supabase.from("warehouses").select("id, name").eq("organization_id", orgId).eq("is_active", true).order("name"),
  ]);
  const rows = (data as unknown as Row[]) ?? [];
  const wname = (r: Row) => (Array.isArray(r.warehouses) ? r.warehouses[0]?.name : r.warehouses?.name) ?? "—";

  return (
    <div>
      <PageHeader
        title="جرد المخزن"
        action={
          <Link href="/dashboard/inventory" className="rounded-xl border border-borderSoft bg-white px-4 py-2.5 text-sm font-medium text-charcoal hover:border-sage">
            رجوع للمخزون
          </Link>
        }
      />
      {canAdjust && (warehouses?.length ?? 0) > 0 && <StartStocktakeForm warehouses={warehouses ?? []} />}
      <DataTable<Row>
        rows={rows}
        getRowKey={(r) => r.id}
        emptyLabel="لا توجد عمليات جرد بعد"
        columns={[
          { header: "بدأ في", render: (r) => dt(r.started_at) },
          { header: "المخزن", render: (r) => wname(r) },
          { header: "ملاحظات", render: (r) => r.notes ?? "—" },
          { header: "الحالة", render: (r) => <span className={`rounded-md px-2 py-0.5 text-xs font-medium ${STATUS_STYLE[r.status]}`}>{STATUS_LABEL[r.status]}</span> },
          { header: "أُغلق في", render: (r) => (r.closed_at ? dt(r.closed_at) : "—") },
          { header: "", render: (r) => <Link href={`/dashboard/inventory/stocktake/${r.id}`} className="text-xs text-sage hover:underline">فتح</Link> },
        ]}
      />
    </div>
  );
}
