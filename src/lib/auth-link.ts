// What an emailed Supabase link (invitation / password reset) carries when it lands on our page.
// Admin invitations come back with the session in the URL #hash (implicit style), which a PKCE browser client
// ignores — so the page reads it itself instead of waiting for an event that never fires.
export type AuthLink =
  | { kind: "session"; accessToken: string; refreshToken: string; type: string | null }
  | { kind: "token_hash"; tokenHash: string; type: "invite" | "recovery" | "signup" | "magiclink" | "email" }
  | { kind: "error"; message: string; code: string | null }
  | { kind: "none" };

const OTP_TYPES = ["invite", "recovery", "signup", "magiclink", "email"] as const;

export function parseAuthLink(search: string, hash: string): AuthLink {
  const q = new URLSearchParams(search.replace(/^\?/, ""));
  const h = new URLSearchParams(hash.replace(/^#/, ""));
  const get = (k: string) => h.get(k) ?? q.get(k);

  const err = get("error_description") ?? get("error");
  if (err) return { kind: "error", message: err.replace(/\+/g, " "), code: get("error_code") };

  const access = h.get("access_token");
  const refresh = h.get("refresh_token");
  if (access && refresh) return { kind: "session", accessToken: access, refreshToken: refresh, type: h.get("type") };

  const tokenHash = q.get("token_hash");
  const type = q.get("type");
  if (tokenHash && type && (OTP_TYPES as readonly string[]).includes(type)) return { kind: "token_hash", tokenHash, type: type as (typeof OTP_TYPES)[number] };

  return { kind: "none" };
}

export function explainLinkError(code: string | null, message: string): string {
  const m = `${code ?? ""} ${message}`.toLowerCase();
  if (m.includes("expired") || m.includes("otp_expired")) return "انتهت صلاحية الرابط، أو تم فتحه من قبل (بعض برامج حماية البريد تفتح الروابط تلقائيًا). اطلب رابطًا جديدًا.";
  if (m.includes("access_denied")) return "الرابط غير صالح أو استُخدم من قبل. اطلب رابطًا جديدًا.";
  return message;
}
