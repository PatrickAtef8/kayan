import { createClient } from "@/lib/supabase/server";
import { getMembership, getRoleKey } from "@/lib/org-context";
import { canViewCost, canEditCost, getProductCosts } from "@/lib/costs";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { ActionForm, SubmitButton } from "@/components/ui/action-form";
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
  barcode: string | null;
  reorder_level: number;
  units_per_carton: number | null;
  unit: string;
  category_id: string | null;
  product_categories: { name: string } | null;
  product_prices: { cost: number; selling_price: number; wholesale_price: number | null; distributor_price: number | null }[];
};

export default async function ProductsPage(props: { searchParams: Promise<{ q?: string; page?: string }> }) {
  const searchParams = await props.searchParams;
  const supabase = await createClient();
  const page = Math.max(1, Number(searchParams.page) || 1);
  const q = searchParams.q?.trim() ?? "";

  let productsQuery = supabase
    .from("products")
    .select("id, name, sku, barcode, reorder_level, units_per_carton, unit, category_id, product_categories(name), product_prices(selling_price, wholesale_price, distributor_price)", { count: "exact" })
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (q) productsQuery = productsQuery.or(`name.ilike.%${q}%,sku.ilike.%${q}%,barcode.ilike.%${q}%`);

  const [{ data: products, count }, { data: categories }] = await Promise.all([
    productsQuery,
    supabase.from("product_categories").select("id, name").order("name"),
  ]);

  // cost comes from its own protected table (0034); empty for roles that may not read it
  const membership = await getMembership();
  const isOwner = (await getRoleKey()) === "owner";   // the storekeeper reads the catalogue: no prices, no editing
  const viewCost = membership ? await canViewCost(supabase, membership.organization_id) : false;
  const editCost = membership ? await canEditCost(supabase, membership.organization_id) : false;
  const costMap = viewCost ? await getProductCosts(supabase, (products ?? []).map((p) => p.id as string)) : new Map<string, number>();
  const productsView = (products ?? []).map((p) => ({
    ...p,
    product_prices: ((p.product_prices as unknown as object[]) ?? []).map((pp) => ({ ...pp, cost: costMap.get(p.id as string) ?? 0 })),
  }));

  return (
    <div>
      <PageHeader title="المنتجات" action={isOwner ? <ImportProductsButton /> : undefined} />
      <AutoFocusNewProduct />

      {isOwner && <Card className="mb-7 p-5 sm:p-6" id="add-product-form">
        <ActionForm action={createProduct} successText="تمت إضافة المنتج بنجاح" className="grid grid-cols-1 gap-4 sm:grid-cols-3">
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
          <Field label="الباركود">
            <Input name="barcode" dir="ltr" placeholder="اختياري — لا يتكرر" />
          </Field>

          <Field label="حد الطلب (الحد الأدنى للمخزون)">
            <Input name="reorder_level" type="number" step="0.001" min="0" dir="ltr" defaultValue={0} />
          </Field>
          <Field label="عدد الوحدات في الكرتونة">
            <Input name="units_per_carton" type="number" step="0.001" min="0" dir="ltr" placeholder="اختياري" />
          </Field>
          <div />

          {editCost && (<Field label="التكلفة">
            <Input name="cost" type="number" step="0.01" dir="ltr" defaultValue={0} />
          </Field>)}
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
            <SubmitButton pendingText="جارٍ إضافة المنتج...">إضافة منتج</SubmitButton>
          </div>
        </ActionForm>
      </Card>}

      <div className="mb-4">
        <SearchBox placeholder="بحث بالاسم أو الكود أو الباركود..." />
      </div>

      <ProductsTable readOnly={!isOwner} canViewCost={viewCost} canEditCost={editCost} products={productsView as unknown as ProductRow[]} categories={categories ?? []} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
