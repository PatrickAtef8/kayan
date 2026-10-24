import { requireRole } from "@/lib/role-guard";

// Owner: all reports. Sales rep: his own. The storekeeper has no use for this screen (the database refuses him too).
export default async function Layout({ children }: { children: React.ReactNode }) {
  await requireRole(["owner", "sales"]);
  return <>{children}</>;
}
