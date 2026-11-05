/** @type {import('next').NextConfig} */

// Enforced here: clickjacking, MIME sniffing, referrer leakage, HSTS, and the directives that cannot break a page.
// The full script/style/connect policy is NOT static any more: it carries a per-request nonce, so src/proxy.ts builds it
// (src/lib/security/csp.ts) and sends it as Content-Security-Policy-Report-Only. Enforcing it is a deliberate, tested step — docs/SECURITY_HEADERS.md.
const securityHeaders = [
  { key: "X-Frame-Options", value: "DENY" },
  // Enforced: the directives that cannot break a page (no framing, no <base> hijack, no plugins). The script/style/connect policy
  // below stays Report-Only: with 'unsafe-inline' scripts (Next's inline bootstrap) enforcing it would add little, and a nonce-based
  // policy needs a browser pass to be rolled out safely.
  { key: "Content-Security-Policy", value: "frame-ancestors 'none'; base-uri 'self'; object-src 'none'" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=()" },
  { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains" },
];

const nextConfig = {
  poweredByHeader: false,
  async headers() {
    return [
      { source: "/:path*", headers: securityHeaders },
      // belt and braces next to the <meta robots> of those layouts: private areas are never indexed
      ...["/admin/:path*", "/dashboard/:path*", "/checkout/:path*", "/api/:path*", "/auth/:path*", "/reset-password"].map((source) => ({ source, headers: [{ key: "X-Robots-Tag", value: "noindex, nofollow, noarchive" }] })),
    ];
  },
};

export default nextConfig;
