import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { ActionForm, SubmitButton } from "@/components/ui/action-form";
import { createPartner } from "./actions";
import { PartnersTable } from "./partners-table";

export type Partner = { id: string; name: string; phone: string | null };
export type WithdrawalRow = {
  id: string;
  amount: number;
  withdrawal_date: string;
  description: string | null;
  partners: { name: string } | null;
};

export default async function PartnersPage() {
  const supabase = await createClient();

  const [{ data: partners }, { data: withdrawals }] = await Promise.all([
    supabase.from("partners").select("id, name, phone").order("created_at", { ascending: false }),
    supabase
      .from("partner_withdrawals")
      .select("id, amount, withdrawal_date, description, partners(name)")
      .order("created_at", { ascending: false }),
  ]);

  return (
    <div>
      <PageHeader title="الشركاء" />

      <Card className="mb-7 p-5 sm:p-6">
        <ActionForm action={createPartner} successText="تمت إضافة الشريك بنجاح" className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <Field label="اسم الشريك">
            <Input name="name" required placeholder="مثال: أحمد محمد" />
          </Field>
          <Field label="رقم الهاتف">
            <Input name="phone" dir="ltr" placeholder="اختياري" />
          </Field>
          <div className="self-end">
            <SubmitButton pendingText="جارٍ إضافة الشريك...">إضافة شريك</SubmitButton>
          </div>
        </ActionForm>
      </Card>

      <div className="mb-4 text-xs font-medium text-charcoal/40">الشركاء</div>
      <PartnersTable partners={(partners as Partner[]) ?? []} />

      <div className="mb-4 mt-9 text-xs font-medium text-charcoal/40">سجل السحوبات</div>
      <WithdrawalsTable withdrawals={(withdrawals as unknown as WithdrawalRow[]) ?? []} />
    </div>
  );
}

function WithdrawalsTable({ withdrawals }: { withdrawals: WithdrawalRow[] }) {
  if (withdrawals.length === 0) {
    return <p className="rounded-2xl border border-dashed border-borderSoft p-6 text-center text-sm text-charcoal/40">لا توجد سحوبات مسجلة بعد</p>;
  }
  return (
    <div className="divide-y divide-borderSoft rounded-2xl border border-borderSoft bg-white">
      {withdrawals.map((w) => (
        <div key={w.id} className="flex items-center justify-between px-4 py-3 text-sm">
          <div>
            <p className="text-charcoal">{w.partners?.name ?? "—"}</p>
            {w.description && <p className="mt-0.5 text-xs text-charcoal/40">{w.description}</p>}
          </div>
          <div className="text-left">
            <p className="font-medium text-rose" dir="ltr">
              − {w.amount.toLocaleString("ar-EG", { minimumFractionDigits: 2 })} ج.م
            </p>
            <p className="text-xs text-charcoal/35" dir="ltr">{w.withdrawal_date}</p>
          </div>
        </div>
      ))}
    </div>
  );
}
