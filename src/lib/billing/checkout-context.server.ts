import "server-only";
import { cache } from "react";
import { redirect } from "next/navigation";
import { getCurrentUser, getMembership, getRoleKey, getOrgAccess } from "@/lib/org-context";
import { isSuperAdminSession } from "@/lib/admin/auth.server";
import { parseAccess } from "./access-gate";

// Everything the /checkout pages need to know about the caller, resolved once per request on the server:
// who they are, whether they are a platform administrator, which company they belong to, their role there, and the company's
// subscription state (from the database, which answers even for a company that has not paid yet).
export const getCheckoutContext = cache(async () => {
  const user = await getCurrentUser();
  if (!user) redirect("/login");
  const [isAdmin, membership] = await Promise.all([isSuperAdminSession(user), getMembership()]);
  if (!membership) return { user, isAdmin, orgId: null as string | null, roleKey: null as string | null, access: null };
  const orgId = membership.organization_id as string;
  const [roleKey, accessRes] = await Promise.all([getRoleKey(), getOrgAccess(orgId)]);
  return { user, isAdmin, orgId, roleKey, access: parseAccess(accessRes.data) };
});
