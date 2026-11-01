"use server";

import { createClient } from "@/lib/supabase/server";
import { safeErrorMessage } from "@/lib/db-errors";

export type PricingPreview = {
  gross: number;
  line_discount: number;
  base: number;
  tier_discount: number;
  invoice_discount: number;
  cash_discount: number;
  tier_discount_pct: number;
  invoice_discount_pct: number;
  cash_discount_pct: number;
  discount_total: number;
  net: number;
  tax: number;
  total: number;
  bonus: { trigger: string; product: string; qty: number }[];
};

export type PricingPreviewInput = {
  applies_to: "sales" | "purchases";
  // every discount is a percentage (0–100)
  items: { product_id: string; quantity: number; unit_price?: number; unit_cost?: number; discount_pct: number }[];
  invoice_discount_pct: number;
  cash_discount_pct: number; // applies only when something is paid now (amount_paid > 0)
  amount_paid: number;
  tax: number;
  // bonus is entered by hand, never computed: { product_id, quantity } per free item
  bonus_items: { product_id: string; quantity: number }[];
};

// Same engine the invoice RPCs use (`_pricing`), so the screen shows exactly
// what will be posted: tier reached, whether the immediate-payment discount applies, bonus.
export async function previewPricing(input: PricingPreviewInput): Promise<{ preview: PricingPreview | null; error: string | null }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { preview: null, error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (!membership) return { preview: null, error: "غير مصرح" };

  const items = input.items.filter((i) => i.product_id && i.quantity > 0);
  if (items.length === 0) return { preview: null, error: null };

  const { data, error } = await supabase.rpc("pricing_preview", {
    org_id: membership.organization_id,
    p_applies: input.applies_to,
    items,
    p_invoice_discount_pct: input.invoice_discount_pct || 0,
    p_cash_discount_pct: input.cash_discount_pct || 0,
    p_amount_paid: input.amount_paid || 0,
    p_tax: input.tax || 0,
    p_bonus_items: input.bonus_items.filter((b) => b.product_id && b.quantity > 0),
  });
  if (error) return { preview: null, error: safeErrorMessage(error) };
  return { preview: data as PricingPreview, error: null };
}
