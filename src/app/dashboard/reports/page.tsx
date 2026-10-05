import { redirect } from "next/navigation";
import { isRestrictedRep } from "@/lib/org-context";

export default async function ReportsIndexPage() {
  redirect((await isRestrictedRep()) ? "/dashboard/reports/debts" : "/dashboard/reports/sales");
}
