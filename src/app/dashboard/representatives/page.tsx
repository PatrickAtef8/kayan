import { createClient } from "@/lib/supabase/server";
import { getMembership } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
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

  // Members who can be linked to a rep (the Sales Representative role)
  const membership = await getMembership();
  const { data: members } = membership ? await supabase.rpc("list_org_members", { org_id: membership.organization_id }) : { data: [] };
  const memberOptions: MemberOption[] = ((members as { user_id: string; email: string; role_key: string }[] | null) ?? [])
    .filter((m) => m.role_key === "sales")
    .map((m) => ({ value: m.user_id, label: m.email }));

  return (
    <div>
      <PageHeader title="المندوبين" />

      <Card className="mb-7 p-5 sm:p-6">
        <form action={createRepresentative} className="grid grid-cols-1 gap-4 sm:grid-cols-3">
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
          </Field>
          <div className="sm:col-span-2">
            <Field label="أساس احتساب العمولة">
              <ModernSelect name="commission_basis" allowClear={false} defaultValue="net_sales" options={COMMISSION_BASIS_OPTIONS} />
            </Field>
          </div>
          <div className="self-end">
            <Button type="submit">إضافة مندوب</Button>
          </div>
        </form>
      </Card>

      <RepresentativesTable representatives={(reps as Representative[]) ?? []} members={memberOptions} />
    </div>
  );
}
