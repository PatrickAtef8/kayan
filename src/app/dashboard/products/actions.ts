"use server";

import { revalidatePath } from "next/cache";
import { translateDbError } from "@/lib/db-errors";
import { createClient } from "@/lib/supabase/server";
import { AUTH_ERROR, NAME_REQUIRED } from "@/lib/action-result";
import { canEditCost, setProductCost } from "@/lib/costs";
import { insertChunked, insertManyChunked, upsertChunked, type BulkItem } from "@/lib/bulk";

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

// Phase 1 (reports package): barcode, reorder level, units per carton — all optional.
function readInventoryFields(formData: FormData) {
  const barcode = String(formData.get("barcode") || "").trim() || null;
  const levelRaw = String(formData.get("reorder_level") || "").trim();
  const cartonRaw = String(formData.get("units_per_carton") || "").trim();
  const reorderLevel = levelRaw ? Math.max(0, Number(levelRaw) || 0) : 0;
  const cartonNum = cartonRaw ? Number(cartonRaw) : null;
  const unitsPerCarton = cartonNum && cartonNum > 0 ? cartonNum : null;
  return { barcode, reorder_level: reorderLevel, units_per_carton: unitsPerCarton };
}

// A repeated barcode / SKU: say exactly which box is repeated and which product already uses it,
// instead of the generic "another record has the same data".
async function duplicateProductMessage(
  supabase: Awaited<ReturnType<typeof createClient>>,
  orgId: string,
  error: { code?: string; message?: string; details?: string | null } | null,
  fields: { barcode: string | null; sku: string | null },
  selfId?: string,
): Promise<string> {
  const generic = translateDbError(error, "products");
  if (error?.code !== "23505") return generic;
  const text = `${error.message ?? ""} ${error.details ?? ""}`;
  const col = /barcode/i.test(text) ? "barcode" : /sku/i.test(text) ? "sku" : null;
  if (!col) return generic;
  const value = fields[col];
  if (!value) return generic;
  let q = supabase.from("products").select("name").eq("organization_id", orgId).eq(col, value).limit(1);
  if (selfId) q = q.neq("id", selfId);
  const { data } = await q.maybeSingle();
  const label = col === "barcode" ? "الباركود" : "كود الصنف (SKU)";
  return data?.name
    ? `${label} "${value}" مستخدم بالفعل للمنتج «${data.name}» — غيّر ${label} في هذا المنتج أو عدّل المنتج الآخر.`
    : generic;
}

export async function createProduct(formData: FormData) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: AUTH_ERROR };

  const name = String(formData.get("name") || "").trim();
  if (!name) return { error: NAME_REQUIRED };

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

  const inventoryFields = readInventoryFields(formData);
  const { data: product, error } = await supabase
    .from("products")
    .insert({
      organization_id: membership.organization_id,
      category_id: categoryId,
      name,
      sku,
      unit,
      ...inventoryFields,
    })
    .select("id")
    .single();

  if (error || !product) {
    return { error: await duplicateProductMessage(supabase, membership.organization_id, error, { barcode: inventoryFields.barcode, sku }) };
  }

  const { error: priceError } = await supabase.from("product_prices").insert({
    organization_id: membership.organization_id,
    product_id: product.id,
    selling_price: sellingPrice,
    wholesale_price: wholesalePrice,
    distributor_price: distributorPrice,
  });
  if (priceError) return { error: translateDbError(priceError, "products") };

  // cost is stored in its own protected table (0034); only users allowed to edit cost may set it
  if (formData.has("cost") && cost > 0 && (await canEditCost(supabase, membership.organization_id))) {
    const costResult = await setProductCost(supabase, product.id, cost);
    if (costResult.error) return { error: `أُضيف المنتج لكن تعذّر حفظ التكلفة: ${costResult.error}` };
  }

  revalidatePath("/dashboard/products");
  return { error: null };
}

