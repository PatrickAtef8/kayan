"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Upload, FileUp } from "lucide-react";
import { Modal } from "@/components/ui/modal";
import { Button } from "@/components/ui/button";
import { parseCsv } from "@/lib/csv-parse";
import { downloadCsv } from "@/lib/csv";

export type ImportResult = { created: number; skipped: { row: number; reason: string }[]; error: string | null };

// Generic CSV import flow (§56): pick file -> preview -> confirm -> per-row
// result. Entity-specific parts (columns, parsing, the server action) are
// passed in, so customers/suppliers/etc. share one UI.
export function CsvImportButton<T>({
  entityLabel,
  templateName,
  headers,
  templateRow,
  parseRow,
  previewCells,
  onImport,
}: {
  entityLabel: string;
  templateName: string;
  headers: string[];
  templateRow: (string | number)[];
  parseRow: (cells: string[]) => T;
  previewCells: (row: T) => (string | number)[];
  onImport: (rows: T[]) => Promise<ImportResult>;
}) {
  const router = useRouter();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<T[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<ImportResult | null>(null);
  const [pending, setPending] = useState(false);

  async function handleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;

    const table = parseCsv(await file.text());
    if (table.length < 2) {
      setError("الملف فارغ أو لا يحتوي على صفوف بيانات");
      return;
    }
    const [, ...dataRows] = table; // first row = header, positional columns
    setError(null);
    setResult(null);
    setRows(dataRows.map(parseRow));
    setOpen(true);
  }

  async function submit() {
    setPending(true);
    const outcome = await onImport(rows);
    setPending(false);
    setResult(outcome);
    if (outcome.created > 0) router.refresh();
  }

  return (
    <div className="flex items-center gap-2">
      <button
        type="button"
        onClick={() => fileInputRef.current?.click()}
        className="flex items-center gap-1.5 rounded-lg border border-borderSoft px-3 py-2 text-xs font-medium text-charcoal/60 transition-colors hover:border-sage hover:text-sage"
      >
        <Upload size={13} strokeWidth={2} />
        استيراد من CSV
      </button>
      <button type="button" onClick={() => downloadCsv(templateName, headers, [templateRow])} className="text-xs font-medium text-charcoal/40 hover:text-sage hover:underline">
        تنزيل نموذج
      </button>
      <input ref={fileInputRef} type="file" accept=".csv" className="hidden" onChange={handleFile} />
      {error && <span className="text-xs text-rose">{error}</span>}

      <Modal open={open} onClose={() => setOpen(false)} title={`استيراد ${entityLabel} من CSV`}>
        <div className="max-h-[65vh] space-y-4 overflow-y-auto">
          {!result ? (
            <>
              <p className="text-xs text-charcoal/50">
                تم العثور على <span className="font-medium text-charcoal">{rows.length}</span> صف. الأعمدة المتوقعة بالترتيب: {headers.join("، ")}.
              </p>
              <div className="max-h-64 overflow-auto rounded-lg border border-borderSoft">
                <table className="w-full text-right text-xs">
                  <thead className="bg-paper text-charcoal/40">
                    <tr>
                      {headers.map((h) => (
                        <th key={h} className="px-2.5 py-2 font-medium">
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {rows.slice(0, 20).map((r, i) => (
                      <tr key={i} className="border-t border-borderSoft">
                        {previewCells(r).map((cell, j) => (
                          <td key={j} className="px-2.5 py-1.5">
                            {cell}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {rows.length > 20 && <p className="text-[0.6875rem] text-charcoal/35">...و{rows.length - 20} صف إضافي</p>}
              <Button type="button" disabled={pending} onClick={submit} className="flex items-center gap-1.5">
                <FileUp size={14} strokeWidth={2} />
                {pending ? "جارٍ الاستيراد..." : "استيراد الآن"}
              </Button>
            </>
          ) : (
            <div>
              {result.error ? (
                <p className="text-sm text-rose">{result.error}</p>
              ) : (
                <p className="text-sm text-charcoal">
                  تم إنشاء <span className="font-medium text-sage">{result.created}</span> سجل بنجاح.
                </p>
              )}
              {result.skipped.length > 0 && (
                <div className="mt-3">
                  <p className="mb-1.5 text-xs font-medium text-charcoal/50">تم تخطي {result.skipped.length} صف:</p>
                  <ul className="space-y-1 text-xs text-rose">
                    {result.skipped.map((s) => (
                      <li key={s.row}>
                        صف {s.row}: {s.reason}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
              <Button type="button" className="mt-4" onClick={() => setOpen(false)}>
                إغلاق
              </Button>
            </div>
          )}
        </div>
      </Modal>
    </div>
  );
}
