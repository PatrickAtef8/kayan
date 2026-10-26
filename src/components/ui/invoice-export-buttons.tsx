"use client";

import { useState } from "react";
import { FileSpreadsheet, FileText } from "lucide-react";
import { useExportOrgName } from "@/components/ui/export-context";
import { saveBlob } from "@/lib/export/download";
import { invoiceFileName, type InvoiceDoc } from "@/lib/export/invoice-model";
import { safeFileName } from "@/lib/export/model";

/**
 * Exports ONE invoice as a finished document (PDF or Excel): header, party, items, totals, payments, balance.
 * `variant="icons"` is the compact pair used inside table rows; `"full"` the labelled buttons for the details dialog.
 * The document is built only when a button is pressed; the PDF/Excel code is loaded then too.
 */
export function InvoiceExportButtons({ build, variant = "icons" }: { build: (orgName?: string) => InvoiceDoc; variant?: "icons" | "full" }) {
  const orgName = useExportOrgName();
  const [busy, setBusy] = useState<"pdf" | "excel" | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function run(kind: "pdf" | "excel") {
    if (busy) return;
    setBusy(kind);
    setError(null);
    await new Promise((r) => setTimeout(r, 30)); // let the button show «busy» first
    try {
      const doc = build(orgName);
      if (kind === "pdf") {
        const { buildInvoicePdfBlob } = await import("@/lib/export/invoice-pdf");
        saveBlob(await buildInvoicePdfBlob(doc), safeFileName(invoiceFileName(doc), "pdf"));
      } else {
        const { buildInvoiceExcelBlob } = await import("@/lib/export/invoice-excel");
        saveBlob(await buildInvoiceExcelBlob(doc), safeFileName(invoiceFileName(doc), "xlsx"));
      }
    } catch (e) {
      console.error("invoice export failed", e);
      setError("تعذّر إنشاء الملف. حاول مرة أخرى.");
    } finally {
      setBusy(null);
    }
  }

  if (variant === "icons") {
    const icon = "rounded-card p-1.5 text-ink/40 transition-colors hover:bg-paper hover:text-sage disabled:opacity-40";
    return (
      <>
        <button type="button" disabled={busy !== null} onClick={() => run("pdf")} className={icon} title="تصدير الفاتورة PDF" aria-label="تصدير الفاتورة PDF">
          <FileText size={16} strokeWidth={2} className={busy === "pdf" ? "animate-pulse" : ""} />
        </button>
        <button type="button" disabled={busy !== null} onClick={() => run("excel")} className={icon} title="تصدير الفاتورة Excel" aria-label="تصدير الفاتورة Excel">
          <FileSpreadsheet size={16} strokeWidth={2} className={busy === "excel" ? "animate-pulse" : ""} />
        </button>
      </>
    );
  }

  const btn = "flex items-center gap-1.5 rounded-lg border border-borderSoft bg-white px-3 py-2 text-xs font-medium text-charcoal/60 transition-colors hover:border-sage hover:text-sage disabled:opacity-50";
  return (
    <div className="flex flex-wrap items-center gap-2">
      <button type="button" disabled={busy !== null} onClick={() => run("pdf")} className={btn}>
        <FileText size={13} strokeWidth={2} />
        {busy === "pdf" ? "جارٍ تجهيز الفاتورة..." : "تصدير الفاتورة PDF"}
      </button>
      <button type="button" disabled={busy !== null} onClick={() => run("excel")} className={btn}>
        <FileSpreadsheet size={13} strokeWidth={2} />
        {busy === "excel" ? "جارٍ تجهيز الفاتورة..." : "تصدير الفاتورة Excel"}
      </button>
      {error ? (
        <span role="alert" className="text-xs text-rose">
          {error}
        </span>
      ) : null}
    </div>
  );
}