export async function updateProduct(id: string, formData: FormData) {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { error: AUTH_ERROR };

  const name = String(formData.get("name") || "").trim();
  if (!name) return { error: NAME_REQUIRED };

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

  const inventoryFields = readInventoryFields(formData);
  const { error: updateError } = await supabase
    .from("products")
    .update({ name, sku, unit, category_id: categoryId, ...inventoryFields })
    .eq("id", id);
  if (updateError) {
    return { error: await duplicateProductMessage(supabase, membership.organization_id, updateError, { barcode: inventoryFields.barcode, sku }, id) };
  }

  // One current price row per product (see 0004_master_data.sql) — upsert
  // rather than insert, since editing a product usually means changing a
  // price that already exists.
  const { error: priceError } = await supabase
    .from("product_prices")
    .upsert(
      { organization_id: membership.organization_id, product_id: id, selling_price: sellingPrice, wholesale_price: wholesalePrice, distributor_price: distributorPrice },
      { onConflict: "organization_id,product_id" }
    );
  if (priceError) return { error: translateDbError(priceError, "products") };

  if (formData.has("cost") && (await canEditCost(supabase, membership.organization_id))) {
    const costResult = await setProductCost(supabase, id, cost);
    if (costResult.error) return { error: costResult.error };
  }

  revalidatePath("/dashboard/products");
  return { error: null };
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

export type ProductImportRow = { name: string; sku: string; unit: string; cost: number; selling_price: number; category: string; barcode?: string; reorder_level?: number; units_per_carton?: number };
export type ProductImportResult = { created: number; skipped: { row: number; reason: string }[]; error: string | null };

// Import is postponed: there is no import screen right now (CSV was removed — users work with Excel and PDF only).
// This server action is kept, unchanged, for the upcoming Excel import; nothing calls it yet.
export async function importProducts(rows: ProductImportRow[]): Promise<ProductImportResult> {
  const supabase = await createClient();
  const membership = await getMembership(supabase);
  if (!membership) return { created: 0, skipped: [], error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  const orgId = membership.organization_id;
  const canSetCost = await canEditCost(supabase, orgId);

  const { data: existingCategories } = await supabase.from("product_categories").select("id, name").eq("organization_id", orgId);
  const categoryByName = new Map((existingCategories ?? []).map((c) => [c.name.trim(), c.id]));

  const { data: existingProducts } = await supabase.from("products").select("name").eq("organization_id", orgId);
  const existingNames = new Set((existingProducts ?? []).map((p) => p.name.trim()));

  const skipped: { row: number; reason: string }[] = [];

  // Pass 1 — validate each row and resolve its category. Categories are created one at a time (only the DISTINCT
  // missing ones, so a category created for row 2 is visible to row 5 when they share a name); a failed category is
  // remembered so its rows are skipped without retrying it.
  const failedCategories = new Set<string>();
  const items: BulkItem[] = [];
  const rowByName = new Map<string, ProductImportRow>();
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
      if (!categoryId && !failedCategories.has(categoryName)) {
        const { data: newCategory, error: categoryError } = await supabase
          .from("product_categories")
          .insert({ organization_id: orgId, name: categoryName })
          .select("id")
          .single();
        if (!categoryError && newCategory) {
          categoryId = newCategory.id;
          categoryByName.set(categoryName, newCategory.id);
        } else {
          failedCategories.add(categoryName);
        }
      }
      if (!categoryId) {
        skipped.push({ row: i + 1, reason: `تعذّر إنشاء الفئة: ${categoryName}` });
        continue;
      }
    }

    existingNames.add(name);
    rowByName.set(name, row);
    items.push({
      row: i + 1,
      data: {
        organization_id: orgId,
        category_id: categoryId,
        name,
        sku: row.sku.trim() || null,
        unit: row.unit.trim() || "قطعة",
        barcode: row.barcode?.trim() || null,
        reorder_level: row.reorder_level && row.reorder_level > 0 ? row.reorder_level : 0,
        units_per_carton: row.units_per_carton && row.units_per_carton > 0 ? row.units_per_carton : null,
      },
    });
  }

  // Pass 2 — products in chunks (one request per 200 products instead of one per product).
  const { inserted, failed } = await insertChunked(supabase, "products", items, "فشل إنشاء المنتج");
  for (const f of failed) skipped.push({ row: f.row, reason: f.error });

  // Pass 3 — prices and (for roles allowed to set it) costs, also in chunks. As before, a failure here does not
  // undo the product itself.
  const itemByRow = new Map(items.map((it) => [it.row, it.data.name]));
  const priced = inserted.map((r) => ({ id: r.id, row: rowByName.get(itemByRow.get(r.row) as string) as ProductImportRow }));
  await insertManyChunked(supabase, "product_prices", priced.map((p) => ({ organization_id: orgId, product_id: p.id, selling_price: p.row.selling_price || 0 })));
  if (canSetCost) {
    const costed = priced.filter((p) => p.row.cost > 0).map((p) => ({ product_id: p.id, cost: p.row.cost }));
    await upsertChunked(supabase, "product_costs", costed, "product_id");
  }
  const created = inserted.length;
  skipped.sort((a, b) => a.row - b.row);

  revalidatePath("/dashboard/products");
  return { created, skipped, error: null };
}
