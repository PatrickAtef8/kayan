"use client";

import { useState, useTransition } from "react";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { addTeamMember } from "./actions";

type RoleOption = { id: string; name: string };

export function AddMemberForm({ roles, onAdded }: { roles: RoleOption[]; onAdded: () => void }) {
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [roleId, setRoleId] = useState(roles[0]?.id ?? "");
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<null | { mode: "existing" | "notified" | "emailed" | "email_failed"; email: string; name: string; warning?: string }>(null);

  function submit() {
    setError(null);
    setSuccess(null);
    if (!name.trim()) {
      setError("أدخل اسم الشخص");
      return;
    }
    if (!email.trim()) {
      setError("أدخل البريد الإلكتروني");
      return;
    }
    startTransition(async () => {
      const result = await addTeamMember(email, roleId, name);
      if (result.error) {
        setError(result.error);
        return;
      }
      setSuccess({ mode: result.mode ?? "emailed", email: email.trim(), name: name.trim(), warning: result.warning });
      setEmail("");
      setName("");
      onAdded();
    });
  }

  return (
    <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-[1fr_1fr_9rem_auto] sm:items-end">
      <Field label="الاسم">
        <Input value={name} maxLength={100} onChange={(e) => setName(e.target.value)} placeholder="مثال: محمود علي" />
      </Field>
      <Field label="البريد الإلكتروني">
        <Input type="email" dir="ltr" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="name@example.com" />
      </Field>
      <Field label="الدور">
        <ModernSelect value={roleId} onChange={setRoleId} allowClear={false} options={roles.map((r) => ({ value: r.id, label: r.name }))} />
      </Field>
      <Button type="button" disabled={pending} onClick={submit}>
        {pending ? "جارٍ الإضافة..." : "إضافة عضو"}
      </Button>
      {error && <p className="text-xs text-rose sm:col-span-4">{error}</p>}
      {success?.mode === "emailed" && (
        <p className="text-xs text-sage sm:col-span-4">تم إرسال دعوة بالبريد إلى {success.name} ({success.email}) — سيجد فيها رابطًا لتعيين كلمة المرور (راجع Spam إن لم تظهر).</p>
      )}
      {success?.mode === "notified" && (
        <p className="text-xs text-sage sm:col-span-4">{success.name} ({success.email}) لديه حساب بالفعل. أرسلنا له بريدًا يخبره بالدعوة، وسيجدها في صفحة «الدعوات» عند تسجيل دخوله.</p>
      )}
      {success?.mode === "email_failed" && (
        <p className="text-xs text-rose sm:col-span-4">
          سجّلنا دعوة {success.name} ({success.email}) لكن <b>تعذّر إرسال البريد</b>. {success.warning} بعد حل المشكلة أضف نفس البريد مرة أخرى لإعادة الإرسال.
        </p>
      )}
      {success?.mode === "existing" && (
        <p className="text-xs text-brass sm:col-span-4">
          {success.name} ({success.email}) لديه حساب بالفعل، لذلك <b>لن يصله إيميل</b>. سجّلنا الدعوة، وسيجدها في صفحة «الدعوات» عند تسجيل دخوله، ويمكنك إخباره بذلك مباشرة.
        </p>
      )}
    </div>
  );
}
