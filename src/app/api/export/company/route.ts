import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { getMembership, getRoleKey } from "@/lib/org-context";
import { rateLimit, RATE_POLICIES } from "@/lib/rate-limit.server";
import { EXPORT_TABLES, MAX_ROWS_PER_SHEET, PAGE_SIZE, headerFor, planSheet, safeSheetName } from "@/lib/export/company-export";
import { cairoDate } from "@/lib/report-period";

// GET /api/export/company — the company's data as ONE Excel workbook (Arabic, right-to-left), one sheet per kind of record.
// Only the company OWNER may download it. It reads with the owner's own session (row-level security) and filters every table by their
// organization, so another company's rows cannot appear. Nothing is written or cached.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function GET() {
  const membership = await getMembership();
  if (!membership) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if ((await getRoleKey()) !== "owner") return NextResponse.json({ error: "forbidden" }, { status: 403 });
  const orgId = membership.organization_id as string;

  const limit = await rateLimit(RATE_POLICIES.companyExport, orgId);
  if (!limit.allowed) return NextResponse.json({ error: "too many requests", retryAfter: limit.retryAfter }, { status: 429 });

  const supabase = await createClient();
  const { data: org } = await supabase.from("organizations").select("name").eq("id", orgId).maybeSingle();

  const used = new Set<string>();
  const plans: { name: string; keys: string[]; rows: unknown[][] }[] = [];
  const notes: string[][] = [];
  for (const def of EXPORT_TABLES) {
    const records: Record<string, unknown>[] = [];
    let truncated = false, failed: string | null = null;
    for (let from = 0; ; from += PAGE_SIZE) {
      const { data, error } = await supabase.from(def.table).select("*").eq("organization_id", orgId).order("id").range(from, from + PAGE_SIZE - 1);
      if (error) { failed = error.message; break; }
      records.push(...((data ?? []) as Record<string, unknown>[]));
      if (!data || data.length < PAGE_SIZE) break;
      if (records.length >= MAX_ROWS_PER_SHEET) { truncated = true; break; }
    }
    if (failed) { notes.push([def.sheet, "لم يُصدَّر (غير متاح لهذا الدور أو غير موجود)"]); continue; }
    const plan = planSheet(def, records, truncated);
    if (plan.truncated) notes.push([def.sheet, `اقتُطع عند ${MAX_ROWS_PER_SHEET} سجل — صدّر هذه البيانات على دفعات من التقارير`]);
    plans.push({ name: safeSheetName(def.sheet, used), keys: plan.keys, rows: plan.rows });
  }

  const { default: writeExcelFile } = await import("write-excel-file/universal");
  const head = { fontWeight: "bold", textColor: "#FFFFFF", backgroundColor: "#344E41", alignVertical: "center" } as const;
  const sheets = [
    { sheet: safeSheetName("ملخص", used), rightToLeft: true, columns: [{ width: 28 }, { width: 60 }], data: [
      [{ value: org?.name ?? "كيان", fontWeight: "bold" }, { value: `تصدير بيانات الشركة — ${cairoDate()}` }],
      ...plans.map((p) => [{ value: p.name }, { value: p.rows.length, type: Number }]),
      ...notes.map(([a, b]) => [{ value: a, textColor: "#9C4F45" }, { value: b, textColor: "#9C4F45" }]),
    ] },
    ...plans.map((p) => ({
      sheet: p.name, rightToLeft: true, stickyRowsCount: 1,
      columns: p.keys.map(() => ({ width: 22 })),
      data: [
        p.keys.map((k) => ({ value: headerFor(k), ...head })),
        ...p.rows.map((r) => r.map((v) => (typeof v === "number" ? { value: v, type: Number } : typeof v === "boolean" ? { value: v, type: Boolean } : { value: v === null ? "" : String(v) }))),
      ],
    })),
  ];
  const blob = await writeExcelFile(sheets as any).toBlob();
  return new NextResponse(await blob.arrayBuffer(), {
    headers: {
      "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "Content-Disposition": `attachment; filename="kayan-export-${cairoDate()}.xlsx"`,
      "Cache-Control": "no-store",
    },
  });
}
