"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Upload, FileUp } from "lucide-react";
import { Modal } from "@/components/ui/modal";
import { Button } from "@/components/ui/button";
import { parseCsv } from "@/lib/csv-parse";
import { downloadCsv } from "@/lib/csv";
import { importProductsCsv, type ProductImportRow, type ProductImportResult } from "./actions";

const EXPECTED_HEADERS = ["الاسم", "الكود", "الوحدة", "التكلفة", "سعر البيع", "الفئة", "الباركود", "حد الطلب", "وحدات/كرتونة"];

function rowsFromCsv(text: string): { rows: ProductImportRow[]; error: string | null } {
  const table = parseCsv(text);
  if (table.length === 0) return { rows: [], error: "الملف فارغ" };

  const [, ...dataRows] = table; // first row assumed to be the header — not validated column-by-column, just positional
  const rows: ProductImportRow[] = dataRows.map((cells) => ({
    name: cells[0] ?? "",
    sku: cells[1] ?? "",
    unit: cells[2] ?? "",
    cost: Number(cells[3] || 0),
    selling_price: Number(cells[4] || 0),
    category: cells[5] ?? "",
    barcode: cells[6] ?? "",
    reorder_level: Number(cells[7] || 0),
    units_per_carton: Number(cells[8] || 0),
  }));

  return { rows, error: null };
}

export function ImportProductsButton() {
  const router = useRouter();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<ProductImportRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<ProductImportResult | null>(null);
  const [pending, setPending] = useState(false);

  async function handleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;

    const text = await file.text();
    const parsed = rowsFromCsv(text);
    if (parsed.error) {
      setError(parsed.error);
      return;
    }
    setError(null);
    setResult(null);
    setRows(parsed.rows);
    setOpen(true);
  }

  async function submit() {
    setPending(true);
    const outcome = await importProductsCsv(rows);
    setPending(false);
    setResult(outcome);
    if (outcome.created > 0) router.refresh();
  }

  function downloadTemplate() {
    downloadCsv("قالب-استيراد-المنتجات", EXPECTED_HEADERS, [["منتج تجريبي", "SKU-001", "قطعة", 10, 15, "فئة تجريبية", "6221000000011", 20, 12]]);
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
      <button type="button" onClick={downloadTemplate} className="text-xs font-medium text-charcoal/40 hover:text-sage hover:underline">
        تنزيل نموذج
      </button>
      <input ref={fileInputRef} type="file" accept=".csv" className="hidden" onChange={handleFile} />

      <Modal open={open} onClose={() => setOpen(false)} title="استيراد منتجات من CSV">
        <div className="max-h-[65vh] space-y-4 overflow-y-auto">
          {!result ? (
            <>
              <p className="text-xs text-charcoal/50">
                تم العثور على <span className="font-medium text-charcoal">{rows.length}</span> صف. الأعمدة المتوقعة بالترتيب: {EXPECTED_HEADERS.join("، ")}.
              </p>
              <div className="max-h-64 overflow-auto rounded-lg border border-borderSoft">
                <table className="w-full text-right text-xs">
                  <thead className="bg-paper text-charcoal/40">
                    <tr>
                      {EXPECTED_HEADERS.map((h) => (
                        <th key={h} className="px-2.5 py-2 font-medium">{h}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {rows.slice(0, 20).map((r, i) => (
                      <tr key={i} className="border-t border-borderSoft">
                        <td className="px-2.5 py-1.5">{r.name}</td>
                        <td className="px-2.5 py-1.5">{r.sku}</td>
                        <td className="px-2.5 py-1.5">{r.unit}</td>
                        <td className="px-2.5 py-1.5" dir="ltr">{r.cost}</td>
                        <td className="px-2.5 py-1.5" dir="ltr">{r.selling_price}</td>
                        <td className="px-2.5 py-1.5">{r.category}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {rows.length > 20 && <p className="text-[0.6875rem] text-charcoal/35">...و{rows.length - 20} صف إضافي</p>}
              <div className="flex items-center gap-3">
                <Button type="button" disabled={pending} onClick={submit} className="flex items-center gap-1.5">
                  <FileUp size={14} strokeWidth={2} />
                  {pending ? "جارٍ الاستيراد..." : "استيراد الآن"}
                </Button>
              </div>
            </>
          ) : (
            <div>
              <p className="text-sm text-charcoal">
                تم إنشاء <span className="font-medium text-sage">{result.created}</span> منتج بنجاح.
              </p>
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
          {error && <p className="text-xs text-rose">{error}</p>}
        </div>
      </Modal>
    </div>
  );
}
