"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getSiteUrl, explainInviteError } from "@/lib/site-url";
import { translateDbError, safeErrorMessage } from "@/lib/db-errors";
import { rateLimit, RATE_POLICIES, tooManyRequestsMessage } from "@/lib/rate-limit.server";
import { sendEmail, isEmailConfigured, hasRecentSend } from "@/lib/email/service.server";
import { isValidEmailAddress } from "@/lib/email/config";

async function getMembership(supabase: Awaited<ReturnType<typeof createClient>>) {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  return membership;
}

// mode "existing":     the person already has an account and NO email was sent (the email service is not configured): they see the invitation on /invites.
// mode "notified":     the person already has an account; an email told them to sign in and accept on /invites.
// mode "emailed":      a new account was created and an invitation email with a set-password link was sent.
// mode "email_failed": the invitation is recorded but the email could not be sent (see `warning`); adding the same address again re-sends it.
export type AddMemberResult = { error: string | null; mode?: "existing" | "notified" | "emailed" | "email_failed"; warning?: string };

const ALREADY_REGISTERED = /already|registered|exists/i;

export async function addTeamMember(email: string, roleId: string, name: string): Promise<AddMemberResult> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const trimmedEmail = email.trim();
  const trimmedName = name.trim();
  if (!trimmedEmail || !roleId) return { error: "البريد الإلكتروني والدور مطلوبان" };
  if (!trimmedName) return { error: "اسم الشخص مطلوب" };
  if (trimmedName.length > 100) return { error: "الاسم طويل جدًا (الحد الأقصى ١٠٠ حرف)" };
  if (trimmedEmail.length > 254 || !isValidEmailAddress(trimmedEmail)) return { error: "البريد الإلكتروني غير صالح" };

  // an invitation can send a real e-mail to any address: cap how many one company can trigger per hour
  const limit = await rateLimit(RATE_POLICIES.teamInvite, membership.organization_id);
  if (!limit.allowed) return { error: tooManyRequestsMessage(limit.retryAfter) };

  // Not a second email within 10 minutes: every invitation link is one-time, and issuing a new one would silently kill the one already in their inbox.
  if (isEmailConfigured() && (await hasRecentSend("team_invite", trimmedEmail, 10) || await hasRecentSend("team_invite_existing", trimmedEmail, 10))) {
    return { error: "أرسلنا دعوة إلى هذا البريد قبل لحظات. انتظر بضع دقائق قبل إعادة الإرسال." };
  }

  const { data, error } = await supabase.rpc("add_team_member", {
    org_id: membership.organization_id,
    p_email: trimmedEmail,
    p_role_id: roleId,
    p_name: trimmedName,
  });
  if (error) return { error: safeErrorMessage(error) };

  const status = (data as { status: string } | null)?.status;
  const emailReady = isEmailConfigured();

  // The context every invitation email needs (RLS applies: the caller can read their own company and its roles).
  const orgId = membership.organization_id as string;
  const [{ data: org }, { data: role }, { data: inviter }] = await Promise.all([
    supabase.from("organizations").select("name").eq("id", orgId).maybeSingle(),
    supabase.from("roles").select("name").eq("id", roleId).maybeSingle(),
    supabase.from("organization_users").select("display_name").eq("organization_id", orgId).eq("user_id", (await supabase.auth.getUser()).data.user?.id ?? "").maybeSingle(),
  ]);
  const ctx = { orgName: (org as { name?: string } | null)?.name ?? "—", roleName: (role as { name?: string } | null)?.name ?? "—", inviterName: (inviter as { display_name?: string | null } | null)?.display_name ?? null };

  let origin: string;
  try {
    origin = getSiteUrl();
  } catch (e) {
    return { error: e instanceof Error ? e.message : "تعذّر تحديد عنوان الموقع" };
  }

  if (status === "added") {
    // An existing account. Normally they just sign in and accept on /invites. Without the email service nothing is sent (as before).
    revalidatePath("/dashboard/settings/team");
    if (!emailReady) return { error: null, mode: "existing" };

    // An account that was created by an earlier invitation but never confirmed has no password yet: it needs a fresh set-password link,
    // not a "sign in" notice. generateLink("invite") succeeds only for such an account — for a normal one it reports "already registered".
    let admin;
    try { admin = createAdminClient(); } catch { return { error: null, mode: "existing" }; }
    const gen = await admin.auth.admin.generateLink({ type: "invite", email: trimmedEmail, options: { redirectTo: `${origin}/reset-password` } });
    const hashed = gen.data?.properties?.hashed_token;
    if (!gen.error && hashed) {
      const sent = await sendEmail({ template: "team_invite", to: trimmedEmail, organizationId: orgId, data: { ...ctx, link: `${origin}/reset-password?token_hash=${encodeURIComponent(hashed)}&type=invite` } });
      return sent.ok ? { error: null, mode: "emailed" } : { error: null, mode: "email_failed", warning: sent.message.ar };
    }
    if (gen.error && !ALREADY_REGISTERED.test(gen.error.message)) console.error("invite link generation failed", { code: (gen.error as { code?: string }).code, status: (gen.error as { status?: number }).status });
    const sent = await sendEmail({ template: "team_invite_existing", to: trimmedEmail, organizationId: orgId, data: { ...ctx, link: `${origin}/invites` } });
    return sent.ok ? { error: null, mode: "notified" } : { error: null, mode: "email_failed", warning: sent.message.ar };
  }

  // status === "needs_invite": no existing Supabase account for this email — create one via the admin API, then finish the membership.
  let adminClient;
  try {
    adminClient = createAdminClient();
  } catch (e) {
    return { error: e instanceof Error ? e.message : "تعذّر إرسال الدعوة" };
  }

  if (!emailReady) {
    // Email service not configured: fall back to Supabase's own invitation email (it goes out through whatever SMTP the Supabase project has).
    // The emailed link opens /reset-password: it signs the invited person in and lets them choose a password.
    const { data: invited, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(trimmedEmail, { redirectTo: `${origin}/reset-password` });
    if (inviteError || !invited?.user) return { error: inviteError ? explainInviteError(inviteError.message) : "تعذّر دعوة هذا البريد الإلكتروني" };
    const { error: completeError } = await supabase.rpc("complete_team_invite", { org_id: orgId, p_user_id: invited.user.id, p_role_id: roleId, p_name: trimmedName });
    if (completeError) return { error: safeErrorMessage(completeError) };
    revalidatePath("/dashboard/settings/team");
    return { error: null, mode: "emailed" };
  }

  // Resend path: create the account + a one-time link WITHOUT Supabase emailing anything, record the membership, then send our own branded email.
  const gen = await adminClient.auth.admin.generateLink({ type: "invite", email: trimmedEmail, options: { redirectTo: `${origin}/reset-password` } });
  const userId = gen.data?.user?.id;
  const hashed = gen.data?.properties?.hashed_token;
  if (gen.error || !userId || !hashed) return { error: gen.error ? explainInviteError(gen.error.message) : "تعذّر دعوة هذا البريد الإلكتروني" };

  const { error: completeError } = await supabase.rpc("complete_team_invite", { org_id: orgId, p_user_id: userId, p_role_id: roleId, p_name: trimmedName });
  if (completeError) return { error: safeErrorMessage(completeError) };
  revalidatePath("/dashboard/settings/team");

  // token_hash link to OUR page: nothing is consumed until the person's browser runs the page, so mail scanners that pre-open links cannot burn it.
  const sent = await sendEmail({ template: "team_invite", to: trimmedEmail, organizationId: orgId, data: { ...ctx, link: `${origin}/reset-password?token_hash=${encodeURIComponent(hashed)}&type=invite` } });
  return sent.ok ? { error: null, mode: "emailed" } : { error: null, mode: "email_failed", warning: sent.message.ar };
}

