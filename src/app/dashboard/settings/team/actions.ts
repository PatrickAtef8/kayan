"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getSiteUrl, explainInviteError } from "@/lib/site-url";
import { translateDbError, safeErrorMessage } from "@/lib/db-errors";
import { rateLimit, RATE_POLICIES, tooManyRequestsMessage } from "@/lib/rate-limit.server";

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

// mode "existing": the person already has an account -> NO email is sent; they see the invitation on /invites after signing in.
// mode "emailed":  a new account was created and Supabase emailed them an invitation link.
export type AddMemberResult = { error: string | null; mode?: "existing" | "emailed" };

export async function addTeamMember(email: string, roleId: string, name: string): Promise<AddMemberResult> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const trimmedEmail = email.trim();
  const trimmedName = name.trim();
  if (!trimmedEmail || !roleId) return { error: "البريد الإلكتروني والدور مطلوبان" };
  if (!trimmedName) return { error: "اسم الشخص مطلوب" };
  if (trimmedName.length > 100) return { error: "الاسم طويل جدًا (الحد الأقصى ١٠٠ حرف)" };
  if (trimmedEmail.length > 254) return { error: "البريد الإلكتروني غير صالح" };

  // an invitation can send a real e-mail to any address: cap how many one company can trigger per hour
  const limit = await rateLimit(RATE_POLICIES.teamInvite, membership.organization_id);
  if (!limit.allowed) return { error: tooManyRequestsMessage(limit.retryAfter) };

  const { data, error } = await supabase.rpc("add_team_member", {
    org_id: membership.organization_id,
    p_email: trimmedEmail,
    p_role_id: roleId,
    p_name: trimmedName,
  });
  if (error) return { error: safeErrorMessage(error) };

  const status = (data as { status: string } | null)?.status;

  if (status === "added") {
    revalidatePath("/dashboard/settings/team");
    return { error: null, mode: "existing" };
  }

  // status === "needs_invite": no existing Supabase account for this
  // email — create one via the admin API, then finish the membership.
  let adminClient;
  try {
    adminClient = createAdminClient();
  } catch (e) {
    return { error: e instanceof Error ? e.message : "تعذّر إرسال الدعوة" };
  }

  let origin: string;
  try {
    origin = getSiteUrl();
  } catch (e) {
    return { error: e instanceof Error ? e.message : "تعذّر تحديد عنوان الموقع" };
  }
  // The emailed link opens /reset-password: it signs the invited person in and lets them choose a password.
  const { data: invited, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(trimmedEmail, {
    redirectTo: `${origin}/reset-password`,
  });

  if (inviteError || !invited?.user) {
    return { error: inviteError ? explainInviteError(inviteError.message) : "تعذّر دعوة هذا البريد الإلكتروني" };
  }

  const { error: completeError } = await supabase.rpc("complete_team_invite", {
    org_id: membership.organization_id,
    p_user_id: invited.user.id,
    p_role_id: roleId,
    p_name: trimmedName,
  });
  if (completeError) return { error: safeErrorMessage(completeError) };

  revalidatePath("/dashboard/settings/team");
  return { error: null, mode: "emailed" };
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
