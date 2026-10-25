"use client";

import { useState, useTransition } from "react";
import { Check, Pencil, UserMinus, X } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";
import { ModernSelect } from "@/components/ui/select";
import { updateMemberRole, updateMemberName, removeMember, linkMemberToRep } from "./actions";

type Member = { user_id: string; email: string; role_id: string; role_key: string; role_name: string; status: string; is_self: boolean; display_name?: string | null };
type RoleOption = { id: string; name: string };

export function TeamList({ members, roles, linkedUserIds = [], freeReps = [] }: { members: Member[]; roles: RoleOption[]; linkedUserIds?: string[]; freeReps?: { id: string; name: string }[] }) {
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

  const [editingId, setEditingId] = useState<string | null>(null);
  const [draftName, setDraftName] = useState("");

  function saveName(userId: string) {
    const next = draftName.trim();
    if (!next) {
      setError("الاسم مطلوب");
      return;
    }
    setError(null);
    setPendingId(userId);
    startTransition(async () => {
      const result = await updateMemberName(userId, next);
      if (result.error) setError(result.error);
      else {
        setRows((prev) => prev.map((m) => (m.user_id === userId ? { ...m, display_name: next } : m)));
        setEditingId(null);
      }
      setPendingId(null);
    });
  }

  const [linked, setLinked] = useState<string[]>(linkedUserIds);
  const [pickRep, setPickRep] = useState<Record<string, string>>({});

  function link(m: Member, repId: string | null) {
    setError(null);
    setPendingId(m.user_id);
    startTransition(async () => {
      const result = await linkMemberToRep(m.user_id, repId, m.display_name?.trim() || m.email.split("@")[0]);
      if (result.error) setError(result.error);
      else setLinked((prev) => [...prev, m.user_id]);
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
              {editingId === m.user_id ? (
                <div className="mb-1 flex items-center gap-1.5">
                  <input
                    autoFocus
                    value={draftName}
                    maxLength={100}
                    onChange={(e) => setDraftName(e.target.value)}
                    onKeyDown={(e) => { if (e.key === "Enter") saveName(m.user_id); if (e.key === "Escape") setEditingId(null); }}
                    placeholder="اسم الشخص"
                    className="w-44 rounded-lg border border-borderSoft bg-white px-2 py-1 text-sm text-charcoal outline-none focus:border-sage"
                  />
                  <button type="button" aria-label="حفظ الاسم" disabled={pending} onClick={() => saveName(m.user_id)} className="cursor-pointer rounded-lg p-1.5 text-sage hover:bg-sage/10 disabled:opacity-40"><Check size={15} /></button>
                  <button type="button" aria-label="إلغاء" onClick={() => setEditingId(null)} className="cursor-pointer rounded-lg p-1.5 text-charcoal/40 hover:bg-charcoal/5"><X size={15} /></button>
                </div>
              ) : (
                <p className="mb-0.5 flex items-center gap-1.5 font-medium text-charcoal">
                  {m.display_name?.trim() ? m.display_name : <span className="text-[0.75rem] font-normal text-rose">بدون اسم</span>}
                  <button type="button" aria-label="تعديل الاسم" onClick={() => { setEditingId(m.user_id); setDraftName(m.display_name ?? ""); }} className="cursor-pointer rounded p-1 text-charcoal/30 hover:text-sage"><Pencil size={12} /></button>
                </p>
              )}
              <p className="text-charcoal/70">
                <span dir="ltr">{m.email}</span>
                {m.is_self && <span className="mr-1.5 text-[0.6875rem] text-charcoal/35">(أنت)</span>}
                {m.status === "invited" && <span className="mr-1.5 text-[0.6875rem] text-brass">(بانتظار القبول)</span>}
                {m.role_key === "sales" && !linked.includes(m.user_id) && <span className="mr-1.5 text-[0.6875rem] text-rose">(غير مربوط بسجل مندوب — لن يرى أي بيانات)</span>}
                {m.role_key === "sales" && linked.includes(m.user_id) && <span className="mr-1.5 text-[0.6875rem] text-sage">(مربوط بسجل مندوب ✓)</span>}
              </p>
              {m.role_key === "sales" && !linked.includes(m.user_id) && (
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  {freeReps.length > 0 && (
                    <>
                      <div className="w-40"><ModernSelect value={pickRep[m.user_id] ?? ""} onChange={(v) => setPickRep((p) => ({ ...p, [m.user_id]: v }))} placeholder="مندوب موجود..." clearLabel="مندوب موجود..." options={freeReps.map((r) => ({ value: r.id, label: r.name }))} /></div>
                      <button type="button" disabled={!pickRep[m.user_id] || pending} onClick={() => link(m, pickRep[m.user_id] || null)} className="cursor-pointer rounded-lg border border-borderSoft bg-white px-2.5 py-1.5 text-xs text-charcoal transition-colors hover:border-sage disabled:cursor-not-allowed disabled:opacity-40">ربط</button>
                      {!pickRep[m.user_id] && <span className="text-[0.6875rem] text-charcoal/40">اختر مندوبًا من القائمة لربطه</span>}
                      <span className="text-[0.6875rem] text-charcoal/35">أو</span>
                    </>
                  )}
                  <button type="button" disabled={pending} onClick={() => link(m, null)} className="cursor-pointer rounded-lg bg-charcoal px-2.5 py-1.5 text-xs text-ivory transition-colors hover:bg-sage disabled:cursor-not-allowed disabled:opacity-40">ربط بسجل مندوب جديد</button>
                </div>
              )}
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
