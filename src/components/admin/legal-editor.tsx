"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import clsx from "clsx";
import { Check, ExternalLink, TriangleAlert } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import { saveLegalDocument, saveLegalSettings } from "@/app/admin/actions";
import { extractReviewNotes } from "@/lib/legal/render";

type Version = { version: number; titleAr: string; bodyAr: string; titleEn: string; bodyEn: string; note: string | null; createdAt: string };
export type LegalDocForEditor = { key: "terms" | "privacy" | "refund"; label: string; path: string; versions: Version[] };
export type LegalSettingsForEditor = { companyNameAr: string; companyNameEn: string; phone: string; email: string; addressAr: string; addressEn: string; commercialRegister: string; taxRegistration: string; lawyerReviewed: boolean };

const field = "w-full rounded-xl border border-borderSoft bg-white px-3 py-2 text-sm outline-none focus:border-sage focus:ring-2 focus:ring-sage/20";
const DATE = new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeStyle: "short" });
type Msg = { ok: boolean; text: string } | null;

function Notice({ msg }: { msg: Msg }) {
  if (!msg) return null;
  return <p role="alert" className={clsx("mt-3 flex items-start gap-2 text-sm", msg.ok ? "text-sage" : "text-rose")}>{msg.ok ? <Check size={16} className="mt-0.5 shrink-0" /> : <TriangleAlert size={16} className="mt-0.5 shrink-0" />}{msg.text}</p>;
}

function SettingField({ label, value, onChange, ltr, hint }: { label: string; value: string; onChange: (v: string) => void; ltr?: boolean; hint?: string }) {
  return (
    <label className="block"><span className="block text-xs font-medium text-charcoal/70">{label}</span>
      <input value={value} dir={ltr ? "ltr" : undefined} onChange={(e) => onChange(e.target.value)} className={clsx(field, "mt-1", ltr && "text-right")} />
      {hint && <span className="mt-1 block text-[0.6875rem] text-charcoal/40">{hint}</span>}</label>
  );
}

// ---- contact details + legal identity + the "reviewed by a lawyer" switch ---------------------------------------------------
function SettingsCard({ initial }: { initial: LegalSettingsForEditor }) {
  const router = useRouter();
  const [s, setS] = useState(initial);
  const [msg, setMsg] = useState<Msg>(null);
  const [pending, start] = useTransition();
  const set = (p: Partial<LegalSettingsForEditor>) => setS((x) => ({ ...x, ...p }));
  const save = () => { setMsg(null); start(async () => { try { const r = await saveLegalSettings(s); if (r.error) setMsg({ ok: false, text: r.error }); else { setMsg({ ok: true, text: r.message ?? "حُفظ." }); router.refresh(); } } catch { setMsg({ ok: false, text: "تعذّر الاتصال بالخادم." }); } }); };
  return (
    <Card className="mb-6 p-5">
      <h2 className="text-base font-semibold text-charcoal">بيانات التواصل والجهة</h2>
      <p className="mt-1 text-xs leading-5 text-charcoal/50">تظهر في تذييل الموقع وصفحة «اتصل بنا» وتُملأ تلقائيًا في الصفحات القانونية. الحقل الفارغ يظهر شرطة «—».</p>
      <div className="mt-4 grid gap-4 sm:grid-cols-2">
        <SettingField label="رقم التواصل (هاتف)" value={s.phone} onChange={(v) => set({ phone: v })} ltr hint="مثال: +20 100 000 0000" />
        <SettingField label="البريد الإلكتروني" value={s.email} onChange={(v) => set({ email: v })} ltr />
        <SettingField label="اسم الجهة بالعربية" value={s.companyNameAr} onChange={(v) => set({ companyNameAr: v })} />
        <SettingField label="اسم الجهة بالإنجليزية" value={s.companyNameEn} onChange={(v) => set({ companyNameEn: v })} ltr />
        <SettingField label="العنوان بالعربية" value={s.addressAr} onChange={(v) => set({ addressAr: v })} />
        <SettingField label="العنوان بالإنجليزية" value={s.addressEn} onChange={(v) => set({ addressEn: v })} ltr />
        <SettingField label="رقم السجل التجاري" value={s.commercialRegister} onChange={(v) => set({ commercialRegister: v })} ltr />
        <SettingField label="رقم التسجيل الضريبي" value={s.taxRegistration} onChange={(v) => set({ taxRegistration: v })} ltr />
      </div>
      <label className="mt-4 flex cursor-pointer items-start gap-2.5 text-sm"><input type="checkbox" checked={s.lawyerReviewed} onChange={(e) => set({ lawyerReviewed: e.target.checked })} className="mt-0.5 h-4 w-4 accent-[#344E41]" /><span><span className="font-medium">راجعها محامٍ مصري واعتمدتُها</span><span className="mt-0.5 block text-xs text-charcoal/50">ما دام الخيار غير مفعّل تظهر على الصفحات العامة ملاحظة «مسودة قيد المراجعة القانونية». فعّله بعد المراجعة فقط.</span></span></label>
      <Notice msg={msg} />
      <button type="button" onClick={save} disabled={pending} className="mt-4 inline-flex items-center gap-2 rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage disabled:opacity-50">{pending ? <><Spinner />جارٍ الحفظ…</> : "حفظ البيانات"}</button>
    </Card>
  );
}

