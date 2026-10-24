import { cache } from "react";
import { createClient } from "@/lib/supabase/server";

// Per-request memoisation (React `cache` is scoped to a single server render,
// never shared between requests or users). The dashboard layout and the page
// under it render concurrently and used to each call auth.getUser() — a round
// trip to Supabase Auth — plus the membership lookup. They now share one call
// of each. Nothing is cached across requests, so permissions and membership
// are always read fresh.

export const getSupabase = cache(() => createClient());

export const getCurrentUser = cache(async () => {
  const {
    data: { user },
  } = await (await getSupabase()).auth.getUser();
  return user;
});

export const getMembership = cache(async () => {
  const user = await getCurrentUser();
  if (!user) return null;
  const { data, error } = await (await getSupabase())
    .from("organization_users")
    .select("organization_id, roles(name)")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (error) console.error("membership lookup failed", error);
  return data;
});

export function roleNameOf(membership: { roles: unknown } | null): string | undefined {
  const roles = membership?.roles as { name: string } | { name: string }[] | null | undefined;
  return Array.isArray(roles) ? roles[0]?.name : roles?.name;
}

// Matches no row; used so an org filter can always be applied even when the
// caller has no membership (the layout redirects such users anyway).
export const NO_ORG_ID = "00000000-0000-0000-0000-000000000000";

// The three roles of the system (0043). The database is the authority: every
// restriction below is enforced by RLS / RPC checks. These helpers only decide
// what to SHOW, so nobody is sent to a screen the database would refuse.
export type RoleKey = "owner" | "sales" | "warehouse";

export const getRoleKey = cache(async (): Promise<RoleKey | null> => {
  const membership = await getMembership();
  if (!membership) return null;
  const { data } = await (await getSupabase()).rpc("my_role_key", { target_org: membership.organization_id });
  return data === "owner" || data === "sales" || data === "warehouse" ? data : null;
});

// A member with the Sales Representative role sees only the customers assigned
// to their rep record (all of this enforced by RLS in the database).
export const isRestrictedRep = cache(async () => {
  const membership = await getMembership();
  if (!membership) return false;
  const { data } = await (await getSupabase()).rpc("is_restricted_rep", { target_org: membership.organization_id });
  return !!data;
});
