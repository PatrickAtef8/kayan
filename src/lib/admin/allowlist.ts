// Who is a Super Admin. Pure, so it is unit-tested. Two environment variables, both server-only, both optional:
//   SUPER_ADMIN_USER_IDS  comma-separated Supabase auth user ids (UUIDs)   ← preferred: an id can never be claimed by anyone else
//   SUPER_ADMIN_EMAILS    comma-separated emails; honoured only for an account whose email is CONFIRMED
// With neither set, nobody is a Super Admin and /admin does not exist for anyone.
export type AdminCandidate = { id: string; email?: string | null; email_confirmed_at?: string | null };

const list = (v: string | undefined) => (v ?? "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);

export function isSuperAdmin(user: AdminCandidate | null | undefined, env: { SUPER_ADMIN_USER_IDS?: string; SUPER_ADMIN_EMAILS?: string }): boolean {
  if (!user?.id) return false;
  if (list(env.SUPER_ADMIN_USER_IDS).includes(user.id.toLowerCase())) return true;
  const email = user.email?.trim().toLowerCase();
  return !!email && !!user.email_confirmed_at && list(env.SUPER_ADMIN_EMAILS).includes(email);
}

/** The ids / emails configured as platform administrators, parsed (lower-cased, empties dropped). */
export function adminLists(env: { SUPER_ADMIN_USER_IDS?: string; SUPER_ADMIN_EMAILS?: string }): { ids: string[]; emails: string[] } {
  return { ids: list(env.SUPER_ADMIN_USER_IDS), emails: list(env.SUPER_ADMIN_EMAILS) };
}
