"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

// Confirms dispatch (sales) or receiving (purchases). Runs as the caller: the database function checks the
// warehouse.fulfill permission, refuses excess quantities and refuses a second confirmation of the same units.
export async function confirmFulfilment(input: {
  kind: "sales" | "purchase";
  invoiceId: string;
  lines: { line_id: string; quantity: number }[];
  note: string;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (!membership) return { error: "غير مصرح" };

  const lines = input.lines.filter((l) => Number(l.quantity) > 0);
  if (lines.length === 0) return { error: "أدخل كمية واحدة على الأقل" };

  const fn = input.kind === "sales" ? "confirm_sales_dispatch" : "confirm_purchase_receipt";
  const { error } = await supabase.rpc(fn, {
    org_id: membership.organization_id,
    p_invoice_id: input.invoiceId,
    p_lines: lines,
    p_note: input.note.trim() || null,
  });
  if (error) return { error: error.message };

  revalidatePath("/dashboard/warehouse-orders");
  revalidatePath("/dashboard/inventory");
  revalidatePath("/dashboard");
  return { error: null };
}
