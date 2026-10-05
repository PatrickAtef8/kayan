import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { SearchBox } from "@/components/ui/search-box";
import { Pagination } from "@/components/ui/pagination";
import { createProduct } from "./actions";
import { ProductsTable } from "./products-table";
import { AutoFocusNewProduct } from "./auto-focus-new-product";
import { ImportProductsButton } from "./import-products-button";

const PAGE_SIZE = 20;

type ProductRow = {
  id: string;
  name: string;
  sku: string | null;
  unit: string;
  category_id: string | null;
  product_categories: { name: string } | null;
  product_prices: { cost: number; selling_price: number; wholesale_price: number | null; distributor_price: number | null }[];
};

export default async function ProductsPage({ searchParams }: { searchParams: { q?: string; page?: string } }) {
  const supabase = createClient();
  const page = Math.max(1, Number(searchParams.page) || 1);
  const q = searchParams.q?.trim() ?? "";

  let productsQuery = supabase
    .from("products")
    .select("id, name, sku, unit, category_id, product_categories(name), product_prices(cost, selling_price, wholesale_price, distributor_price)", { count: "exact" })
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (q) productsQuery = productsQuery.or(`name.ilike.%${q}%,sku.ilike.%${q}%`);

  const [{ data: products, count }, { data: categories }] = await Promise.all([
    productsQuery,
    supabase.from("product_categories").select("id, name").order("name"),
  ]);

  return (
    <div>
      <PageHeader title="المنتجات" action={<ImportProductsButton />} />
      <AutoFocusNewProduct />

      <Card className="mb-7 p-5 sm:p-6" id="add-product-form">
        <form action={createProduct} className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <Field label="اسم المنتج">
            <Input id="product-name-input" name="name" required placeholder="مثال: زيت عباد الشمس 1 لتر" />
          </Field>
          <Field label="كود المنتج (SKU)">
            <Input name="sku" dir="ltr" placeholder="اختياري" />
          </Field>
          <Field label="وحدة القياس">
            <Input name="unit" defaultValue="قطعة" />
          </Field>

          <Field label="التصنيف">
            <ModernSelect name="category_id" options={(categories ?? []).map((c) => ({ value: c.id, label: c.name }))} />
          </Field>
          <Field label="أو تصنيف جديد">
            <Input name="new_category" placeholder="اكتب اسم تصنيف جديد" />
          </Field>
          <div />

          <Field label="التكلفة">
            <Input name="cost" type="number" step="0.01" dir="ltr" defaultValue={0} />
          </Field>
          <Field label="سعر البيع (تجزئة)">
            <Input name="selling_price" type="number" step="0.01" dir="ltr" defaultValue={0} />
          </Field>
          <div />
          <Field label="سعر الجملة (اختياري)">
            <Input name="wholesale_price" type="number" step="0.01" dir="ltr" placeholder="بلا — يُستخدم سعر التجزئة" />
          </Field>
          <Field label="سعر الموزع (اختياري)">
            <Input name="distributor_price" type="number" step="0.01" dir="ltr" placeholder="بلا — يُستخدم سعر التجزئة" />
          </Field>
          <div className="self-end">
            <Button type="submit">إضافة منتج</Button>
          </div>
        </form>
      </Card>

      <div className="mb-4">
        <SearchBox placeholder="بحث بالاسم أو الكود..." />
      </div>

      <ProductsTable products={(products as unknown as ProductRow[]) ?? []} categories={categories ?? []} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
