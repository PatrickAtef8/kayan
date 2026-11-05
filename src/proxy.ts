import { NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/middleware";
import { buildCsp, generateNonce } from "@/lib/security/csp";

// Next.js 16 renamed "middleware" to "proxy" (runs on the Node.js runtime).
// Besides the session refresh it issues a per-request nonce and a nonce-based Content-Security-Policy in REPORT-ONLY mode (see
// src/lib/security/csp.ts and docs/SECURITY_HEADERS.md). Next.js reads the nonce from the request header and stamps its own scripts with it.
export async function proxy(request: NextRequest) {
  const nonce = generateNonce();
  const sentryHost = (() => { try { return process.env.NEXT_PUBLIC_SENTRY_DSN ? `https://${new URL(process.env.NEXT_PUBLIC_SENTRY_DSN).host}` : null; } catch { return null; } })();
  const csp = buildCsp({ nonce, supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL, isDev: process.env.NODE_ENV !== "production", extraConnect: sentryHost ? [sentryHost] : [] });

  const headers = new Headers(request.headers);
  headers.set("x-nonce", nonce);
  headers.set("content-security-policy-report-only", csp);
  const response = await updateSession(new NextRequest(request, { headers }));
  response.headers.set("Content-Security-Policy-Report-Only", csp);
  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|api/health|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)"],
};
