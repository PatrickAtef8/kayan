// What a create/update server action hands back to <ActionForm>. `error: null` = it worked.
// A string is an Arabic, user-facing reason (already translated) that is shown under the button.
export type ActionResult = { error: string | null };

export const AUTH_ERROR = "غير مصرح — يرجى تسجيل الدخول مجددًا";
export const NAME_REQUIRED = "أدخل الاسم أولًا";
