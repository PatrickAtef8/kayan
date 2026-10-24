import { NextResponse, type NextRequest } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/server";

// Landing point of the "confirm your email" link sent after signup. It turns the code in the
// link into a session and sends the person to the dashboard, where the company they entered
// at signup is created automatically (see src/app/dashboard/layout.tsx).
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type") as EmailOtpType | null;

  const supabase = await createClient();
  let ok = false;
  if (code) {
    ok = !(await supabase.auth.exchangeCodeForSession(code)).error;
  } else if (tokenHash && type) {
    ok = !(await supabase.auth.verifyOtp({ type, token_hash: tokenHash })).error;
  }

  // Opened on another device/browser than the one used to sign up: the link cannot start a session
  // there, but the email IS confirmed by then, so a normal login works.
  return NextResponse.redirect(`${origin}${ok ? "/dashboard" : "/login?confirmed=1"}`);
}
