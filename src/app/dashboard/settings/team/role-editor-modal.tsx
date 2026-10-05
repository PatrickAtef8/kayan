"use client";

import { useState, useTransition } from "react";
import { Modal } from "@/components/ui/modal";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { createCustomRole, updateCustomRole } from "./role-actions";

export type PermissionOption = { key: string; description: string; category: string };

const CATEGORY_LABEL: Record<string, string> = {
  general: "عام",
  finance: "مالية",
  settings: "الإعدادات",
  sales: "المبيعات",
  purchases: "المشتريات",
  treasury: "الخزنة",
  inventory: "المخزون",
  reports: "التقارير",
};

export function RoleEditorModal({
  open,
  onClose,
  permissions,
  editing,
}: {
  open: boolean;
  onClose: () => void;
  permissions: PermissionOption[];
  editing?: { id: string; name: string; permissionKeys: string[] } | null;
}) {
  const [name, setName] = useState(editing?.name ?? "");
  const [selected, setSelected] = useState<Set<string>>(new Set(editing?.permissionKeys ?? []));
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const grouped = permissions.reduce<Record<string, PermissionOption[]>>((acc, p) => {
    (acc[p.category] ??= []).push(p);
    return acc;
  }, {});

  function toggle(key: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  function submit() {
    setError(null);
    if (!name.trim()) {
      setError("اسم الدور مطلوب");
      return;
    }
    if (selected.size === 0) {
      setError("اختر صلاحية واحدة على الأقل");
      return;
    }

    startTransition(async () => {
      const result = editing ? await updateCustomRole(editing.id, name, Array.from(selected)) : await createCustomRole(name, Array.from(selected));
      if (result.error) {
        setError(result.error);
        return;
      }
      onClose();
    });
  }

  return (
    <Modal open={open} onClose={onClose} title={editing ? "تعديل الدور" : "دور جديد"}>
      <div className="max-h-[65vh] space-y-4 overflow-y-auto">
        <Field label="اسم الدور">
          <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="مثال: مشرف المخازن" />
        </Field>

        <div>
          <p className="mb-2 text-xs font-medium text-charcoal/50">الصلاحيات</p>
          <div className="space-y-4">
            {Object.entries(grouped).map(([category, perms]) => (
              <div key={category}>
                <p className="mb-1.5 text-[0.6875rem] font-medium text-charcoal/35">{CATEGORY_LABEL[category] ?? category}</p>
                <div className="space-y-1.5">
                  {perms.map((p) => (
                    <label key={p.key} className="flex cursor-pointer items-center gap-2 rounded-lg px-2 py-1.5 text-sm hover:bg-paper">
                      <input type="checkbox" checked={selected.has(p.key)} onChange={() => toggle(p.key)} className="h-4 w-4 rounded border-borderSoft text-sage" />
                      <span className="text-charcoal">{p.description}</span>
                    </label>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>

        <div className="flex items-center gap-3 border-t border-borderSoft pt-4">
          <Button type="button" disabled={pending} onClick={submit}>
            {pending ? "جارٍ الحفظ..." : editing ? "حفظ التعديلات" : "إنشاء الدور"}
          </Button>
          {error && <span className="text-xs text-rose">{error}</span>}
        </div>
      </div>
    </Modal>
  );
}
