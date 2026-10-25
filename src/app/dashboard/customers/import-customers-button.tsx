"use client";

import { CsvImportButton } from "@/components/import/csv-import-button";
import { importCustomersCsv, type CustomerImportRow } from "./actions";

const HEADERS = ["الاسم", "الهاتف", "نوع العميل (تجزئة/جملة/موزع)", "الرصيد الافتتاحي"];

export function ImportCustomersButton() {
  return (
    <CsvImportButton<CustomerImportRow>
      entityLabel="عملاء"
      templateName="قالب-استيراد-العملاء"
      headers={HEADERS}
      templateRow={["محل الأمل", "01000000000", "تجزئة", 1500]}
      // files made from the old template had five columns (name, phone, free-text type, price level, balance)
      parseRow={(c) => {
        const old = c.length >= 5;
        return { name: c[0] ?? "", phone: c[1] ?? "", price_tier: (old ? c[3] : c[2]) ?? "", opening_balance: Number((old ? c[4] : c[3]) || 0) };
      }}
      previewCells={(r) => [r.name, r.phone, r.price_tier, r.opening_balance]}
      onImport={importCustomersCsv}
    />
  );
}
