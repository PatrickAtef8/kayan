"use server";

import { createAdminClient } from "@/lib/supabase/admin";
import { translateAuthError } from "@/lib/auth-errors";
import { MIN_PASSWORD_LENGTH, isPasswordAcceptable } from "@/lib/password-strength";

// Saves the password for the person who just opened an invitation / reset link.
// Done on the server with the link's access token so it does not depend on the browser
// session surviving, nor on Supabase's "secure password change" re-authentication rule
// (which rejected brand-new invited users with an error the page could not explain).
// The token is verified first, and ONLY that token's own account can be changed.
export async function setPasswordFromLink(accessToken: string, password: string): Promise<{ error: string | null; email?: string }> {
  if (!accessToken) return { error: "انتهت الجلسة أو الرابط. اطلب رابطًا جديدًا." };
  if (!isPasswordAcceptable(password ?? "")) return { error: `كلمة المرور قصيرة جدًا — يجب ألا تقل عن ${MIN_PASSWORD_LENGTH} أحرف.` };

  let admin;
  try {
    admin = createAdminClient();
  } catch (e) {
    return { error: e instanceof Error ? e.message : "تعذّر إعداد الاتصال بالخادم" };
  }

  const { data, error } = await admin.auth.getUser(accessToken);
  if (error || !data.user) return { error: "انتهت صلاحية الرابط أو الجلسة. اطلب رابطًا جديدًا." };

  const { error: updateError } = await admin.auth.admin.updateUserById(data.user.id, { password, email_confirm: true });
  if (updateError) return { error: translateAuthError(updateError.message, (updateError as { code?: string }).code, (updateError as { reasons?: string[] }).reasons) };

  return { error: null, email: data.user.email ?? undefined };
}
