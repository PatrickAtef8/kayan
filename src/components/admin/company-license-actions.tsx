"use client";

import { ConfirmAction } from "./confirm-action";
import { grantComplimentary, revokeComplimentary, deleteCompany } from "@/app/admin/actions";

export function CompanyLicenseActions({ orgId, name, complimentary, hasPaidLicense }: { orgId: string; name: string; complimentary: boolean; hasPaidLicense: boolean }) {
  const del = (
    <ConfirmAction label="حذف الشركة نهائيًا" tone="danger" redirectTo="/admin/companies" title="حذف الشركة نهائيًا؟"
      description={`ستُحذف «${name}» وكل بياناتها (الفواتير والمخزون والخزنة والأعضاء والسجلات) ولا يمكن التراجع. يُحفظ سجل المراجعة وسجل المدفوعات في أرشيف قبل الحذف، وتُحذف مرفقاتها من التخزين. حسابات أعضائها تبقى موجودة بلا شركة. تأكد من وجود نسخة احتياطية حديثة لقاعدة البيانات.`}
      confirmLabel="حذف الشركة" requireText={name} run={(typed) => deleteCompany(orgId, typed)} />
  );
  return (
    <div className="space-y-3">
      {hasPaidLicense ? <p className="text-xs text-charcoal/45">للشركة باقة مدفوعة — لا يُستبدل بها وصول مجاني.</p> : (
        <div>
          {complimentary
            ? <ConfirmAction label="إلغاء الوصول المجاني" title="إلغاء الوصول المجاني؟" description={`ستعود «${name}» إلى وضع «بلا باقة» كما كانت قبل المنحة، ولا يُحذف أي من بياناتها.`} confirmLabel="إلغاء الوصول المجاني" run={() => revokeComplimentary(orgId)} />
            : <ConfirmAction label="منح وصول مجاني كامل" title="منح وصول مجاني؟" description={`ستحصل «${name}» على كل الوحدات بلا حد للفريق أو المخازن، بلا أي دفع وبلا انتهاء. لا يتأثر أي عميل آخر.`} confirmLabel="منح الوصول" run={() => grantComplimentary(orgId)} />}
        </div>
      )}
      <div>{del}</div>
    </div>
  );
}
