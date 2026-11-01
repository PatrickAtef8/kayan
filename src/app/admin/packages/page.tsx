import { Card } from "@/components/ui/card";
import { AdminHeader } from "@/components/admin/admin-header";
import { PackageEditor } from "@/components/admin/package-editor";
import { GraceSettings } from "@/components/admin/grace-settings";
import { requireSuperAdminPage } from "@/lib/admin/auth.server";
import { createAdminClient } from "@/lib/supabase/admin";
import { loadPricingConfig } from "@/lib/billing/config";
import { toEditable, type PricingConfig } from "@/lib/billing/pricing";
import { PRICING_CONFIG } from "@/config/pricing.config";
import { fmtDate } from "@/lib/admin/format";

const shipped = PRICING_CONFIG as PricingConfig;

export default async function PackagesPage() {
  await requireSuperAdminPage();
  const admin = createAdminClient();
  const [{ config, custom, updatedAt }, hist, lic, settings] = await Promise.all([
    loadPricingConfig(admin),
    admin.from("platform_pricing_history").select("id, action, created_at, applied_to_existing, note").order("id", { ascending: false }).limit(15),
    admin.rpc("admin_license_stats"),
    admin.from("platform_billing_settings").select("grace_enabled, grace_hours").eq("id", 1).maybeSingle(),
  ]);
  const grace = { enabled: settings.data?.grace_enabled ?? true, hours: settings.data?.grace_hours ?? 24 };
  const counts = (lic.error ? {} : (lic.data ?? {})) as Record<string, number>;
  const packages = config.packages.map((p) => ({
    key: p.key, name: p.name, config: p, current: toEditable(p), shipped: toEditable(shipped.packages.find((s) => s.key === p.key)!), licensees: counts[p.key] ?? 0,
  }));
  return (
    <div>
      <AdminHeader title="الباقات والأسعار" subtitle="عدّل الأسعار والحدود والوحدات. تسري التغييرات فورًا على صفحة الأسعار وصفحة الدفع والشراء الجديد دون إعادة نشر." />
      <Card className={`mb-5 p-4 text-sm ${custom ? "border-amber-200 bg-amber-50 text-amber-900" : "bg-sageSoft/50 text-charcoal/75"}`}>
        {custom ? `الإعدادات الحالية معدّلة عن الأصلية (آخر تعديل ${fmtDate(updatedAt)}).` : "الإعدادات الحالية هي الأصلية كما شُحنت مع النظام، ولم يُعدَّل شيء بعد."}
      </Card>
      <GraceSettings initial={grace} />
      <PackageEditor packages={packages} history={(hist.data ?? []) as never} custom={custom} />
    </div>
  );
}
