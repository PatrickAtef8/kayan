import type { Metadata } from "next";
import { getSiteUrl } from "@/lib/site-url";
import { IBM_Plex_Sans_Arabic } from "next/font/google";
import "./globals.css";

// next/font/google downloads the font files once at build time and serves
// them from this app's own domain from then on — it does NOT add a
// runtime dependency on Google Fonts (that's the whole point of the
// next/font system, vs. a <link> tag which would). If a fully offline/
// firewalled build environment genuinely can't reach Google during
// `next build`, self-hosted .woff2 files via next/font/local are the
// fallback — but that's a different problem than the one a system-font
// fallback (Tahoma) solves, and it reintroduces the exact "looks cheap"
// issue that was the original bug report on this project.
const arabicFont = IBM_Plex_Sans_Arabic({
  subsets: ["arabic"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-arabic",
  display: "swap",
});

const TITLE = "كيان — إدارة الأعمال";
const DESCRIPTION = "كيان نظام لإدارة الأعمال للشركات الصغيرة والمتوسطة: المبيعات والمشتريات والمخزون والخزنة والمناديب في مكان واحد، وكل رقم له مصدر.";
// Link preview (WhatsApp, Facebook, Telegram, X…): a 1200×630 image kept in /public. metadataBase (below) turns this into the absolute URL those apps need.
const OG_IMAGE = { url: "/og-image.png", width: 1200, height: 630, alt: "كيان — شركتك كلها في شاشة واحدة" };
const siteUrl = (() => { try { return getSiteUrl(); } catch { return null; } })();

export const metadata: Metadata = {
  ...(siteUrl ? { metadataBase: new URL(siteUrl) } : {}),
  title: { default: TITLE, template: "%s | كيان" },
  description: DESCRIPTION,
  applicationName: "Kayan",
  openGraph: { type: "website", locale: "ar_EG", siteName: "كيان", title: TITLE, description: DESCRIPTION, url: "/", images: [OG_IMAGE] },
  twitter: { card: "summary_large_image", title: TITLE, description: DESCRIPTION, images: [OG_IMAGE.url] },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ar" dir="rtl" className={arabicFont.variable} data-scroll-behavior="smooth" suppressHydrationWarning>
      <body className="font-arabic antialiased leading-relaxed">{children}</body>
    </html>
  );
}
