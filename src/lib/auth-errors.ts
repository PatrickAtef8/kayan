// Supabase Auth (and Postgres RPC) errors come back in English. This keeps
// the UI fully Arabic by mapping the common cases and falling back to a
// generic Arabic message for anything unrecognized, instead of ever
// showing the raw English text to the user.
const KNOWN_PATTERNS: [RegExp, string][] = [
  [/already registered|user already exists/i, "هذا البريد الإلكتروني مسجّل بالفعل. جرّب تسجيل الدخول بدلاً من ذلك."],
  [/password should be at least|password.*(short|weak|characters)/i, "كلمة المرور قصيرة جدًا — يجب ألا تقل عن 6 أحرف."],
  [/invalid.*email|unable to validate email/i, "صيغة البريد الإلكتروني غير صحيحة."],
  [/rate limit/i, "محاولات كثيرة جدًا خلال وقت قصير. برجاء المحاولة بعد قليل."],
  [/network|fetch failed/i, "تعذّر الاتصال بالخادم. تحقق من اتصال الإنترنت وحاول مجددًا."],
];

export function translateAuthError(message: string): string {
  const match = KNOWN_PATTERNS.find(([pattern]) => pattern.test(message));
  return match ? match[1] : "حدث خطأ غير متوقع. برجاء المحاولة مرة أخرى.";
}
