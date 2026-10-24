import { redirect } from "next/navigation";
import { getRoleKey } from "@/lib/org-context";

export default async function ReportsIndex() {
  const role = await getRoleKey();
  redirect(role === "warehouse" ? "/dashboard/reports/inventory" : "/dashboard/reports/sales");
}
