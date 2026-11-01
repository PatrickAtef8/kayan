import { requireRole } from "@/lib/role-guard";

// Billing belongs to the owner. (The database refuses anyone else the data, and every action re-checks the role.)
export default async function BillingLayout({ children }: { children: React.ReactNode }) {
  await requireRole(["owner"]);
  return <>{children}</>;
}
