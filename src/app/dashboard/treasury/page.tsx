import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { TreasuryForm } from "./treasury-form";
import { TreasuryTable } from "./treasury-table";
import { OpeningBalanceCard } from "./opening-balance-card";
import { Money } from "@/components/ui/money";

export type MovementRow = {
  id: string;
  direction: "in" | "out";
  amount: number;
  category: string;
  movement_date: string;
  description: string | null;
};

export default async function TreasuryPage() {
  const supabase = await createClient();

  const [{ data: balances }, { data: movements }] = await Promise.all([
    supabase.from("treasury_balances").select("balance, opening_balance"),
    supabase
      .from("treasury_movements")
      .select("id, direction, amount, category, movement_date, description")
      .order("created_at", { ascending: false })
      .limit(100),
  ]);

  const totalBalance = (balances ?? []).reduce((sum, r) => sum + Number(r.balance), 0);
  const openingBalance = (balances ?? []).reduce((sum, r) => sum + Number(r.opening_balance), 0);

  return (
    <div>
      <PageHeader title="الخزنة" />

      <Card className="mb-7 p-5 sm:p-6">
        <p className="text-xs text-charcoal/45">الرصيد الحالي</p>
        <p className="mt-2 text-3xl font-semibold tracking-tight text-charcoal"><Money value={totalBalance} /></p>
      </Card>

      <OpeningBalanceCard openingBalance={openingBalance} />

      <TreasuryForm />

      <div className="mb-4 mt-9 text-xs font-medium text-charcoal/40">حركات الخزنة</div>
      <TreasuryTable movements={(movements as MovementRow[]) ?? []} />
    </div>
  );
}
