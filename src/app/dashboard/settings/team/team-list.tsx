"use client";

import { useState, useTransition } from "react";
import { UserMinus } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";
import { ModernSelect } from "@/components/ui/select";
import { updateMemberRole, removeMember } from "./actions";

type Member = { user_id: string; email: string; role_id: string; role_key: string; role_name: string; status: string; is_self: boolean };
type RoleOption = { id: string; name: string };

export function TeamList({ members, roles }: { members: Member[]; roles: RoleOption[] }) {
  const [rows, setRows] = useState(members);
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function changeRole(userId: string, roleId: string) {
    setError(null);
    setPendingId(userId);
    const previous = rows;
    setRows((prev) => prev.map((m) => (m.user_id === userId ? { ...m, role_id: roleId } : m)));
    startTransition(async () => {
      const result = await updateMemberRole(userId, roleId);
      if (result.error) {
        setRows(previous);
        setError(result.error);
      }
      setPendingId(null);
    });
  }

  function remove(userId: string) {
    if (!confirm("هل تريد إزالة هذا العضو من المؤسسة؟")) return;
    setError(null);
    setPendingId(userId);
    startTransition(async () => {
      const result = await removeMember(userId);
      if (result.error) {
        setError(result.error);
        setPendingId(null);
      } else {
        setRows((prev) => prev.filter((m) => m.user_id !== userId));
      }
    });
  }

  return (
    <div>
      {error && <p className="mb-3 text-xs text-rose">{error}</p>}
      <div className="divide-y divide-borderSoft rounded-xl border border-borderSoft">
        {rows.map((m) => (
          <div key={m.user_id} className="flex items-center justify-between gap-3 px-3.5 py-3 text-sm">
            <div>
              <p className="text-charcoal">
                {m.email}
                {m.is_self && <span className="mr-1.5 text-[0.6875rem] text-charcoal/35">(أنت)</span>}
                {m.status === "invited" && <span className="mr-1.5 text-[0.6875rem] text-brass">(بانتظار القبول)</span>}
              </p>
            </div>
            <div className="flex items-center gap-2">
              <div className="flex w-36 items-center gap-2">
                {pending && pendingId === m.user_id && <Spinner size={13} className="text-sage" />}
                <div className="min-w-0 flex-1">
                <ModernSelect
                  value={m.role_id}
                  onChange={(v) => changeRole(m.user_id, v)}
                  allowClear={false}
                  options={roles.map((r) => ({ value: r.id, label: r.name }))}
                />
                </div>
              </div>
              <button
                onClick={() => remove(m.user_id)}
                disabled={m.is_self || (pending && pendingId === m.user_id)}
                aria-label="إزالة العضو"
                className="rounded-lg p-1.5 text-charcoal/30 hover:bg-rose/10 hover:text-rose disabled:cursor-not-allowed disabled:opacity-30"
              >
                {pending && pendingId === m.user_id ? <Spinner size={15} /> : <UserMinus size={16} strokeWidth={2} />}
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
