import { getSettingsContext } from "@/lib/settings-context";
import { NoSettingsAccess } from "@/components/settings/no-settings-access";
import { TeamManager } from "./team-manager";

const ROLE_ORDER = ["owner", "admin", "accountant", "sales", "warehouse"];

export default async function TeamSettingsPage() {
  const { supabase, orgId, canManage } = await getSettingsContext();
  if (!orgId) return null;
  if (!canManage) return <NoSettingsAccess />;

  const [{ data: members }, { data: roles }, { data: permissions }, { data: memberCounts }] = await Promise.all([
    supabase.rpc("list_org_members", { org_id: orgId }),
    supabase.from("roles").select("id, key, name, is_system").or(`organization_id.is.null,organization_id.eq.${orgId}`),
    supabase.from("permissions").select("key, description, category"),
    supabase.from("organization_users").select("role_id").eq("organization_id", orgId).eq("status", "active"),
  ]);

  const allRoles = roles ?? [];
  const sortedRoles = allRoles
    .slice()
    .sort((a, b) => {
      const ai = ROLE_ORDER.indexOf(a.key);
      const bi = ROLE_ORDER.indexOf(b.key);
      if (ai !== -1 || bi !== -1) return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
      return a.name.localeCompare(b.name, "ar");
    });

  // role_permissions has no organization_id column of its own, so scope by
  // this org's custom role ids (system roles' permission sets are fixed
  // and seeded once — never shown for editing here).
  const customRoleRows = allRoles.filter((r) => !r.is_system);
  const { data: rolePermissions } = customRoleRows.length
    ? await supabase.from("role_permissions").select("role_id, permission_key").in("role_id", customRoleRows.map((r) => r.id))
    : { data: [] as { role_id: string; permission_key: string }[] };

  const countByRole = (memberCounts ?? []).reduce<Record<string, number>>((acc, m) => {
    if (m.role_id) acc[m.role_id] = (acc[m.role_id] ?? 0) + 1;
    return acc;
  }, {});

  const customRoles = customRoleRows.map((r) => ({
    id: r.id,
    name: r.name,
    permissionKeys: (rolePermissions ?? []).filter((rp) => rp.role_id === r.id).map((rp) => rp.permission_key),
    memberCount: countByRole[r.id] ?? 0,
  }));

  return (
    <div className="max-w-2xl">
      <p className="mb-6 text-xs leading-6 text-charcoal/45">
        إضافة شخص لديه حساب بالفعل تتم فورًا. أما إضافة بريد إلكتروني جديد تمامًا فترسل له دعوة لإنشاء حساب — يحتاج هذا
        إلى إعداد مفتاح الخدمة (service role) في متغيرات البيئة، راجع ملف .env.example.
      </p>
      <TeamManager members={members ?? []} roles={sortedRoles} customRoles={customRoles} permissions={permissions ?? []} />
    </div>
  );
}
