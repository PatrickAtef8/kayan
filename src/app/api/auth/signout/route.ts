import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { isSameOriginRequest } from "@/lib/request-origin";

export async function POST(request: Request) {
  // a form on another site must not be able to sign the person out (the session cookie is SameSite=Lax too; this is the second barrier)
  if (!isSameOriginRequest(request.headers, request.url)) return new NextResponse("Forbidden", { status: 403 });
  const supabase = await createClient();
  await supabase.auth.signOut();
  // 303 (See Other): the browser follows with a GET. The default 307 would repeat the POST against /login.
  return NextResponse.redirect(new URL("/login", request.url), 303);
}
