import { getSettingsContext } from "@/lib/settings-context";
import { NoSettingsAccess } from "@/components/settings/no-settings-access";
import { Card } from "@/components/ui/card";
import { MODULES } from "@/lib/modules";
import { ModuleToggleRow } from "./module-toggle-row";

export default async function ModulesSettingsPage() {
  const { supabase, orgId, canManage } = await getSettingsContext();
  if (!orgId) return null;
  if (!canManage) return <NoSettingsAccess />;

  const { data: rows } = await supabase.from("organization_modules").select("module_key, enabled").eq("organization_id", orgId);
  const enabledMap = new Map((rows ?? []).map((r) => [r.module_key, r.enabled]));

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
        <p className="mb-3 text-xs font-medium text-charcoal/40">وحدات اختيارية</p>
        <Card className="divide-y divide-borderSoft p-0">
          {toggleable.map((m) => (
            <ModuleToggleRow key={m.key} moduleKey={m.key} label={m.label} initialEnabled={enabledMap.get(m.key) ?? false} />
          ))}
        </Card>
      </div>
    </div>
  );
}
