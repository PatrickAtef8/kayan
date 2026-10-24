// Password guidance shown while typing (signup / reset). Only the minimum length is REQUIRED;
// the other checks are advisory so people are nudged toward a strong password without rigid rules.
export const MIN_PASSWORD_LENGTH = 8;

export type PasswordCheck = { id: "length" | "case" | "number" | "symbol"; label: string; ok: boolean; required: boolean };

const COMMON = new Set(["12345678", "123456789", "1234567890", "11111111", "00000000", "password", "password1", "qwertyui", "qwerty123", "iloveyou", "abc12345", "12341234"]);

export function passwordChecks(p: string): PasswordCheck[] {
  return [
    { id: "length", label: `${MIN_PASSWORD_LENGTH} أحرف على الأقل`, ok: p.length >= MIN_PASSWORD_LENGTH, required: true },
    { id: "case", label: "حروف كبيرة وصغيرة", ok: /[a-z]/.test(p) && /[A-Z]/.test(p), required: false },
    { id: "number", label: "رقم واحد على الأقل", ok: /\d/.test(p), required: false },
    { id: "symbol", label: "رمز خاص (مثل ! @ #)", ok: /[^A-Za-z0-9\u0600-\u06FF\s]/.test(p), required: false },
  ];
}

export type PasswordStrength = { score: 0 | 1 | 2 | 3 | 4; label: string };

export function passwordStrength(p: string): PasswordStrength {
  if (!p) return { score: 0, label: "" };
  const labels = ["", "ضعيفة", "مقبولة", "جيدة", "قوية"] as const;
  if (p.length < MIN_PASSWORD_LENGTH || COMMON.has(p.toLowerCase())) return { score: 1, label: labels[1] };
  const c = passwordChecks(p);
  const points = 1 + Number(c[1].ok) + Number(c[2].ok) + Number(c[3].ok || p.length >= 14);
  const score = Math.min(4, points) as 1 | 2 | 3 | 4;
  return { score, label: labels[score] };
}

export function isPasswordAcceptable(p: string): boolean {
  return p.length >= MIN_PASSWORD_LENGTH;
}
