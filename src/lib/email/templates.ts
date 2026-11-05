// Every email Kayan sends, as data → { subject, html, text }. One registry, one layout (layout.ts): adding an email means adding a
// builder here, never a separate hand-written HTML design. Arabic (RTL) is the default; English is supported for every template.

import { renderLayout, type Block, type Locale } from "./layout.ts";

export type { Locale } from "./layout.ts";

export type TemplateData = {
  /** A brand-new person is invited to a company (they have to set a password first). */
  team_invite: { orgName: string; roleName: string; inviterName?: string | null; link: string };
  /** An existing Kayan user is invited to a company: they sign in and accept on /invites. */
  team_invite_existing: { orgName: string; roleName: string; inviterName?: string | null; link: string };
  password_reset: { link: string };
  subscription_reminder: {
    orgName: string;
    /** whole days until the licence ends; 0 = ends today; negative = already ended */
    daysLeft: number;
    /** YYYY-MM-DD */
    endsOn: string;
    packageName?: string | null;
    renewUrl: string;
  };
  payment_receipt: { orgName: string; packageName: string; amountLabel: string; paidOn: string; reference: string; periodEnd?: string | null; billingUrl: string };
  payment_needs_review: { orgName: string; amountLabel: string; reference: string; billingUrl: string };
};

export type TemplateName = keyof TemplateData;
export type Rendered = { subject: string; html: string; text: string };

export type RenderContext = { locale?: Locale; siteUrl?: string | null; supportEmail?: string | null };

const T = <K extends TemplateName>(
  build: (d: TemplateData[K], l: Locale) => { subject: string; preheader: string; heading: string; blocks: Block[]; cta?: { label: string; url: string }; afterCta?: string; reason: string },
) => build;

const ar = (l: Locale) => l === "ar";