// ---- one document: edit both languages, save as a new version ----------------------------------------------------------------
function DocEditor({ doc }: { doc: LegalDocForEditor }) {
  const router = useRouter();
  const cur = doc.versions[0];
  const [d, setD] = useState({ titleAr: cur.titleAr, bodyAr: cur.bodyAr, titleEn: cur.titleEn, bodyEn: cur.bodyEn });
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<Msg>(null);
  const [pending, start] = useTransition();
  const dirty = d.titleAr !== cur.titleAr || d.bodyAr !== cur.bodyAr || d.titleEn !== cur.titleEn || d.bodyEn !== cur.bodyEn;
  const notes = useMemo(() => [...extractReviewNotes(d.bodyAr).map((t) => ({ lang: "ع", t })), ...extractReviewNotes(d.bodyEn).map((t) => ({ lang: "EN", t }))], [d.bodyAr, d.bodyEn]);
  const save = () => { setMsg(null); start(async () => { try { const r = await saveLegalDocument({ key: doc.key, ...d, note }); if (r.error) setMsg({ ok: false, text: r.error }); else { setMsg({ ok: true, text: r.message ?? "حُفظ." }); setNote(""); router.refresh(); } } catch { setMsg({ ok: false, text: "تعذّر الاتصال بالخادم." }); } }); };
  return (
    <Card className="p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-base font-semibold text-charcoal">{doc.label} <span className="num ms-2 text-xs font-normal text-charcoal/45">الإصدار الحالي {cur.version}</span></h2>
        <span className="flex gap-3 text-xs"><a href={doc.path} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-sage underline underline-offset-4">عرض بالعربية <ExternalLink size={12} /></a><a href={`${doc.path}?lang=en`} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-sage underline underline-offset-4">English <ExternalLink size={12} /></a></span>
      </div>
      <p className="mt-2 text-xs leading-5 text-charcoal/50">صيغة بسيطة: <code>## عنوان</code> · <code>- نقطة</code> · <code>1. رقم</code> · <code>**غامق**</code> · <code>[نص](/رابط)</code>. الرموز <code dir="ltr">{"{{company_name}} {{phone}} {{email}} {{address}} {{commercial_register}} {{tax_registration}}"}</code> تُملأ تلقائيًا. السطر <code dir="ltr">{"[[REVIEW: ...]]"}</code> ملاحظة للمحامي لا تظهر للعامة.</p>
      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <div><label className="block text-xs font-medium text-charcoal/70">العنوان (عربي)</label><input value={d.titleAr} onChange={(e) => setD({ ...d, titleAr: e.target.value })} className={clsx(field, "mt-1")} />
          <label className="mt-3 block text-xs font-medium text-charcoal/70">النص (عربي)</label><textarea value={d.bodyAr} onChange={(e) => setD({ ...d, bodyAr: e.target.value })} rows={20} className={clsx(field, "mt-1 font-mono text-[0.8125rem] leading-6")} /></div>
        <div dir="ltr"><label className="block text-xs font-medium text-charcoal/70">Title (English)</label><input value={d.titleEn} onChange={(e) => setD({ ...d, titleEn: e.target.value })} className={clsx(field, "mt-1")} />
          <label className="mt-3 block text-xs font-medium text-charcoal/70">Text (English)</label><textarea value={d.bodyEn} onChange={(e) => setD({ ...d, bodyEn: e.target.value })} rows={20} className={clsx(field, "mt-1 font-mono text-[0.8125rem] leading-6")} /></div>
      </div>
      {notes.length > 0 && (
        <div className="mt-4 bg-amber-50 p-4 text-sm text-amber-900">
          <p className="font-medium">بنود تحتاج مراجعة محامٍ مصري ({notes.length})</p>
          <ul className="mt-2 list-disc space-y-1 ps-5 text-xs leading-6">{notes.map((n, i) => <li key={i}><span className="font-medium">[{n.lang}]</span> {n.t}</li>)}</ul>
        </div>
      )}
      <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} placeholder="ملاحظة عن هذا التعديل (اختياري)" className={clsx(field, "mt-4")} />
      <Notice msg={msg} />
      <div className="mt-4 flex flex-wrap items-center gap-3">
        <button type="button" onClick={save} disabled={pending || !dirty} className="inline-flex items-center gap-2 rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage disabled:cursor-not-allowed disabled:opacity-50">{pending ? <><Spinner />جارٍ الحفظ…</> : "حفظ كإصدار جديد"}</button>
        <span className="text-xs text-charcoal/45">كل حفظ ينشئ إصدارًا جديدًا ولا يُعدَّل القديم؛ فيبقى ما وافق عليه كل عميل قابلًا للإثبات.</span>
      </div>
      {doc.versions.length > 1 && (
        <details className="mt-5 border-t border-borderSoft pt-4 text-sm">
          <summary className="cursor-pointer font-medium text-charcoal">سجل الإصدارات ({doc.versions.length})</summary>
          <ul className="mt-3 divide-y divide-borderSoft">{doc.versions.map((v) => (
            <li key={v.version} className="flex flex-wrap items-center justify-between gap-3 py-2">
              <span><span className="num font-medium">الإصدار {v.version}</span><span className="text-xs text-charcoal/45"> · {DATE.format(new Date(v.createdAt))}</span>{v.note && <span className="block text-xs text-charcoal/50">{v.note}</span>}</span>
              {v.version !== cur.version && <button type="button" onClick={() => { setD({ titleAr: v.titleAr, bodyAr: v.bodyAr, titleEn: v.titleEn, bodyEn: v.bodyEn }); setMsg({ ok: true, text: `حُمّل نص الإصدار ${v.version} في المحرر. احفظه ليصبح إصدارًا جديدًا.` }); }} className="text-xs text-sage underline underline-offset-4">تحميل في المحرر</button>}
            </li>))}
          </ul>
        </details>
      )}
    </Card>
  );
}

export function LegalEditor({ docs, settings }: { docs: LegalDocForEditor[]; settings: LegalSettingsForEditor }) {
  const [tab, setTab] = useState(docs[0].key);
  const doc = docs.find((d) => d.key === tab) ?? docs[0];
  return (
    <div>
      <SettingsCard initial={settings} />
      <div role="tablist" aria-label="المستندات" className="mb-4 flex flex-wrap gap-2">
        {docs.map((d) => <button key={d.key} role="tab" aria-selected={tab === d.key} type="button" onClick={() => setTab(d.key)} className={clsx("rounded-xl px-4 py-2 text-sm", tab === d.key ? "bg-sageSoft font-medium text-sage" : "bg-white text-charcoal/60 hover:text-charcoal")}>{d.label}</button>)}
      </div>
      <DocEditor key={doc.key + doc.versions[0].version} doc={doc} />
    </div>
  );
}
