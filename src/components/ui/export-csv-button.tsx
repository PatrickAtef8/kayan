"use client";

import { Download } from "lucide-react";
import { downloadCsv } from "@/lib/csv";

export function ExportCsvButton({ filename, headers, rows }: { filename: string; headers: string[]; rows: (string | number | null | undefined)[][] }) {
  return (
    <button
      type="button"
      onClick={() => downloadCsv(filename, headers, rows)}
      className="flex items-center gap-1.5 rounded-lg border border-borderSoft px-3 py-2 text-xs font-medium text-charcoal/60 transition-colors hover:border-sage hover:text-sage"
    >
      <Download size={13} strokeWidth={2} />
      تصدير CSV
    </button>
  );
}
