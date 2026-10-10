"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

// Notes are plain text rows (party_notes). Nothing in the accounting reads them.
export async function addPartyNote(input: { party_type: "customer" | "supplier"; party_id: string; note: string; invoice_id?: string }) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "غير مصرح — يرجى تسجيل الدخول مجددًا" };
  const { data: membership } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).eq("status", "active").order("created_at", { ascending: true }).limit(1).maybeSingle();
  if (!membership) return { error: "غير مصرح" };
  const note = input.note.trim();
  if (!note) return { error: "اكتب الملاحظة أولًا" };

  const { error } = await supabase.from("party_notes").insert({
    organization_id: membership.organization_id,
    party_type: input.party_type,
    customer_id: input.party_type === "customer" ? input.party_id : null,
    supplier_id: input.party_type === "supplier" ? input.party_id : null,
    sales_invoice_id: input.party_type === "customer" ? input.invoice_id ?? null : null,
    note,
    created_by: user.id,
  });
  if (error) return { error: error.code === "42501" ? "ليس لديك صلاحية إضافة ملاحظة هنا" : error.message };
  revalidatePath(`/dashboard/reports/${input.party_type === "customer" ? "customers" : "suppliers"}/${input.party_id}`);
  return { error: null };
}
