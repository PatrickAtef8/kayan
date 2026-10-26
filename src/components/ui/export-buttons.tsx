"use client";

import { useState } from "react";
import { FileSpreadsheet, FileText } from "lucide-react";
import { useExportOrgName } from "@/components/ui/export-context";
import { saveBlob } from "@/lib/export/download";
import { MAX_PDF_ROWS, safeFileName, titleFromFilename, type Cell, type ExportSpec, type KindSpec, type ListFilters, type ListResult, type SummaryItem } from "@/lib/export/model";

const btn =
  "flex items-center gap-1.5 rounded-lg border border-borderSoft bg-white px-3 py-2 text-xs font-medium text-charcoal/60 transition-colors hover:border-sage hover:text-sage disabled:opacity-50";

/**
 * §56: Excel + PDF, both generated as real files from the same data (see src/lib/export/). There is no CSV: the
 * people using the system work in Excel and PDF.
 *
 * Only `filename`, `headers` and `rows` are required. `title` / `subtitle` / `kinds` / `summary` / `notes` make the
 * files read as proper reports: a title with the period, typed columns (money, dates, quantities…), totals for
 * columns marked ":sum", and key figures above the table.
 */
export function ExportButtons({
  filename,
  headers,
  rows,
  loadRows,
  loadFilters,
  title,
  subtitle,
  kinds,
  summary,
  notes,
}: {
  filename: string;
  headers: string[];
  /** The rows to export. Leave out when `loadRows` fetches them (long lists the page only shows 20 of). */
  rows?: Cell[][];
  /** Server action that returns ALL rows for the page's current filters; runs when a button is pressed. */
  loadRows?: (filters: ListFilters) => Promise<ListResult>;
  loadFilters?: ListFilters;
  title?: string;
  subtitle?: string;
  kinds?: KindSpec[];
  summary?: SummaryItem[];
  notes?: string[];
}) {
  const orgName = useExportOrgName();
  const [busy, setBusy] = useState<"excel" | "pdf" | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function run(kind: "excel" | "pdf") {
    if (busy) return;
    setError(null);
    setBusy(kind);
    // let the browser paint «جارٍ التجهيز...» before the heavy work starts
    await new Promise((r) => setTimeout(r, 30));
    try {
      let data: Cell[][] = rows ?? [];
      let allNotes = notes;
      if (loadRows) {
        const res = await loadRows(loadFilters ?? {});
        if (!res.ok) {
          setError(res.error);
          return;
        }
        data = res.rows;
        if (res.note) allNotes = [...(notes ?? []), res.note];
      }
      if (kind === "pdf" && data.length > MAX_PDF_ROWS) {
        setError(`التقرير كبير (${data.length.toLocaleString("ar-EG")} صف) — صدّره بصيغة Excel.`);
        return;
      }
      const spec: ExportSpec = { filename, title: title ?? titleFromFilename(filename), subtitle, headers, rows: data, kinds, summary, notes: allNotes, orgName };
      // Loaded on click so these libraries aren't part of every page's bundle.
      if (kind === "excel") {
        const { buildExcelBlob } = await import("@/lib/export/excel");
        saveBlob(await buildExcelBlob(spec), safeFileName(filename.replace(/\.xlsx$/i, ""), "xlsx"));
      } else {
        const { buildPdfBlob } = await import("@/lib/export/pdf");
        saveBlob(await buildPdfBlob(spec), safeFileName(filename.replace(/\.pdf$/i, ""), "pdf"));
      }
    } catch (e) {
      console.error("export failed", e);
      setError("تعذّر إنشاء الملف. حاول مرة أخرى.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="no-print flex flex-wrap items-center gap-2">
      <button type="button" disabled={busy !== null} onClick={() => run("excel")} className={btn}>
        <FileSpreadsheet size={13} strokeWidth={2} />
        {busy === "excel" ? "جارٍ تجهيز ملف Excel..." : "Excel"}
      </button>
      <button type="button" disabled={busy !== null} onClick={() => run("pdf")} className={btn}>
        <FileText size={13} strokeWidth={2} />
        {busy === "pdf" ? "جارٍ تجهيز ملف PDF..." : "PDF"}
      </button>
      {error ? (
        <span role="alert" className="text-xs text-rose">
          {error}
        </span>
      ) : null}
    </div>
  );
}
