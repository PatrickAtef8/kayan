"use client";

import { CsvImportButton } from "@/components/import/csv-import-button";
import { importCustomersCsv, type CustomerImportRow } from "./actions";

const HEADERS = ["الاسم", "الهاتف", "نوع العميل", "مستوى السعر (تجزئة/جملة/موزع)", "الرصيد الافتتاحي"];

export function ImportCustomersButton() {
  return (
    <CsvImportButton<CustomerImportRow>
      entityLabel="عملاء"
      templateName="قالب-استيراد-العملاء"
      headers={HEADERS}
      templateRow={["محل الأمل", "01000000000", "تجزئة", "تجزئة", 1500]}
      parseRow={(c) => ({
        name: c[0] ?? "",
        phone: c[1] ?? "",
        customer_type: c[2] ?? "",
        price_tier: c[3] ?? "",
        opening_balance: Number(c[4] || 0),
      })}
      previewCells={(r) => [r.name, r.phone, r.customer_type, r.price_tier, r.opening_balance]}
      onImport={importCustomersCsv}
    />
  );
}
