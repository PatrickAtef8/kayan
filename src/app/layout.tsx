import type { Metadata } from "next";
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

export const metadata: Metadata = {
  title: "كيان — إدارة الأعمال",
  description: "منصة إدارة أعمال متكاملة للشركات الصغيرة والمتوسطة",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ar" dir="rtl" className={arabicFont.variable} data-scroll-behavior="smooth" suppressHydrationWarning>
      <body className="font-arabic antialiased leading-relaxed">{children}</body>
    </html>
  );
}
