import { getSettingsContext } from "@/lib/settings-context";
import { NoSettingsAccess } from "@/components/settings/no-settings-access";
import { Card } from "@/components/ui/card";
import { VISIBLE_MODULES as MODULES } from "@/lib/modules";
import { ModuleToggleRow } from "./module-toggle-row";

export default async function ModulesSettingsPage() {
  const { supabase, orgId, canManage } = await getSettingsContext();
  if (!orgId) return null;
  if (!canManage) return <NoSettingsAccess />;

  const [{ data: rows }, { data: lic }] = await Promise.all([
    supabase.from("organization_modules").select("module_key, enabled").eq("organization_id", orgId),
    supabase.from("organization_licenses").select("entitlements").eq("organization_id", orgId).maybeSingle(),
  ]);
  const enabledMap = new Map((rows ?? []).map((r) => [r.module_key, r.enabled]));
  // The PACKAGE decides which optional modules can be switched on; the rest are shown locked. (The database enforces it too.)
  const ent = lic?.entitlements as { modules?: unknown } | null | undefined;
  const included = new Set<string>(Array.isArray(ent?.modules) ? (ent!.modules as unknown[]).filter((k): k is string => typeof k === "string") : []);
  const hasLicense = !!lic;

  const toggleable = MODULES.filter((m) => !("core" in m && m.core));
  const core = MODULES.filter((m) => "core" in m && m.core);

  return (
    <div className="max-w-lg space-y-6">
      <div>
        <p className="mb-3 text-xs font-medium text-charcoal/40">وحدات أساسية (مفعّلة دائمًا)</p>
        <Card className="divide-y divide-borderSoft p-0">
          {core.map((m) => (
            <div key={m.key} className="px-3.5 py-3 text-sm text-charcoal/50">
              {m.label}
            </div>
          ))}
        </Card>
      </div>

      <div>
        <p className="mb-1 text-xs font-medium text-charcoal/40">وحدات اختيارية</p>
        <p className="mb-3 text-xs leading-6 text-charcoal/45">الوحدات المتاحة تحددها الباقة التي اشتركت بها. الوحدات غير المشمولة تظهر مقفلة، ويمكنك ترقية الباقة بالتواصل مع فريق كيان.</p>
        <Card className="divide-y divide-borderSoft p-0">
          {toggleable.map((m) => (
            <ModuleToggleRow key={m.key} moduleKey={m.key} label={m.label} initialEnabled={enabledMap.get(m.key) ?? false} locked={m.key === "offers" ? false : !hasLicense || !included.has(m.key)} />
          ))}
        </Card>
      </div>
    </div>
  );
}
