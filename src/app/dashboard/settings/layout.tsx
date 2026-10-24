import { PageHeader } from "@/components/ui/page-header";
import { SettingsTabs } from "@/components/settings/settings-tabs";
import { requireRole } from "@/lib/role-guard";

export default async function SettingsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(["owner"]);
  return (
    <div>
      <PageHeader title="الإعدادات" />
      <SettingsTabs />
      {children}
    </div>
  );
}
