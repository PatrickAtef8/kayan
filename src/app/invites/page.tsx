"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type Invite = { organization_id: string; organization_name: string; role_name: string };

export default function InvitesPage() {
  const router = useRouter();
  const [invites, setInvites] = useState<Invite[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return router.replace("/login");
      const { data, error } = await supabase.rpc("list_my_invites");
      if (error) setError("تعذر تحميل الدعوات");
      else setInvites((data as Invite[]) ?? []);
    });
  }, [router]);

  async function respond(orgId: string, accept: boolean) {
    setBusy(orgId);
    setError(null);
    const supabase = createClient();
    const { error } = accept
      ? await supabase.rpc("accept_org_invite", { p_org: orgId })
      : await supabase.rpc("decline_org_invite", { p_org: orgId });
    setBusy(null);
    if (error) return setError(error.message);
    if (accept) return router.replace("/dashboard");
    setInvites((cur) => (cur ?? []).filter((i) => i.organization_id !== orgId));
  }

  return (
    <main className="mx-auto max-w-md p-6" dir="rtl">
      <h1 className="mb-4 text-xl font-bold">دعوات الانضمام</h1>
      {error && <p className="mb-3 text-sm text-red-600">{error}</p>}
      {invites === null ? (
        <p>جارٍ التحميل…</p>
      ) : invites.length === 0 ? (
        <p>لا توجد دعوات معلقة.</p>
      ) : (
        <ul className="space-y-3">
          {invites.map((i) => (
            <li key={i.organization_id} className="rounded-lg border p-4">
              <p className="font-semibold">{i.organization_name}</p>
              <p className="mb-3 text-sm opacity-70">الدور: {i.role_name}</p>
              <div className="flex gap-2">
                <button disabled={busy === i.organization_id} onClick={() => respond(i.organization_id, true)} className="rounded bg-black px-3 py-1.5 text-white disabled:opacity-50">قبول</button>
                <button disabled={busy === i.organization_id} onClick={() => respond(i.organization_id, false)} className="rounded border px-3 py-1.5 disabled:opacity-50">رفض</button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}