const builders: { [K in TemplateName]: ReturnType<typeof T<K>> } = {
  team_invite: T<"team_invite">((d, l) => ({
    subject: ar(l) ? `دعوة للانضمام إلى ${d.orgName} على كيان` : `You're invited to join ${d.orgName} on Kayan`,
    preheader: ar(l) ? `تمت دعوتك للعمل مع ${d.orgName}. اضبط كلمة المرور لتبدأ.` : `You've been invited to work with ${d.orgName}. Set a password to get started.`,
    heading: ar(l) ? "تمت دعوتك للانضمام إلى فريق العمل" : "You've been invited to join the team",
    blocks: [
      { type: "p", text: ar(l) ? `${d.inviterName ? `دعاك ${d.inviterName}` : "تمت دعوتك"} للانضمام إلى «${d.orgName}» على كيان، منصة إدارة الأعمال.` : `${d.inviterName ? `${d.inviterName} has invited you` : "You have been invited"} to join “${d.orgName}” on Kayan, the business management platform.` },
      { type: "facts", rows: [{ label: ar(l) ? "الشركة" : "Company", value: d.orgName }, { label: ar(l) ? "دورك" : "Your role", value: d.roleName }] },
      { type: "p", text: ar(l) ? "اضغط على الزر لاختيار كلمة مرور وبدء العمل." : "Use the button below to choose a password and get started." },
    ],
    cta: { label: ar(l) ? "قبول الدعوة وتعيين كلمة المرور" : "Accept invitation & set password", url: d.link },
    afterCta: ar(l) ? "الرابط خاص بك وصالح لفترة محدودة. لا تشاركه مع أحد." : "This link is personal to you and valid for a limited time. Please do not share it.",
    reason: ar(l) ? "وصلتك هذه الرسالة لأن مدير شركة أضاف بريدك الإلكتروني إلى فريقه على كيان. إذا لم تكن تتوقعها فتجاهلها." : "You received this email because a company administrator added your address to their team on Kayan. If you were not expecting it, you can ignore it.",
  })),

  team_invite_existing: T<"team_invite_existing">((d, l) => ({
    subject: ar(l) ? `دعوة جديدة للانضمام إلى ${d.orgName}` : `New invitation to join ${d.orgName}`,
    preheader: ar(l) ? `سجّل الدخول لقبول الدعوة إلى ${d.orgName}.` : `Sign in to accept your invitation to ${d.orgName}.`,
    heading: ar(l) ? "لديك دعوة جديدة على كيان" : "You have a new invitation on Kayan",
    blocks: [
      { type: "p", text: ar(l) ? `${d.inviterName ? `دعاك ${d.inviterName}` : "تمت دعوتك"} للانضمام إلى «${d.orgName}». لديك حساب على كيان بالفعل، فسجّل الدخول وستجد الدعوة بانتظارك.` : `${d.inviterName ? `${d.inviterName} has invited you` : "You have been invited"} to join “${d.orgName}”. You already have a Kayan account — sign in and the invitation will be waiting for you.` },
      { type: "facts", rows: [{ label: ar(l) ? "الشركة" : "Company", value: d.orgName }, { label: ar(l) ? "الدور" : "Role", value: d.roleName }] },
    ],
    cta: { label: ar(l) ? "عرض الدعوة" : "View invitation", url: d.link },
    reason: ar(l) ? "وصلتك هذه الرسالة لأن مدير شركة أضاف بريدك الإلكتروني إلى فريقه على كيان. إذا لم تكن تتوقعها فتجاهلها." : "You received this email because a company administrator added your address to their team on Kayan. If you were not expecting it, you can ignore it.",
  })),

  password_reset: T<"password_reset">((d, l) => ({
    subject: ar(l) ? "إعادة تعيين كلمة المرور — كيان" : "Reset your Kayan password",
    preheader: ar(l) ? "اضغط لاختيار كلمة مرور جديدة." : "Choose a new password for your account.",
    heading: ar(l) ? "إعادة تعيين كلمة المرور" : "Reset your password",
    blocks: [
      { type: "p", text: ar(l) ? "تلقينا طلبًا لإعادة تعيين كلمة مرور حسابك على كيان. اضغط على الزر أدناه لاختيار كلمة مرور جديدة." : "We received a request to reset the password of your Kayan account. Use the button below to choose a new one." },
      { type: "note", tone: "warn", text: ar(l) ? "إذا لم تطلب ذلك، تجاهل هذه الرسالة — لن يتغيّر شيء في حسابك." : "If you did not request this, ignore this email — nothing will change on your account." },
    ],
    cta: { label: ar(l) ? "اختيار كلمة مرور جديدة" : "Choose a new password", url: d.link },
    afterCta: ar(l) ? "الرابط صالح لفترة محدودة ويُستخدم مرة واحدة." : "The link is valid for a limited time and works once.",
    reason: ar(l) ? "وصلتك هذه الرسالة لأن شخصًا طلب إعادة تعيين كلمة المرور لهذا البريد." : "You received this email because a password reset was requested for this address.",
  })),

  subscription_reminder: T<"subscription_reminder">((d, l) => {
    const ended = d.daysLeft < 0;
    const today = d.daysLeft === 0;
    const pkg = d.packageName ? (ar(l) ? ` (باقة ${d.packageName})` : ` (${d.packageName} package)`) : "";
    const when = ended
      ? ar(l) ? "انتهى اشتراك شركتك" : "Your company's subscription has ended"
      : today ? (ar(l) ? "ينتهي اشتراك شركتك اليوم" : "Your company's subscription ends today")
      : ar(l) ? `ينتهي اشتراك شركتك خلال ${d.daysLeft} ${d.daysLeft === 1 ? "يوم" : d.daysLeft <= 10 ? "أيام" : "يومًا"}` : `Your company's subscription ends in ${d.daysLeft} day${d.daysLeft === 1 ? "" : "s"}`;
    return {
      subject: ended ? (ar(l) ? `انتهى اشتراك ${d.orgName} — جدّد للاستمرار` : `${d.orgName}'s subscription has ended — renew to continue`) : (ar(l) ? `تذكير: ${when} — ${d.orgName}` : `Reminder: ${when} — ${d.orgName}`),
      preheader: ar(l) ? `تاريخ الانتهاء ${d.endsOn}. جدّد اشتراكك لتستمر بدون انقطاع.` : `Ends on ${d.endsOn}. Renew to keep working without interruption.`,
      heading: when,
      blocks: [
        { type: "p", text: ar(l) ? `اشتراك «${d.orgName}»${pkg} ${ended ? "انتهى" : "سينتهي"} بتاريخ ${d.endsOn}. ${ended ? "جدّد الاشتراك لاستعادة الوصول الكامل — بياناتك محفوظة." : "جدّد الآن لتستمر في العمل دون انقطاع."}` : `The subscription for “${d.orgName}”${pkg} ${ended ? "ended" : "ends"} on ${d.endsOn}. ${ended ? "Renew to restore full access — your data is safe." : "Renew now to keep working without interruption."}` },
        { type: "facts", rows: [{ label: ar(l) ? "الشركة" : "Company", value: d.orgName }, { label: ar(l) ? "تاريخ الانتهاء" : "End date", value: d.endsOn }] },
        { type: "note", text: ar(l) ? "التجديد يدوي: ادفع من صفحة الاشتراك داخل كيان. لا يتم خصم أي مبلغ تلقائيًا." : "Renewal is manual: pay from the billing page inside Kayan. Nothing is charged automatically." },
      ],
      cta: { label: ar(l) ? "تجديد الاشتراك" : "Renew subscription", url: d.renewUrl },
      reason: ar(l) ? "أرسلنا هذه الرسالة إلى مالك الشركة لأن اشتراكها يقترب من الانتهاء." : "We sent this email to the company owner because the subscription is about to end.",
    };
  }),

  payment_receipt: T<"payment_receipt">((d, l) => ({
    subject: ar(l) ? `تم استلام دفعتك — ${d.orgName}` : `Payment received — ${d.orgName}`,
    preheader: ar(l) ? `شكرًا لك. تم تأكيد دفعة ${d.amountLabel}.` : `Thank you. Your payment of ${d.amountLabel} is confirmed.`,
    heading: ar(l) ? "تم تأكيد الدفع" : "Payment confirmed",
    blocks: [
      { type: "p", text: ar(l) ? `شكرًا لك. تم تأكيد دفعتك لشركة «${d.orgName}».` : `Thank you. Your payment for “${d.orgName}” is confirmed.` },
      { type: "facts", rows: [
        { label: ar(l) ? "الباقة" : "Package", value: d.packageName },
        { label: ar(l) ? "المبلغ" : "Amount", value: d.amountLabel },
        { label: ar(l) ? "تاريخ الدفع" : "Paid on", value: d.paidOn },
        ...(d.periodEnd ? [{ label: ar(l) ? "الاشتراك ساري حتى" : "Active until", value: d.periodEnd }] : []),
        { label: ar(l) ? "رقم المرجع" : "Reference", value: d.reference },
      ] },
    ],
    cta: { label: ar(l) ? "عرض صفحة الاشتراك" : "View billing", url: d.billingUrl },
    reason: ar(l) ? "هذا إشعار آلي بدفعة تمت على حساب شركتك في كيان." : "This is an automatic notice about a payment made for your company on Kayan.",
  })),

  payment_needs_review: T<"payment_needs_review">((d, l) => ({
    subject: ar(l) ? `دفعتك قيد المراجعة — ${d.orgName}` : `Your payment is under review — ${d.orgName}`,
    preheader: ar(l) ? "سجّلنا دفعتك وسيراجعها فريق كيان." : "We recorded your payment and the Kayan team will review it.",
    heading: ar(l) ? "دفعتك قيد المراجعة" : "Your payment is under review",
    blocks: [
      { type: "p", text: ar(l) ? `سجّلنا دفعتك لشركة «${d.orgName}»، لكنها تحتاج إلى تأكيد إضافي من فريق كيان. لن تضيع منها شيء، وسنتواصل معك عند الانتهاء.` : `We recorded your payment for “${d.orgName}”, but it needs an extra confirmation from the Kayan team. Nothing is lost and we will follow up once it is done.` },
      { type: "facts", rows: [{ label: ar(l) ? "المبلغ" : "Amount", value: d.amountLabel }, { label: ar(l) ? "رقم المرجع" : "Reference", value: d.reference }] },
    ],
    cta: { label: ar(l) ? "عرض صفحة الاشتراك" : "View billing", url: d.billingUrl },
    reason: ar(l) ? "هذا إشعار آلي بدفعة تمت على حساب شركتك في كيان." : "This is an automatic notice about a payment made for your company on Kayan.",
  })),
};

export const TEMPLATE_NAMES = Object.keys(builders) as TemplateName[];

export function renderTemplate<K extends TemplateName>(name: K, data: TemplateData[K], ctx: RenderContext = {}): Rendered {
  const locale: Locale = ctx.locale === "en" ? "en" : "ar";
  const b = (builders[name] as (d: TemplateData[K], l: Locale) => ReturnType<ReturnType<typeof T>>)(data, locale);
  const { html, text } = renderLayout({
    locale,
    preheader: b.preheader,
    heading: b.heading,
    blocks: b.blocks,
    cta: b.cta,
    afterCta: b.afterCta,
    reason: b.reason,
    siteUrl: ctx.siteUrl ?? null,
    supportEmail: ctx.supportEmail ?? null,
  });
  return { subject: b.subject.replace(/[\r\n]+/g, " ").slice(0, 200), html, text };
}
