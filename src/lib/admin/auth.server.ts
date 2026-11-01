import "server-only";
import { cache } from "react";
import { notFound, redirect } from "next/navigation";
import { getCurrentUser } from "@/lib/org-context";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { isSuperAdmin, adminLists, type AdminCandidate } from "./allowlist";

// Server-side Super Admin authorization. Every admin page AND every admin action calls one of these; nothing is trusted
// from the browser. The user comes from auth.getUser() (verified with Supabase, not just decoded from a cookie).

function currentEnv() {
  return { SUPER_ADMIN_USER_IDS: process.env.SUPER_ADMIN_USER_IDS, SUPER_ADMIN_EMAILS: process.env.SUPER_ADMIN_EMAILS };
}

export function isSuperAdminUser(user: AdminCandidate | null | undefined): boolean {
  return isSuperAdmin(user, currentEnv());
}

// The Auth-verified user, fetched at most ONCE per request (a network round trip to Supabase Auth). Only needed for an administrator
// listed by EMAIL, because that list is honoured only for a confirmed email, which the session token does not carry.
const verifiedUser = cache(async () => {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  return user;
});

/**
 * For pages/layouts: not signed in → login; signed in but not an admin → a plain 404 (the area does not exist for them).
 * Memoised per request, so the admin layout and the page under it authorize ONCE (they used to pay a separate Auth round trip each).
 * An administrator listed by user id costs no network at all (the id comes from the verified session token); one listed by email
 * costs a single verified lookup. Server ACTIONS (writes) still verify with auth.getUser() themselves.
 */
export const requireSuperAdminPage = cache(async (): Promise<{ id: string; email: string | null }> => {
  const me = await getCurrentUser();
  if (!me) redirect("/login");
  const env = currentEnv();
  if (adminLists(env).ids.includes(me.id.toLowerCase())) return { id: me.id, email: me.email ?? null };
  if (!me.email || !adminLists(env).emails.includes(me.email.trim().toLowerCase())) notFound();   // not on either list: no network needed
  const user = await verifiedUser();
  if (!user) redirect("/login");
  if (!isSuperAdminUser(user)) notFound();
  return { id: user.id, email: user.email ?? null };
});

export type AdminContext = { ok: true; userId: string; email: string | null; admin: ReturnType<typeof createAdminClient> } | { ok: false; error: string };

/** For server actions: returns the service-role client only to a verified Super Admin. */
export async function requireSuperAdminAction(): Promise<AdminContext> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user || !isSuperAdminUser(user)) return { ok: false, error: "غير مصرح" };
  try {
    return { ok: true, userId: user.id, email: user.email ?? null, admin: createAdminClient() };
  } catch {
    return { ok: false, error: "مفتاح الخدمة SUPABASE_SERVICE_ROLE_KEY غير مضبوط على الخادم." };
  }
}

/**
 * "Is the person behind this session a platform administrator?" for the DASHBOARD layout, which runs on every page and
 * therefore must not pay a network round trip to Supabase Auth for ordinary users.
 *   • by user id (SUPER_ADMIN_USER_IDS): a plain comparison with the verified id — no network;
 *   • by email (SUPER_ADMIN_EMAILS): only when the session's email is on that list do we ask Supabase Auth for the verified user
 *     (the list is honoured only for a CONFIRMED email, which the session token does not carry).
 * Everyone else costs nothing.
 */
const superAdminSession = cache(async (id: string, email: string): Promise<boolean> => {
  const env = currentEnv();
  const { ids, emails } = adminLists(env);
  if (ids.length === 0 && emails.length === 0) return false;
  if (ids.includes(id.toLowerCase())) return true;
  const e = email.trim().toLowerCase();
  if (!e || !emails.includes(e)) return false;
  return isSuperAdmin(await verifiedUser(), env);
});

export async function isSuperAdminSession(user: { id: string; email?: string | null }): Promise<boolean> {
  return superAdminSession(user.id, user.email ?? "");   // memoised per request: the layout and the page ask the same question
}

/** Is any of these owners a platform administrator? (by id, or by confirmed email) */
export function anyOwnerIsSuperAdmin(owners: { id: string; email?: string | null; confirmed?: boolean | null }[]): boolean {
  const env = currentEnv();
  return owners.some((o) => isSuperAdmin({ id: o.id, email: o.email ?? null, email_confirmed_at: o.confirmed ? "confirmed" : null }, env));
}

/** The configured administrators, for the SQL helpers that count / exclude their companies. */
export function configuredAdmins() {
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const { ids, emails } = adminLists(currentEnv());
  return { ids: ids.filter((i) => UUID.test(i)), emails };
}
