import type { MetadataRoute } from "next";
import { getSiteUrl } from "@/lib/site-url";

// Public pages may be indexed; every private area is disallowed (and also sends noindex — next.config.mjs + the layouts).
export default function robots(): MetadataRoute.Robots {
  let base: string | undefined;
  try { base = getSiteUrl(); } catch { base = undefined; }
  return {
    rules: [{ userAgent: "*", allow: "/", disallow: ["/admin", "/dashboard", "/checkout", "/api/", "/auth/", "/reset-password", "/invites"] }],
    ...(base ? { sitemap: `${base}/sitemap.xml`, host: base } : {}),
  };
}
