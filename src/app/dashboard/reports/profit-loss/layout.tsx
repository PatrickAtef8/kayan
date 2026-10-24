import { requireRole } from "@/lib/role-guard";

export default async function Layout({ children }: { children: React.ReactNode }) {
  await requireRole(["owner"]);
  return <>{children}</>;
}
