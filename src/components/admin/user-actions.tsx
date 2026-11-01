"use client";

import { ConfirmAction } from "./confirm-action";
import { setUserActive, deleteUser } from "@/app/admin/actions";

export function UserActions({ userId, email, deactivated, isSelf, hasCompanies }: { userId: string; email: string; deactivated: boolean; isSelf: boolean; hasCompanies: boolean }) {
  if (isSelf) return <span className="text-xs text-charcoal/35">حسابك (لا يُحذف ولا يُعطَّل كي لا تفقد الدخول)</span>;
  return (
    <div className="flex flex-wrap gap-2">
      {deactivated
        ? <ConfirmAction label="إعادة تفعيل" title="إعادة تفعيل المستخدم؟" description={`سيتمكن ${email} من تسجيل الدخول مرة أخرى.`} confirmLabel="إعادة التفعيل" run={() => setUserActive(userId, true)} />
        : <ConfirmAction label="تعطيل" title="تعطيل المستخدم؟" description={`لن يتمكن ${email} من تسجيل الدخول. لا يُحذف أي شيء من بياناته أو بيانات شركته، ويمكنك إعادة التفعيل في أي وقت.`} confirmLabel="تعطيل" run={() => setUserActive(userId, false)} />}
      <ConfirmAction label="حذف نهائي" tone="danger"
        title="حذف المستخدم نهائيًا؟" description={`سيُحذف حساب ${email} نهائيًا ولا يمكن التراجع.${hasCompanies ? " الحساب عضو في شركة: ستُزال عضويته، وتبقى سجلات الشركة دون اسمه، وقد تُترك الشركة بلا مالك إن كان مالكها الوحيد. للتراجع لاحقًا فضّل «تعطيل»." : ""}`} confirmLabel="حذف نهائيًا" run={() => deleteUser(userId)} />
    </div>
  );
}
