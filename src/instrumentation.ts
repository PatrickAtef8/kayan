import { scrubEvent } from "@/lib/monitoring/scrub";

// Server-side error monitoring (Sentry). Off unless SENTRY_DSN is set, so development and any environment without a DSN send nothing.
// Reports are scrubbed (src/lib/monitoring/scrub.ts) and no personal data is attached (sendDefaultPii: false).
// Only the plain @sentry/node SDK is used (not @sentry/nextjs): the Next.js package drags in a build-time bundler plugin whose dependencies
// currently carry `npm audit` findings, and Kayan does not upload source maps.
export async function register() {
  if (process.env.NEXT_RUNTIME !== "nodejs" || !process.env.SENTRY_DSN) return;
  const Sentry = await import("@sentry/node");
  Sentry.init({
    dsn: process.env.SENTRY_DSN,
    environment: process.env.VERCEL_ENV ?? process.env.NODE_ENV,
    sendDefaultPii: false,
    tracesSampleRate: 0,
    beforeSend: (event) => scrubEvent(event as never) as never,
  });
}

// Next.js calls this for every uncaught server-side error (Server Components, server actions, route handlers).
// Only the route PATTERN is attached — never the URL, which can carry a token_hash in its query string.
export async function onRequestError(err: unknown, _request: unknown, context: { routePath?: string; routeType?: string }) {
  if (process.env.NEXT_RUNTIME !== "nodejs" || !process.env.SENTRY_DSN) return;
  const Sentry = await import("@sentry/node");
  Sentry.withScope((scope) => {
    scope.setTag("route", context.routePath ?? "unknown");
    scope.setTag("routeType", context.routeType ?? "unknown");
    Sentry.captureException(err);
  });
}
