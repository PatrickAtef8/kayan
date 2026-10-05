"use client";

import { CsvImportButton } from "@/components/import/csv-import-button";
import { importSuppliersCsv, type SupplierImportRow } from "./actions";

const HEADERS = ["الاسم", "الهاتف", "الرصيد الافتتاحي"];

export function ImportSuppliersButton() {
  return (
    <CsvImportButton<SupplierImportRow>
      entityLabel="موردين"
      templateName="قالب-استيراد-الموردين"
      headers={HEADERS}
      templateRow={["مصنع الفا", "01000000000", 8000]}
      parseRow={(c) => ({ name: c[0] ?? "", phone: c[1] ?? "", opening_balance: Number(c[2] || 0) })}
      previewCells={(r) => [r.name, r.phone, r.opening_balance]}
      onImport={importSuppliersCsv}
    />
  );
}
