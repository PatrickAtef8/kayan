"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";
import { canEditCost, setProductCost } from "@/lib/costs";

async function getMembership(supabase: Awaited<ReturnType<typeof createClient>>) {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  return membership;
}

export async function createProduct(formData: FormData) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return;

  const name = String(formData.get("name") || "").trim();
  if (!name) return;

  let categoryId = String(formData.get("category_id") || "") || null;
  const newCategory = String(formData.get("new_category") || "").trim();

  // A typed-in new category takes priority over the dropdown selection.
  if (newCategory) {
    const { data: category } = await supabase
      .from("product_categories")
      .insert({ organization_id: membership.organization_id, name: newCategory })
      .select("id")
      .single();
    categoryId = category?.id ?? null;
  }

  const sku = String(formData.get("sku") || "").trim() || null;
  const unit = String(formData.get("unit") || "").trim() || "قطعة";
  const cost = Number(formData.get("cost") || 0);
  const sellingPrice = Number(formData.get("selling_price") || 0);
  const wholesalePriceRaw = String(formData.get("wholesale_price") || "").trim();
  const distributorPriceRaw = String(formData.get("distributor_price") || "").trim();
  const wholesalePrice = wholesalePriceRaw ? Number(wholesalePriceRaw) : null;
  const distributorPrice = distributorPriceRaw ? Number(distributorPriceRaw) : null;

  const { data: product, error } = await supabase
    .from("products")
    .insert({
      organization_id: membership.organization_id,
      category_id: categoryId,
      name,
      sku,
      unit,
    })
    .select("id")
    .single();

  if (error || !product) return;

  await supabase.from("product_prices").insert({
    organization_id: membership.organization_id,
    product_id: product.id,
    selling_price: sellingPrice,
    wholesale_price: wholesalePrice,
    distributor_price: distributorPrice,
  });

  // cost is stored in its own protected table (0034); only users allowed to edit cost may set it
  if (formData.has("cost") && cost > 0 && (await canEditCost(supabase, membership.organization_id))) {
    await setProductCost(supabase, product.id, cost);
  }

  revalidatePath("/dashboard/products");
}

export async function updateProduct(id: string, formData: FormData) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return;

  const name = String(formData.get("name") || "").trim();
  if (!name) return;

  let categoryId = String(formData.get("category_id") || "") || null;
  const newCategory = String(formData.get("new_category") || "").trim();

  if (newCategory) {
    const { data: category } = await supabase
      .from("product_categories")
      .insert({ organization_id: membership.organization_id, name: newCategory })
      .select("id")
      .single();
    categoryId = category?.id ?? null;
  }

  const sku = String(formData.get("sku") || "").trim() || null;
  const unit = String(formData.get("unit") || "").trim() || "قطعة";
  const cost = Number(formData.get("cost") || 0);
  const sellingPrice = Number(formData.get("selling_price") || 0);
  const wholesalePriceRaw = String(formData.get("wholesale_price") || "").trim();
  const distributorPriceRaw = String(formData.get("distributor_price") || "").trim();
  const wholesalePrice = wholesalePriceRaw ? Number(wholesalePriceRaw) : null;
  const distributorPrice = distributorPriceRaw ? Number(distributorPriceRaw) : null;

  await supabase
    .from("products")
    .update({ name, sku, unit, category_id: categoryId })
    .eq("id", id);

  // One current price row per product (see 0004_master_data.sql) — upsert
  // rather than insert, since editing a product usually means changing a
  // price that already exists.
  await supabase
    .from("product_prices")
    .upsert(
      { organization_id: membership.organization_id, product_id: id, selling_price: sellingPrice, wholesale_price: wholesalePrice, distributor_price: distributorPrice },
      { onConflict: "organization_id,product_id" }
    );

  if (formData.has("cost") && (await canEditCost(supabase, membership.organization_id))) {
    await setProductCost(supabase, id, cost);
  }

  revalidatePath("/dashboard/products");
}

export async function deleteProduct(id: string) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { error } = await supabase.from("products").delete().eq("id", id);
  if (error) return { error: translateDbError(error, "products") };

  revalidatePath("/dashboard/products");
  return { error: null };
}

export type ProductImportRow = { name: string; sku: string; unit: string; cost: number; selling_price: number; category: string };
export type ProductImportResult = { created: number; skipped: { row: number; reason: string }[]; error: string | null };

export async function importProductsCsv(rows: ProductImportRow[]): Promise<ProductImportResult> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { created: 0, skipped: [], error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  const orgId = membership.organization_id;
  const canSetCost = await canEditCost(supabase, orgId);

  const { data: existingCategories } = await supabase.from("product_categories").select("id, name").eq("organization_id", orgId);
  const categoryByName = new Map((existingCategories ?? []).map((c) => [c.name.trim(), c.id]));

  const { data: existingProducts } = await supabase.from("products").select("name").eq("organization_id", orgId);
  const existingNames = new Set((existingProducts ?? []).map((p) => p.name.trim()));

  let created = 0;
  const skipped: { row: number; reason: string }[] = [];

  // Sequential, not Promise.all — a category created for row 2 needs to be
  // visible to row 5 if they share a name, and this is a background,
  // occasional bulk action, not something latency-sensitive (§56).
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const name = row.name.trim();
    if (!name) {
      skipped.push({ row: i + 1, reason: "اسم المنتج مطلوب" });
      continue;
    }
    if (existingNames.has(name)) {
      skipped.push({ row: i + 1, reason: `منتج بهذا الاسم موجود بالفعل: ${name}` });
      continue;
    }

    let categoryId: string | null = null;
    const categoryName = row.category.trim();
    if (categoryName) {
      categoryId = categoryByName.get(categoryName) ?? null;
      if (!categoryId) {
        const { data: newCategory, error: categoryError } = await supabase
          .from("product_categories")
          .insert({ organization_id: orgId, name: categoryName })
          .select("id")
          .single();
        if (categoryError || !newCategory) {
          skipped.push({ row: i + 1, reason: `تعذّر إنشاء الفئة: ${categoryName}` });
          continue;
        }
        categoryId = newCategory.id;
        categoryByName.set(categoryName, categoryId);
      }
    }

    const { data: product, error: productError } = await supabase
      .from("products")
      .insert({ organization_id: orgId, category_id: categoryId, name, sku: row.sku.trim() || null, unit: row.unit.trim() || "قطعة" })
      .select("id")
      .single();

    if (productError || !product) {
      skipped.push({ row: i + 1, reason: productError?.message ?? "فشل إنشاء المنتج" });
      continue;
    }

    await supabase.from("product_prices").insert({
      organization_id: orgId,
      product_id: product.id,
      selling_price: row.selling_price || 0,
    });
    if (canSetCost && row.cost > 0) await setProductCost(supabase, product.id, row.cost);

    existingNames.add(name);
    created++;
  }

  revalidatePath("/dashboard/products");
  return { created, skipped, error: null };
}
