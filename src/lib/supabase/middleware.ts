import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

type CookieToSet = { name: string; value: string; options: CookieOptions };

// Refreshes the auth session on every request and redirects unauthenticated
// users away from the dashboard. This is the FIRST layer of protection;
// the real, unbypassable layer is Postgres RLS (0001_foundation.sql).
export async function updateSession(request: NextRequest) {
  // The dashboard layout (the payment gate) must know which page is being opened so that an unpaid owner can still reach
  // the billing pages. A layout cannot read the URL by itself, so it is handed over here. It is always SET (never
  // appended), so a value sent by a browser is overwritten and cannot be used to skip the gate.
  request.headers.set("x-kayan-path", request.nextUrl.pathname);
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet: CookieToSet[]) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        },
      },
    }
  );

  // getClaims() refreshes an expired session (cookies are rewritten through setAll above) and verifies the JWT
  // locally when the project uses asymmetric signing keys — one Auth round trip less per request. On a legacy
  // symmetric-secret project it falls back to getUser(), i.e. the previous behaviour.
  const { data: claimsData } = await supabase.auth.getClaims();
  const user = claimsData?.claims?.sub ? claimsData.claims : null;

  const isDashboardRoute = request.nextUrl.pathname.startsWith("/dashboard") || request.nextUrl.pathname.startsWith("/checkout");

  if (!user && isDashboardRoute) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    return NextResponse.redirect(url);
  }

  return response;
}
