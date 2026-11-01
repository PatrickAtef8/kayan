import { Card } from "@/components/ui/card";
import { AdminHeader } from "@/components/admin/admin-header";
import { LegalEditor, type LegalDocForEditor } from "@/components/admin/legal-editor";
import { requireSuperAdminPage } from "@/lib/admin/auth.server";
import { createAdminClient } from "@/lib/supabase/admin";
import { LEGAL_DEFAULTS, LEGAL_KEYS, LEGAL_PATH } from "@/config/legal.defaults";

const LABEL = { terms: "الشروط والأحكام", privacy: "سياسة الخصوصية", refund: "الإلغاء والاسترداد" } as const;

export default async function AdminLegalPage() {
  await requireSuperAdminPage();
  const admin = createAdminClient();
  const [d, s] = await Promise.all([
    admin.from("legal_documents").select("doc_key, version, title_ar, body_ar, title_en, body_en, change_note, created_at").order("version", { ascending: false }),
    admin.from("platform_legal_settings").select("*").eq("id", 1).maybeSingle(),
  ]);
  if (d.error || !s.data || !(d.data ?? []).length) {
    return (
      <div>
        <AdminHeader title="الصفحات القانونية" subtitle="الشروط والخصوصية والإلغاء والاسترداد وبيانات التواصل." />
        <Card className="border-amber-200 bg-amber-50 p-5 text-sm text-amber-900">الجداول القانونية غير جاهزة. شغّل ترحيلات قاعدة البيانات <span dir="ltr">0064</span> ثم <span dir="ltr">0065</span> في Supabase ثم حدّث الصفحة.</Card>
      </div>
    );
  }
  const docs: LegalDocForEditor[] = LEGAL_KEYS.map((k) => {
    const rows = (d.data ?? []).filter((r) => r.doc_key === k).slice(0, 12);
    return {
      key: k, label: LABEL[k], path: LEGAL_PATH[k],
      versions: rows.length ? rows.map((r) => ({ version: r.version, titleAr: r.title_ar, bodyAr: r.body_ar, titleEn: r.title_en, bodyEn: r.body_en, note: r.change_note, createdAt: r.created_at }))
        : [{ version: 0, ...LEGAL_DEFAULTS[k], note: null, createdAt: new Date().toISOString() }],
    };
  });
  const r = s.data;
  return (
    <div>
      <AdminHeader title="الصفحات القانونية" subtitle="عدّل نصوص الشروط والخصوصية والإلغاء والاسترداد بالعربية والإنجليزية، وبيانات التواصل. كل حفظ إصدار جديد." />
      <Card className="mb-6 bg-amber-50 p-4 text-sm leading-6 text-amber-900">النصوص الأولية <strong>مسودات</strong> كُتبت لنموذج عمل كيان وتحتاج مراجعة محامٍ مصري قبل الاعتماد. بنود المراجعة مدرجة تحت كل مستند، وبالتفصيل في الملف docs/LEGAL_REVIEW.md.</Card>
      <LegalEditor docs={docs} settings={{ companyNameAr: r.company_name_ar, companyNameEn: r.company_name_en, phone: r.contact_phone, email: r.contact_email, addressAr: r.address_ar, addressEn: r.address_en, commercialRegister: r.commercial_register, taxRegistration: r.tax_registration, lawyerReviewed: r.lawyer_reviewed }} />
    </div>
  );
}
