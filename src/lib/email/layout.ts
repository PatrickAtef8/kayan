// The one shared HTML shell for every Kayan email. Templates (templates.ts) only supply the content blocks; header, typography,
// button, footer and RTL/LTR handling live here, so all emails look like one product.
//
// Email-client rules this file follows: table layout, inline styles only, no remote images / web fonts / scripts (nothing to be
// blocked, nothing that can leak that a message was opened), system font stack with Arabic-capable fallbacks, 600px max width, a
// "bulletproof" button made of a table cell so it renders in Outlook too.

export type Locale = "ar" | "en";

export const BRAND = {
  name: { ar: "كيان", en: "Kayan" },
  tagline: { ar: "إدارة الأعمال بوضوح", en: "Business management, made clear" },
  sage: "#344E41",
  sageSoft: "#E7EDE8",
  paper: "#F7F6F2",
  ink: "#1C1C1A",
  line: "#E5E3DD",
  muted: "#6B6B66",
  rose: "#9C4F45",
  amberBg: "#FBF3E4",
  amberInk: "#7A5A1E",
} as const;

const FONT = "'IBM Plex Sans Arabic','Segoe UI',Tahoma,Arial,'Helvetica Neue',Helvetica,sans-serif";

export function escapeHtml(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

/** Only absolute http(s) URLs may become links (blocks javascript:, data:, relative and malformed values). */
export function safeUrl(url: unknown): string | null {
  if (typeof url !== "string") return null;
  const u = url.trim();
  if (!u || /[\s<>"']/.test(u)) return null;
  try {
    const parsed = new URL(u);
    return parsed.protocol === "https:" || parsed.protocol === "http:" ? parsed.toString() : null;
  } catch {
    return null;
  }
}

export type Block =
  | { type: "p"; text: string }
  | { type: "note"; text: string; tone?: "info" | "warn" }
  | { type: "facts"; rows: { label: string; value: string }[] };

export type LayoutInput = {
  locale: Locale;
  /** Hidden inbox preview text. */
  preheader: string;
  heading: string;
  blocks: Block[];
  cta?: { label: string; url: string };
  /** Small print under the button (e.g. "this link expires..."). */
  afterCta?: string;
  /** Shown in the footer so people know why they got the message. */
  reason: string;
  siteUrl?: string | null;
  supportEmail?: string | null;
  /** Skip URL validation for the CTA — ONLY for the Supabase dashboard templates, whose URL is a {{ .Placeholder }}. */
  trustedPlaceholderUrl?: boolean;
};

function blockHtml(b: Block, dir: "rtl" | "ltr"): string {
  const align = dir === "rtl" ? "right" : "left";
  if (b.type === "p") return `<p style="margin:0 0 16px 0;font-size:15px;line-height:26px;color:${BRAND.ink};text-align:${align};">${escapeHtml(b.text)}</p>`;
  if (b.type === "note") {
    const warn = b.tone === "warn";
    return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 16px 0;"><tr><td style="background:${warn ? BRAND.amberBg : BRAND.sageSoft};border-${dir === "rtl" ? "right" : "left"}:3px solid ${warn ? "#C99A3E" : BRAND.sage};padding:12px 16px;font-size:14px;line-height:23px;color:${warn ? BRAND.amberInk : BRAND.sage};text-align:${align};">${escapeHtml(b.text)}</td></tr></table>`;
  }
  const rows = b.rows
    .map((r) => `<tr><td style="padding:9px 0;border-bottom:1px solid ${BRAND.line};font-size:13px;color:${BRAND.muted};text-align:${align};">${escapeHtml(r.label)}</td><td style="padding:9px 0;border-bottom:1px solid ${BRAND.line};font-size:14px;font-weight:600;color:${BRAND.ink};text-align:${dir === "rtl" ? "left" : "right"};" dir="auto">${escapeHtml(r.value)}</td></tr>`)
    .join("");
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px 0;">${rows}</table>`;
}

export function renderLayout(input: LayoutInput): { html: string; text: string } {
  const dir = input.locale === "ar" ? "rtl" : "ltr";
  const align = dir === "rtl" ? "right" : "left";
  const brand = BRAND.name[input.locale];
  const ctaUrl = input.cta ? (input.trustedPlaceholderUrl ? input.cta.url : safeUrl(input.cta.url)) : null;
  const site = input.siteUrl ? safeUrl(input.siteUrl) : null;

  const button = input.cta && ctaUrl
    ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 22px 0;"><tr><td align="center" bgcolor="${BRAND.sage}" style="border-radius:10px;"><a href="${input.trustedPlaceholderUrl ? ctaUrl : escapeHtml(ctaUrl)}" target="_blank" style="display:inline-block;padding:14px 30px;font-family:${FONT};font-size:15px;font-weight:700;color:#FFFFFF;text-decoration:none;border-radius:10px;">${escapeHtml(input.cta.label)}</a></td></tr></table>`
    : "";
  const fallbackLink = input.cta && ctaUrl
    ? `<p style="margin:0 0 6px 0;font-size:12px;line-height:20px;color:${BRAND.muted};text-align:${align};">${input.locale === "ar" ? "إذا لم يعمل الزر، انسخ هذا الرابط والصقه في المتصفح:" : "If the button does not work, copy this link into your browser:"}</p><p dir="ltr" style="margin:0 0 20px 0;font-size:12px;line-height:19px;word-break:break-all;color:${BRAND.sage};text-align:left;">${input.trustedPlaceholderUrl ? ctaUrl : escapeHtml(ctaUrl)}</p>`
    : "";
  const after = input.afterCta ? `<p style="margin:0 0 16px 0;font-size:13px;line-height:22px;color:${BRAND.muted};text-align:${align};">${escapeHtml(input.afterCta)}</p>` : "";
  const support = input.supportEmail && isSimpleAddress(input.supportEmail)
    ? `<br>${input.locale === "ar" ? "للمساعدة:" : "Need help?"} <a href="mailto:${escapeHtml(input.supportEmail)}" style="color:${BRAND.sage};text-decoration:underline;">${escapeHtml(input.supportEmail)}</a>`
    : "";

  const html = `<!doctype html>
<html lang="${input.locale}" dir="${dir}" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only">
<meta name="supported-color-schemes" content="light">
<title>${escapeHtml(input.heading)}</title>
</head>
<body style="margin:0;padding:0;background:${BRAND.paper};font-family:${FONT};-webkit-text-size-adjust:100%;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;mso-hide:all;">${escapeHtml(input.preheader)}&#8199;&#847;&#8199;&#847;&#8199;&#847;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${BRAND.paper};">
<tr><td align="center" style="padding:32px 14px;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;">
    <tr><td style="padding:0 4px 18px 4px;text-align:${align};">
      <table role="presentation" cellpadding="0" cellspacing="0" dir="${dir}"><tr>
        <td style="width:40px;height:40px;background:${BRAND.sage};border-radius:10px;text-align:center;vertical-align:middle;font-family:${FONT};font-size:22px;font-weight:700;line-height:40px;color:#FFFFFF;">${input.locale === "ar" ? "ك" : "K"}</td>
        <td style="padding:0 12px;vertical-align:middle;font-family:${FONT};"><div style="font-size:19px;font-weight:700;color:${BRAND.ink};line-height:22px;">${escapeHtml(brand)}</div><div style="font-size:12px;color:${BRAND.muted};line-height:18px;">${escapeHtml(BRAND.tagline[input.locale])}</div></td>
      </tr></table>
    </td></tr>
    <tr><td style="background:#FFFFFF;border:1px solid ${BRAND.line};border-radius:14px;padding:34px 30px;font-family:${FONT};" dir="${dir}">
      <h1 style="margin:0 0 18px 0;font-size:22px;line-height:32px;font-weight:700;color:${BRAND.ink};text-align:${align};">${escapeHtml(input.heading)}</h1>
      ${input.blocks.map((b) => blockHtml(b, dir)).join("\n      ")}
      ${button}
      ${fallbackLink}
      ${after}
    </td></tr>
    <tr><td style="padding:20px 8px 0 8px;font-family:${FONT};font-size:12px;line-height:20px;color:${BRAND.muted};text-align:${align};" dir="${dir}">
      ${escapeHtml(input.reason)}${support}
      <br><span style="color:#A3A39D;">${escapeHtml(brand)}${site ? ` · <a href="${escapeHtml(site)}" style="color:#A3A39D;text-decoration:underline;">${escapeHtml(new URL(site).host)}</a>` : ""}</span>
    </td></tr>
  </table>
</td></tr>
</table>
</body>
</html>`;

  const lines: string[] = [input.heading, ""];
  for (const b of input.blocks) {
    if (b.type === "facts") for (const r of b.rows) lines.push(`${r.label}: ${r.value}`);
    else lines.push(b.text);
    lines.push("");
  }
  if (input.cta && ctaUrl) lines.push(`${input.cta.label}:`, ctaUrl, "");
  if (input.afterCta) lines.push(input.afterCta, "");
  lines.push("--", input.reason, brand);
  return { html, text: lines.join("\n") };
}

function isSimpleAddress(v: string): boolean {
  return /^[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(v);
}
