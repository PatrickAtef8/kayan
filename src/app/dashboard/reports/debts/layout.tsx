import { requireRole } from "@/lib/role-guard";
import { isRestrictedRep } from "@/lib/org-context";
import { DebtsTabs } from "@/components/reports/debts-tabs";

export default async function DebtsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(["owner", "sales"]);
  const restricted = await isRestrictedRep();
  return (
    <div>
      <DebtsTabs restrictedRep={restricted} />
      {children}
    </div>
  );
}
