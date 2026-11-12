import Link from "next/link";
import { getSettingsContext } from "@/lib/settings-context";
import { NoSettingsAccess } from "@/components/settings/no-settings-access";
import { TeamManager } from "./team-manager";

const ROLE_ORDER = ["owner", "sales", "warehouse"];

const ROLE_NOTES = [
  { name: "مالك", text: "يرى ويدير كل بيانات النظام، وهو الوحيد الذي ينشئ العملاء ويعيّنهم للمناديب ويغيّر التعيين في أي وقت." },
  { name: "مندوب", text: "يرى العملاء المعيّنين له فقط (فواتيرهم ومبيعاتهم ومدفوعاتهم ومديونياتهم وتقاريرهم)، ولا يصل لبيانات أي مندوب آخر حتى لو فتح الصفحات أو الـ API مباشرة." },
  { name: "أمين مخزن", text: "يرى أصناف وكميات فواتير البيع والشراء ليجهّز البضاعة ويؤكد الصرف والاستلام، بدون أي أسعار أو إجماليات أو مديونيات أو مدفوعات أو تقارير مالية." },
];

export default async function TeamSettingsPage() {
  const { supabase, orgId, canManage } = await getSettingsContext();
  if (!orgId) return null;
  if (!canManage) return <NoSettingsAccess />;

  const [{ data: members }, { data: roles }, { data: reps }] = await Promise.all([
    supabase.rpc("list_org_members", { org_id: orgId }),
    supabase.from("roles").select("id, key, name").is("organization_id", null),
    supabase.from("sales_representatives").select("id, name, user_id, is_active").eq("organization_id", orgId),
  ]);

  const sortedRoles = (roles ?? []).slice().sort((a, b) => ROLE_ORDER.indexOf(a.key) - ROLE_ORDER.indexOf(b.key));
  const linkedUserIds = (reps ?? []).filter((r) => r.user_id).map((r) => r.user_id as string);
  const freeReps = (reps ?? []).filter((r) => !r.user_id && r.is_active).map((r) => ({ id: r.id as string, name: r.name as string }));

  return (
    <div className="max-w-2xl">
      <TeamManager members={members ?? []} roles={sortedRoles} linkedUserIds={linkedUserIds} freeReps={freeReps} />
      <div className="mt-8 rounded-xl border border-borderSoft bg-paper/60 p-4">
        <p className="mb-3 text-xs font-medium text-charcoal/60">الأدوار في النظام (ثلاثة فقط، ثابتة)</p>
        <ul className="space-y-2 text-xs leading-6 text-charcoal/55">
          {ROLE_NOTES.map((r) => (
            <li key={r.name}><span className="font-medium text-charcoal">{r.name}:</span> {r.text}</li>
          ))}
        </ul>
        <p className="mt-3 text-[0.6875rem] text-charcoal/40">
          لكي يعمل حساب المندوب: اضغط «ربط بسجل مندوب» بجوار اسمه في القائمة أعلاه (أو اربطه من صفحة <Link href="/dashboard/representatives" className="text-sage underline">المندوبين</Link>)، ثم من صفحة <Link href="/dashboard/customers" className="text-sage underline">العملاء</Link> اضغط أيقونة التعديل ✎ بجوار العميل واختر «المندوب المسؤول».
        </p>
      </div>
    </div>
  );
}
