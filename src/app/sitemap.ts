import type { MetadataRoute } from "next";
import { getSiteUrl } from "@/lib/site-url";

// Only the public marketing / legal pages. Private areas (/dashboard, /admin, /checkout) are deliberately absent.
export default function sitemap(): MetadataRoute.Sitemap {
  let base: string;
  try { base = getSiteUrl(); } catch { return []; }
  const pages: [string, number][] = [["/", 1], ["/pricing", 0.9], ["/signup", 0.8], ["/login", 0.5], ["/contact", 0.5], ["/terms", 0.3], ["/privacy", 0.3], ["/refund-policy", 0.3]];
  return pages.map(([path, priority]) => ({ url: `${base}${path}`, priority }));
}
