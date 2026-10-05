import { PageHeader } from "@/components/ui/page-header";
import { SettingsTabs } from "@/components/settings/settings-tabs";

export default function SettingsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <PageHeader title="الإعدادات" />
      <SettingsTabs />
      {children}
    </div>
  );
}
