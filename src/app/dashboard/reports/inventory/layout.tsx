import { requireRole } from "@/lib/role-guard";
import { InventoryTabs } from "@/components/reports/inventory-tabs";

export default async function InventoryReportsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(["owner", "warehouse"]);
  return (
    <div>
      <InventoryTabs />
      {children}
    </div>
  );
}
