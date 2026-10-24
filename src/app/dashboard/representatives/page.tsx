import { createClient } from "@/lib/supabase/server";
import { getMembership } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { ActionForm, SubmitButton } from "@/components/ui/action-form";
import { ModernSelect } from "@/components/ui/select";
import { createRepresentative } from "./actions";
import { RepresentativesTable } from "./representatives-table";
import { COMMISSION_BASIS_OPTIONS } from "./commission-basis";

export type Representative = {
  id: string;
  name: string;
  phone: string | null;
  fixed_salary: number;
  transportation_allowance: number;
  commission_basis: string;
  commission_rate: number;
  is_active: boolean;
  monthly_target: number;
  min_target_for_commission: number;
  user_id: string | null;
};
export type MemberOption = { value: string; label: string };

export default async function RepresentativesPage() {
  const supabase = await createClient();
  const { data: reps } = await supabase
    .from("sales_representatives")
    .select("id, name, phone, fixed_salary, transportation_allowance, commission_basis, commission_rate, is_active, monthly_target, min_target_for_commission, user_id")
    .order("created_at", { ascending: false });

  // Members who can be linked to a rep (the Sales Representative role).
  // The RPC error is surfaced instead of being swallowed: before, ANY failure here (or a member who is
  // still pending / has another role) looked identical to "there is no rep user", which was misleading.
  type Member = { user_id: string; email: string; role_key: string; role_name: string; status: string; display_name: string | null };
  const who = (m: Member) => (m.display_name?.trim() ? `${m.display_name.trim()} (${m.email})` : m.email);
  const membership = await getMembership();
  const { data: membersData, error: membersError } = membership
    ? await supabase.rpc("list_org_members", { org_id: membership.organization_id })
    : { data: [] as Member[], error: null };
  const allMembers = (membersData as Member[] | null) ?? [];
  const repMembers = allMembers.filter((m) => m.role_key === "sales");
  const memberOptions: MemberOption[] = repMembers.map((m) => ({ value: m.user_id, label: m.status === "active" ? who(m) : `${who(m)} (دعوة لم تُقبل بعد)` }));
  const membersNote: string | null = membersError
    ? `تعذّر تحميل قائمة الفريق: ${membersError.message}`
    : memberOptions.length > 0
      ? null
      : allMembers.length > 1
        ? `لا يوجد عضو بدور «مندوب». الأعضاء الحاليون: ${allMembers.map((m) => `${who(m)} (${m.role_name}${m.status === "active" ? "" : "، دعوة معلقة"})`).join("، ")}. غيّر دور العضو من الإعدادات ← الفريق.`
        : "لا يوجد مستخدم بدور «مندوب» — أضفه أو غيّر دوره من الإعدادات ← الفريق ثم ارجع هنا.";

  return (
    <div>
      <PageHeader title="المندوبين" />

      <Card className="mb-7 p-5 sm:p-6">
        <ActionForm action={createRepresentative} successText="تمت إضافة المندوب بنجاح" className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <Field label="اسم المندوب">
            <Input name="name" required placeholder="مثال: محمود علي" />
          </Field>
          <Field label="رقم الهاتف">
            <Input name="phone" dir="ltr" placeholder="اختياري" />
          </Field>
          <div />

          <Field label="الراتب الثابت">
            <Input name="fixed_salary" type="number" step="0.01" min="0" dir="ltr" defaultValue={0} />
          </Field>
          <Field label="بدل المواصلات">
            <Input name="transportation_allowance" type="number" step="0.01" min="0" dir="ltr" defaultValue={0} />
          </Field>
          <Field label="نسبة العمولة (%)">
            <Input name="commission_rate" type="number" step="0.01" min="0" max="100" dir="ltr" defaultValue={0} />
          </Field>

          <Field label="Target المبيعات الشهري (ج.م)">
            <Input name="monthly_target" type="number" step="0.01" min="0" dir="ltr" defaultValue={0} />
          </Field>
          <Field label="الحد الأدنى لاستحقاق العمولة (ج.م/شهر)">
            <Input name="min_target_for_commission" type="number" step="0.01" min="0" dir="ltr" defaultValue={0} />
          </Field>
          <Field label="مستخدم النظام (دخول المندوب)">
            <ModernSelect name="user_id" placeholder="بدون" clearLabel="بدون" options={memberOptions} />
            {membersNote && <p className="mt-1.5 text-xs text-rose">{membersNote}</p>}
          </Field>
          <div className="sm:col-span-2">
            <Field label="أساس احتساب العمولة">
              <ModernSelect name="commission_basis" allowClear={false} defaultValue="net_sales" options={COMMISSION_BASIS_OPTIONS} />
            </Field>
          </div>
          <div className="self-end">
            <SubmitButton pendingText="جارٍ إضافة المندوب...">إضافة مندوب</SubmitButton>
          </div>
        </ActionForm>
      </Card>

      <RepresentativesTable representatives={(reps as Representative[]) ?? []} members={memberOptions} membersNote={membersNote} />
    </div>
  );
}