export async function updateMemberRole(userId: string, roleId: string) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("organization_users").update({ role_id: roleId }).eq("organization_id", membership.organization_id).eq("user_id", userId);
  if (error) return { error: safeErrorMessage(error) };

  revalidatePath("/dashboard/settings/team");
  return { error: null };
}

// Rename a member (also how members added before names existed get one).
export async function updateMemberName(userId: string, name: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  const trimmed = name.trim();
  if (!trimmed) return { error: "الاسم مطلوب" };
  if (trimmed.length > 100) return { error: "الاسم طويل جدًا (الحد الأقصى ١٠٠ حرف)" };

  const { error } = await supabase.rpc("update_member_name", { org_id: membership.organization_id, p_user_id: userId, p_name: trimmed });
  if (error) return { error: safeErrorMessage(error) };

  revalidatePath("/dashboard/settings/team");
  return { error: null };
}

export async function removeMember(userId: string) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("organization_users").delete().eq("organization_id", membership.organization_id).eq("user_id", userId);
  if (error) return { error: safeErrorMessage(error) };

  revalidatePath("/dashboard/settings/team");
  return { error: null };
}

// One-click link between a team member with the "مندوب" role and a sales-representative record
// (the link is what makes the rep see anything). Either attaches the member to an existing,
// not-yet-linked rep record (repId) or creates a new record for them (repId = null).
export async function linkMemberToRep(userId: string, repId: string | null, displayName: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  const orgId = membership.organization_id;

  if (repId) {
    const { data, error } = await supabase
      .from("sales_representatives")
      .update({ user_id: userId })
      .eq("id", repId)
      .eq("organization_id", orgId)
      .is("user_id", null)
      .select("id");
    if (error) return { error: translateDbError(error, "sales_representatives") };
    if (!data || data.length === 0) return { error: "تعذّر الربط — هذا السجل مربوط بمستخدم آخر أو غير موجود." };
  } else {
    const name = displayName.trim() || "مندوب";
    const { error } = await supabase.from("sales_representatives").insert({ organization_id: orgId, name, user_id: userId });
    if (error) return { error: translateDbError(error, "sales_representatives") };
  }

  revalidatePath("/dashboard/settings/team");
  revalidatePath("/dashboard/representatives");
  revalidatePath("/dashboard/customers");
  return { error: null };
}
