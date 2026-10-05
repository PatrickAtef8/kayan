"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { MODULES, type ModuleKey } from "@/lib/modules";

export async function toggleModule(moduleKey: ModuleKey, enabled: boolean) {
  const supabase = createClient();
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

  const target = MODULES.find((m) => m.key === moduleKey);
  if (!target || ("core" in target && target.core)) return { error: "لا يمكن تعطيل هذه الوحدة الأساسية" };

  const { error } = await supabase
    .from("organization_modules")
    .upsert({ organization_id: membership.organization_id, module_key: moduleKey, enabled }, { onConflict: "organization_id,module_key" });
  if (error) return { error: error.message };

  revalidatePath("/dashboard/settings/modules");
  revalidatePath("/dashboard");
  return { error: null };
}
