"use client";

import { useState } from "react";
import { Download, FileSpreadsheet, Printer } from "lucide-react";
import { downloadCsv } from "@/lib/csv";

type Cell = string | number | null | undefined;

const btn =
  "flex items-center gap-1.5 rounded-lg border border-borderSoft bg-white px-3 py-2 text-xs font-medium text-charcoal/60 transition-colors hover:border-sage hover:text-sage disabled:opacity-50";

// §56: CSV + Excel + PDF. PDF is the browser's own print-to-PDF against a
// print stylesheet (see globals.css) rather than a JS PDF library: client-side
// PDF generators don't shape or join Arabic text or lay out RTL reliably, while
// the browser's renderer does both correctly.
export function ExportButtons({ filename, headers, rows }: { filename: string; headers: string[]; rows: Cell[][] }) {
  const [busy, setBusy] = useState(false);

  async function exportExcel() {
    setBusy(true);
    try {
      // Loaded on click so the library isn't in every page's bundle.
      const { default: writeExcelFile } = await import("write-excel-file/browser");
      const sheetData = [
        headers.map((h) => ({ value: h, fontWeight: "bold" as const })),
        ...rows.map((row) => row.map((cell) => (cell === null || cell === undefined || cell === "" ? null : typeof cell === "number" ? cell : String(cell)))),
      ];
      await writeExcelFile(sheetData, { rightToLeft: true, columns: headers.map(() => ({ width: 22 })) }).toFile(filename.endsWith(".xlsx") ? filename : `${filename}.xlsx`);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="no-print flex flex-wrap items-center gap-2">
      <button type="button" onClick={() => downloadCsv(filename, headers, rows)} className={btn}>
        <Download size={13} strokeWidth={2} />
        CSV
      </button>
      <button type="button" disabled={busy} onClick={exportExcel} className={btn}>
        <FileSpreadsheet size={13} strokeWidth={2} />
        {busy ? "جارٍ التجهيز..." : "Excel"}
      </button>
      <button type="button" onClick={() => window.print()} className={btn}>
        <Printer size={13} strokeWidth={2} />
        PDF / طباعة
      </button>
    </div>
  );
}
