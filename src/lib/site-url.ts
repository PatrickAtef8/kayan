// The public address of the site, used to build the link inside invitation emails.
// Order: NEXT_PUBLIC_SITE_URL (set this) → Vercel's production URL (set automatically on Vercel) → localhost, but ONLY
// outside production — in production a missing address would send people a link that points at localhost.
export function getSiteUrl(env: Record<string, string | undefined> = process.env): string {
  const clean = (u: string) => u.trim().replace(/\/+$/, "");
  const explicit = env.NEXT_PUBLIC_SITE_URL?.trim();
  if (explicit) return clean(/^https?:\/\//i.test(explicit) ? explicit : `https://${explicit}`);
  const vercel = env.VERCEL_PROJECT_PRODUCTION_URL?.trim();
  if (vercel) return clean(`https://${vercel.replace(/^https?:\/\//i, "")}`);
  if (env.NODE_ENV === "production") {
    throw new Error("NEXT_PUBLIC_SITE_URL غير مضبوط — أضفه في متغيرات البيئة (مثال: https://your-project.vercel.app) ثم أعد النشر، وإلا ستشير روابط الدعوة إلى localhost.");
  }
  return "http://localhost:3000";
}

// Turns Supabase's English email errors into something the owner can act on.
export function explainInviteError(message: string): string {
  const m = message.toLowerCase();
  if (m.includes("rate limit") || m.includes("too many")) return "تم تجاوز حد إرسال الإيميلات في Supabase. فعّل Custom SMTP (Authentication → Emails → SMTP Settings) أو انتظر ساعة ثم أعد المحاولة.";
  if (m.includes("not authorized") || m.includes("not allowed") || m.includes("address not")) return "خدمة البريد الافتراضية في Supabase لا ترسل إلا لأعضاء فريق المشروع. فعّل Custom SMTP (مثل Gmail أو Resend أو Brevo) من Authentication → Emails → SMTP Settings.";
  if (m.includes("already") && m.includes("registered")) return "هذا البريد مسجّل بالفعل في Supabase — أعد إضافته من الفريق وسيظهر له طلب الانضمام عند تسجيل الدخول.";
  if (m.includes("smtp") || m.includes("sending") || m.includes("error sending")) return `تعذّر إرسال الإيميل من إعدادات SMTP: ${message}`;
  return message;
}
