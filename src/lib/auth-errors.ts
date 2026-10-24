// Supabase Auth (and Postgres RPC) errors come back in English. This keeps
// the UI Arabic by mapping the known cases. For anything unrecognised it shows a
// generic Arabic message PLUS the original text, so the real cause is never hidden
// (previously every unknown error became the same unexplained sentence).
const KNOWN_PATTERNS: [RegExp, string][] = [
  [/email not confirmed|email_not_confirmed/i, "لم يتم تأكيد بريدك الإلكتروني بعد. افتح رسالة التأكيد المرسلة إليك واضغط الرابط، ثم سجّل الدخول."],
  [/already registered|user already exists/i, "هذا البريد الإلكتروني مسجّل بالفعل. جرّب تسجيل الدخول بدلاً من ذلك."],
  [/different from the old password|same_password/i, "كلمة المرور الجديدة مطابقة لكلمة المرور الحالية. اختر كلمة مرور مختلفة."],
  [/at least one character of each|should contain at least one/i, "كلمة المرور يجب أن تحتوي على حروف كبيرة وصغيرة وأرقام ورموز خاصة."],
  [/password should be at least|password.*(short|weak|characters?)/i, "كلمة المرور قصيرة جدًا — اختر كلمة مرور أطول (8 أحرف على الأقل يُفضّل)."],
  [/session missing|session_not_found|session from session_id claim|jwt expired|invalid jwt|invalid token|bad_jwt/i, "انتهت الجلسة أو الرابط. اطلب من مدير الفريق إعادة إرسال الدعوة، أو اطلب رابطًا جديدًا."],
  [/reauthentication|requires reauth/i, "تحتاج إلى إعادة تسجيل الدخول لتغيير كلمة المرور. اطلب رابطًا جديدًا."],
  [/invalid.*email|unable to validate email/i, "صيغة البريد الإلكتروني غير صحيحة."],
  [/rate limit|too many/i, "محاولات كثيرة جدًا خلال وقت قصير. برجاء المحاولة بعد قليل."],
  [/network|fetch failed/i, "تعذّر الاتصال بالخادم. تحقق من اتصال الإنترنت وحاول مجددًا."],
];

// Supabase answers every password-policy rejection with the SAME code ("weak_password") and puts the
// real cause in `reasons`: "length" (below the project's minimum), "characters" (missing required
// character types) or "pwned" (found in the public Have I Been Pwned breach list). Previously the code
// alone decided the message, so a too-short password was reported as "leaked". Now each cause is explained.
export function explainWeakPassword(message: string, reasons?: readonly string[] | null): string {
  const found = new Set<string>((reasons ?? []).map((r) => String(r).toLowerCase()));
  const text = message ?? "";
  if (found.size === 0) {
    if (/known to be weak|pwned|easy to guess/i.test(text)) found.add("pwned");
    if (/at least \d+ characters/i.test(text)) found.add("length");
    if (/character of each|should contain at least one/i.test(text)) found.add("characters");
  }
  const parts: string[] = [];
  if (found.has("length")) {
    const n = text.match(/at least (\d+) characters/i)?.[1];
    parts.push(n ? `كلمة المرور أقصر من الحد المطلوب في إعدادات الخادم (${n} حرفًا على الأقل).` : "كلمة المرور أقصر من الحد المطلوب في إعدادات الخادم.");
  }
  if (found.has("characters")) parts.push("كلمة المرور لا تحقق شروط الأحرف المطلوبة (حروف كبيرة وصغيرة وأرقام ورموز).");
  if (found.has("pwned")) parts.push("كلمة المرور هذه ظهرت في تسريبات بيانات عامة سابقة (فحص Have I Been Pwned) حتى لو بدت قوية. اختر كلمة مرور فريدة لم تستخدمها في مواقع أخرى.");
  if (parts.length === 0) return "رفض الخادم كلمة المرور لأنها لا تستوفي سياسة الأمان. جرّب كلمة مرور أطول وأكثر تفرّدًا.";
  return parts.join(" ");
}

export function isWeakPasswordError(message: string, code?: string | null): boolean {
  return code === "weak_password" || /known to be weak|pwned|easy to guess|weak_password/i.test(message ?? "");
}

export function translateAuthError(message: string, code?: string | null, reasons?: readonly string[] | null): string {
  if (isWeakPasswordError(message, code) || (reasons && reasons.length > 0)) return explainWeakPassword(message, reasons);
  const hay = `${code ?? ""} ${message ?? ""}`;
  const match = KNOWN_PATTERNS.find(([pattern]) => pattern.test(hay));
  if (match) return match[1];
  const detail = (message ?? "").trim();
  return detail
    ? `حدث خطأ غير متوقع. برجاء المحاولة مرة أخرى. (التفاصيل: ${detail})`
    : "حدث خطأ غير متوقع. برجاء المحاولة مرة أخرى.";
}
