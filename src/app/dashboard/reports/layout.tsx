import { PageHeader } from "@/components/ui/page-header";
import { getRoleKey } from "@/lib/org-context";
import { ReportTabs } from "@/components/reports/report-tabs";

export default async function ReportsLayout({ children }: { children: React.ReactNode }) {
  const role = await getRoleKey();
  return (
    <div>
      <PageHeader title={role === "sales" ? "تقاريري" : "التقارير"} />
      <ReportTabs role={role ?? "owner"} />
      {role === "sales" && <p className="mb-5 rounded-card bg-paper px-3 py-2 text-xs text-charcoal/60">كل الأرقام في هذه التقارير تخص العملاء المسندين إليك وفواتيرك.</p>}
      {role === "warehouse" && <p className="mb-5 rounded-card bg-paper px-3 py-2 text-xs text-charcoal/60">تقارير المخزون بالكميات فقط.</p>}
      {children}
    </div>
  );
}
