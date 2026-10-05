"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";

async function getMembership(supabase: ReturnType<typeof createClient>) {
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

export async function addTeamMember(email: string, roleId: string) {
  const supabase = createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const trimmedEmail = email.trim();
  if (!trimmedEmail || !roleId) return { error: "البريد الإلكتروني والدور مطلوبان" };

  const { data, error } = await supabase.rpc("add_team_member", {
    org_id: membership.organization_id,
    p_email: trimmedEmail,
    p_role_id: roleId,
  });
  if (error) return { error: error.message };

  const status = (data as { status: string } | null)?.status;

  if (status === "added") {
    revalidatePath("/dashboard/settings/team");
    return { error: null };
  }

  // status === "needs_invite": no existing Supabase account for this
  // email — create one via the admin API, then finish the membership.
  let adminClient;
  try {
    adminClient = createAdminClient();
  } catch (e) {
    return { error: e instanceof Error ? e.message : "تعذّر إرسال الدعوة" };
  }

  const origin = process.env.NEXT_PUBLIC_SITE_URL || "http://localhost:3000";
  const { data: invited, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(trimmedEmail, {
    redirectTo: `${origin}/dashboard`,
  });

  if (inviteError || !invited?.user) {
    return { error: inviteError?.message || "تعذّر دعوة هذا البريد الإلكتروني" };
  }

  const { error: completeError } = await supabase.rpc("complete_team_invite", {
    org_id: membership.organization_id,
    p_user_id: invited.user.id,
    p_role_id: roleId,
  });
  if (completeError) return { error: completeError.message };

  revalidatePath("/dashboard/settings/team");
  return { error: null };
}

export async function updateMemberRole(userId: string, roleId: string) {
  const supabase = createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("organization_users").update({ role_id: roleId }).eq("organization_id", membership.organization_id).eq("user_id", userId);
  if (error) return { error: error.message };

  revalidatePath("/dashboard/settings/team");
  return { error: null };
}

export async function removeMember(userId: string) {
  const supabase = createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("organization_users").delete().eq("organization_id", membership.organization_id).eq("user_id", userId);
  if (error) return { error: error.message };

  revalidatePath("/dashboard/settings/team");
  return { error: null };
}
