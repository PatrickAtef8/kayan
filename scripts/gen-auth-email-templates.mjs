// Generates the HTML for Supabase Auth's own emails (Authentication → Emails → Templates) from the SAME layout and brand as every
// email the app sends through Resend, so signup confirmation / magic link / email change look identical to invitations and receipts.
//
//   node --experimental-strip-types scripts/gen-auth-email-templates.mjs
//
// Output: supabase/email-templates/*.html (+ subjects.txt). Paste each file into the matching Supabase template and set the subject.
// The links point at THIS app (token_hash flow) — they use {{ .SiteURL }}, so Supabase → Authentication → URL Configuration → Site URL
// must be the production address. See docs/EMAIL.md.
import { mkdirSync, writeFileSync } from "node:fs";
import { renderLayout } from "../src/lib/email/layout.ts";

const out = new URL("../supabase/email-templates/", import.meta.url);
mkdirSync(out, { recursive: true });

const T = (file, subject, o) => {
  const { html } = renderLayout({ locale: "ar", reason: "أرسلنا هذه الرسالة لأن شخصًا استخدم هذا البريد في كيان. إذا لم تكن أنت، تجاهلها.", trustedPlaceholderUrl: true, ...o });
  writeFileSync(new URL(file, out), html);
  return `${file}\t${subject}`;
};

const subjects = [
  T("confirm-signup.html", "أكّد بريدك الإلكتروني — كيان", {
    preheader: "خطوة واحدة لتفعيل حسابك.", heading: "أكّد بريدك الإلكتروني",
    blocks: [{ type: "p", text: "مرحبًا بك في كيان. اضغط على الزر أدناه لتأكيد بريدك الإلكتروني وتفعيل حسابك." }],
    cta: { label: "تأكيد البريد الإلكتروني", url: "{{ .SiteURL }}/auth/callback?token_hash={{ .TokenHash }}&type=signup" },
    afterCta: "الرابط صالح لفترة محدودة.",
  }),
  T("invite.html", "تمت دعوتك للانضمام إلى كيان", {
    preheader: "اضبط كلمة المرور لتبدأ.", heading: "تمت دعوتك للانضمام إلى كيان",
    blocks: [{ type: "p", text: "تمت دعوتك للانضمام إلى فريق عمل على كيان. اضغط على الزر لاختيار كلمة مرور وبدء العمل." }],
    cta: { label: "قبول الدعوة وتعيين كلمة المرور", url: "{{ .SiteURL }}/reset-password?token_hash={{ .TokenHash }}&type=invite" },
    afterCta: "الرابط خاص بك وصالح لفترة محدودة. لا تشاركه مع أحد.",
  }),
  T("recovery.html", "إعادة تعيين كلمة المرور — كيان", {
    preheader: "اضغط لاختيار كلمة مرور جديدة.", heading: "إعادة تعيين كلمة المرور",
    blocks: [{ type: "p", text: "تلقينا طلبًا لإعادة تعيين كلمة مرور حسابك على كيان. اضغط على الزر لاختيار كلمة مرور جديدة." }, { type: "note", tone: "warn", text: "إذا لم تطلب ذلك، تجاهل هذه الرسالة — لن يتغيّر شيء في حسابك." }],
    cta: { label: "اختيار كلمة مرور جديدة", url: "{{ .SiteURL }}/reset-password?token_hash={{ .TokenHash }}&type=recovery" },
    afterCta: "الرابط صالح لفترة محدودة ويُستخدم مرة واحدة.",
  }),
  T("magic-link.html", "رابط تسجيل الدخول — كيان", {
    preheader: "اضغط لتسجيل الدخول.", heading: "تسجيل الدخول إلى كيان",
    blocks: [{ type: "p", text: "اضغط على الزر أدناه لتسجيل الدخول إلى حسابك." }],
    cta: { label: "تسجيل الدخول", url: "{{ .SiteURL }}/auth/callback?token_hash={{ .TokenHash }}&type=magiclink" },
    afterCta: "الرابط صالح لفترة محدودة ويُستخدم مرة واحدة.",
  }),
  T("email-change.html", "تأكيد تغيير البريد الإلكتروني — كيان", {
    preheader: "أكّد البريد الجديد لحسابك.", heading: "تأكيد تغيير البريد الإلكتروني",
    blocks: [{ type: "p", text: "طُلب تغيير البريد الإلكتروني لحسابك على كيان. اضغط على الزر لتأكيد التغيير." }, { type: "note", tone: "warn", text: "إذا لم تطلب ذلك، لا تضغط على الزر وغيّر كلمة مرورك فورًا." }],
    cta: { label: "تأكيد التغيير", url: "{{ .SiteURL }}/auth/callback?token_hash={{ .TokenHash }}&type=email_change" },
  }),
  T("reauthentication.html", "رمز التحقق — كيان", {
    preheader: "رمز التحقق الخاص بك.", heading: "رمز التحقق",
    blocks: [{ type: "p", text: "أدخل الرمز التالي لتأكيد العملية:" }, { type: "facts", rows: [{ label: "الرمز", value: "{{ .Token }}" }] }, { type: "note", tone: "warn", text: "لا تشارك هذا الرمز مع أحد." }],
  }),
];
writeFileSync(new URL("subjects.txt", out), subjects.join("\n") + "\n");
console.log(`wrote ${subjects.length} templates to supabase/email-templates/`);
