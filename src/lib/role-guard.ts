import { redirect } from "next/navigation";
import { getRoleKey, type RoleKey } from "@/lib/org-context";

// Server-side route guard (used by the section layouts). This is a convenience on top of the
// database rules, not a replacement: calling the APIs directly is refused by RLS/RPC checks anyway.
export async function requireRole(allowed: RoleKey[]) {
  const role = await getRoleKey();
  if (!role || !allowed.includes(role)) redirect("/dashboard");
  return role;
}
