import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { createWarehouse } from "./actions";
import { WarehousesTable } from "./warehouses-table";

type Warehouse = { id: string; name: string; location: string | null };

export default async function WarehousesPage() {
  const supabase = await createClient();
  const { data: warehouses } = await supabase
    .from("warehouses")
    .select("id, name, location")
    .order("created_at", { ascending: false });

  return (
    <div>
      <PageHeader title="المخازن" />

      <Card className="mb-7 p-5 sm:p-6">
        <form action={createWarehouse} className="grid grid-cols-1 gap-4 sm:grid-cols-3 sm:items-end">
          <Field label="اسم المخزن">
            <Input name="name" required placeholder="مثال: المخزن الرئيسي" />
          </Field>
          <Field label="الموقع">
            <Input name="location" placeholder="مثال: القاهرة - مدينة نصر" />
          </Field>
          <div className="self-end">
            <Button type="submit">إضافة مخزن</Button>
          </div>
        </form>
      </Card>

      <WarehousesTable warehouses={(warehouses as Warehouse[]) ?? []} />
    </div>
  );
}
