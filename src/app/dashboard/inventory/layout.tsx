import { requireRole } from "@/lib/role-guard";

// Route guard for this section (the database enforces the same rule on the data itself).
export default async function Layout({ children }: { children: React.ReactNode }) {
  await requireRole(["owner", "warehouse"]);
  return <>{children}</>;
}
