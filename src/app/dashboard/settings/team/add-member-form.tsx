"use client";

import { useState, useTransition } from "react";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { addTeamMember } from "./actions";

type RoleOption = { id: string; name: string };

export function AddMemberForm({ roles, onAdded }: { roles: RoleOption[]; onAdded: () => void }) {
  const [email, setEmail] = useState("");
  const [roleId, setRoleId] = useState(roles[0]?.id ?? "");
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);

  function submit() {
    setError(null);
    setSuccess(false);
    if (!email.trim()) {
      setError("أدخل البريد الإلكتروني");
      return;
    }
    startTransition(async () => {
      const result = await addTeamMember(email, roleId);
      if (result.error) {
        setError(result.error);
        return;
      }
      setEmail("");
      setSuccess(true);
      onAdded();
    });
  }

  return (
    <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-[1fr_9rem_auto] sm:items-end">
      <Field label="البريد الإلكتروني">
        <Input type="email" dir="ltr" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="name@example.com" />
      </Field>
      <Field label="الدور">
        <ModernSelect value={roleId} onChange={setRoleId} allowClear={false} options={roles.map((r) => ({ value: r.id, label: r.name }))} />
      </Field>
      <Button type="button" disabled={pending} onClick={submit}>
        {pending ? "جارٍ الإضافة..." : "إضافة عضو"}
      </Button>
      {error && <p className="text-xs text-rose sm:col-span-3">{error}</p>}
      {success && <p className="text-xs text-sage sm:col-span-3">تمت الإضافة — إذا كان الشخص جديدًا فسيصله بريد إلكتروني لتفعيل حسابه.</p>}
    </div>
  );
}
