import { getSettingsContext } from "@/lib/settings-context";
import { NoSettingsAccess } from "@/components/settings/no-settings-access";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { ActionForm, SubmitButton } from "@/components/ui/action-form";
import { updateOrgName } from "./actions";

const LANGUAGE_LABEL: Record<string, string> = { ar: "العربية", en: "English" };

export default async function GeneralSettingsPage() {
  const { supabase, orgId, canManage } = await getSettingsContext();
  if (!orgId) return null;
  if (!canManage) return <NoSettingsAccess />;

  const { data: org } = await supabase.from("organizations").select("name, country, currency, language, business_type").eq("id", orgId).single();
  if (!org) return null;

  return (
    <div className="max-w-lg">
      <Card className="p-5 sm:p-6">
        <ActionForm action={updateOrgName} successText="تم حفظ اسم المؤسسة" className="mb-6 space-y-4">
          <Field label="اسم المؤسسة">
            <Input name="name" defaultValue={org.name} required />
          </Field>
          <SubmitButton pendingText="جارٍ الحفظ...">حفظ</SubmitButton>
        </ActionForm>

        <div className="space-y-3 border-t border-borderSoft pt-5 text-sm">
          <p className="text-xs text-charcoal/40">
            هذه البيانات ثابتة بعد إنشاء المؤسسة لأن تغييرها يؤثر على كل السجلات المالية السابقة (العملة والضريبة
            محسوبة عليها بالفعل).
          </p>
          <Row label="الدولة" value={org.country ?? "—"} />
          <Row label="العملة" value={org.currency ?? "—"} />
          <Row label="اللغة" value={LANGUAGE_LABEL[org.language ?? ""] ?? org.language ?? "—"} />
          <Row label="نوع النشاط" value={org.business_type ?? "—"} />
        </div>
      </Card>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between text-charcoal/60">
      <span>{label}</span>
      <span className="text-charcoal/40">{value}</span>
    </div>
  );
}
