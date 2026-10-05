import { PageHeader } from "@/components/ui/page-header";
import { isRestrictedRep } from "@/lib/org-context";
import { ReportTabs } from "@/components/reports/report-tabs";

export default async function ReportsLayout({ children }: { children: React.ReactNode }) {
  const restrictedRep = await isRestrictedRep();
  return (
    <div>
      <PageHeader title="التقارير" />
      <ReportTabs restrictedRep={restrictedRep} />
      {children}
    </div>
  );
}
