import type { SupabaseClient } from "@supabase/supabase-js";
import { PRICING_CONFIG } from "../../config/pricing.config.ts";
import { resolvePricingConfig, type PricingConfig } from "./pricing.ts";

/**
 * The pricing configuration in force RIGHT NOW: the values shipped in src/config/pricing.config.ts, with whatever the Super
 * Admin saved (platform_pricing_config) laid over them. Read on every request that shows or charges a price — that is what
 * makes an edit take effect without a redeploy. Any problem reading it falls back to the shipped values, so a database
 * hiccup can never produce a wrong or empty price list.
 */
export async function loadPricingConfig(client: SupabaseClient): Promise<{ config: PricingConfig; custom: boolean; updatedAt: string | null }> {
  const base = PRICING_CONFIG as PricingConfig;
  try {
    const { data, error } = await client.from("platform_pricing_config").select("config, updated_at").eq("id", 1).maybeSingle();
    if (error || !data) return { config: base, custom: false, updatedAt: null };
    const r = resolvePricingConfig(data.config, base);
    return { config: r.config, custom: r.custom, updatedAt: r.custom ? (data.updated_at as string) : null };
  } catch {
    return { config: base, custom: false, updatedAt: null };
  }
}
