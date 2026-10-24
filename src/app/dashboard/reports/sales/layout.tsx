import { requireRole } from "@/lib/role-guard";
import { SalesReportTabs } from "@/components/reports/sales-report-tabs";

export default async function SalesReportsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(["owner", "sales"]);
  return (
    <div>
      <SalesReportTabs />
      {children}
    </div>
  );
}
