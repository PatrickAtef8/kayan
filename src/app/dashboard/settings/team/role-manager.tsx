"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Plus, Pencil, Trash2, ShieldCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { RoleEditorModal, type PermissionOption } from "./role-editor-modal";
import { deleteCustomRole } from "./role-actions";

export type CustomRole = { id: string; name: string; permissionKeys: string[]; memberCount: number };

export function RoleManager({ customRoles, permissions }: { customRoles: CustomRole[]; permissions: PermissionOption[] }) {
  const router = useRouter();
  const [modalState, setModalState] = useState<{ open: boolean; editing: CustomRole | null }>({ open: false, editing: null });
  const [pendingDeleteId, setPendingDeleteId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function close() {
    setModalState({ open: false, editing: null });
    router.refresh();
  }

  function requestDelete(role: CustomRole) {
    setError(null);
    if (role.memberCount > 0) {
      setError(`لا يمكن حذف "${role.name}" — يوجد ${role.memberCount} عضو مُسند إليه. أعد إسنادهم أولاً من القائمة أعلاه.`);
      return;
    }
    setPendingDeleteId(role.id);
  }

  function confirmDelete(id: string) {
    startTransition(async () => {
      const result = await deleteCustomRole(id);
      setPendingDeleteId(null);
      if (result.error) {
        setError(result.error);
        return;
      }
      router.refresh();
    });
  }

  return (
    <div className="mt-10 border-t border-borderSoft pt-8">
      <div className="mb-4 flex items-center justify-between">
        <div>
          <p className="text-xs font-medium text-charcoal/40">صلاحيات مخصّصة</p>
          <h2 className="mt-1 text-base font-semibold text-charcoal">الأدوار المخصّصة</h2>
        </div>
        <Button type="button" onClick={() => setModalState({ open: true, editing: null })} className="flex items-center gap-1.5">
          <Plus size={15} strokeWidth={2.2} />
          دور جديد
        </Button>
      </div>

      {error && <p className="mb-3 text-xs text-rose">{error}</p>}

      {customRoles.length === 0 ? (
        <p className="text-xs text-charcoal/40">لا توجد أدوار مخصّصة بعد — الأدوار الافتراضية (مالك، مدير، محاسب، مبيعات، مخزن) متاحة دائمًا أعلاه.</p>
      ) : (
        <div className="space-y-2">
          {customRoles.map((role) => (
            <div key={role.id} className="flex items-center justify-between rounded-xl border border-borderSoft px-4 py-3">
              <div className="flex items-center gap-2.5">
                <ShieldCheck size={15} className="text-sage" strokeWidth={1.8} />
                <div>
                  <p className="text-sm text-charcoal">{role.name}</p>
                  <p className="text-[0.6875rem] text-charcoal/40">
                    {role.permissionKeys.length} صلاحية · {role.memberCount} عضو
                  </p>
                </div>
              </div>
              <div className="flex items-center gap-1">
                <button onClick={() => setModalState({ open: true, editing: role })} className="rounded-lg p-2 text-charcoal/40 hover:bg-paper hover:text-charcoal" title="تعديل">
                  <Pencil size={14} strokeWidth={1.8} />
                </button>
                {pendingDeleteId === role.id ? (
                  <button disabled={pending} onClick={() => confirmDelete(role.id)} className="rounded-lg px-2 py-1 text-xs font-medium text-rose hover:bg-rose/10">
                    {pending ? "جارٍ الحذف..." : "تأكيد الحذف"}
                  </button>
                ) : (
                  <button onClick={() => requestDelete(role)} className="rounded-lg p-2 text-charcoal/40 hover:bg-paper hover:text-rose" title="حذف">
                    <Trash2 size={14} strokeWidth={1.8} />
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {modalState.open && (
        <RoleEditorModal
          open={modalState.open}
          onClose={close}
          permissions={permissions}
          editing={modalState.editing ? { id: modalState.editing.id, name: modalState.editing.name, permissionKeys: modalState.editing.permissionKeys } : null}
        />
      )}
    </div>
  );
}
