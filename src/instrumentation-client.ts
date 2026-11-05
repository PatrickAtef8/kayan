import * as Sentry from "@sentry/browser";
import { scrubEvent } from "@/lib/monitoring/scrub";

// Browser-side error reporting. Needs NEXT_PUBLIC_SENTRY_DSN (a DSN is a write-only ingest address, safe to expose). Nothing is sent without it.
// Note: events go straight to Sentry's ingest host; the proxy already adds that host to the (report-only) CSP connect-src.
const dsn = process.env.NEXT_PUBLIC_SENTRY_DSN;
if (dsn) {
  Sentry.init({ dsn, environment: process.env.NEXT_PUBLIC_VERCEL_ENV ?? process.env.NODE_ENV, sendDefaultPii: false, tracesSampleRate: 0, beforeSend: (event) => scrubEvent(event as never) as never });
}
