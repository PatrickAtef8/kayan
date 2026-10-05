export function PageHeader({ title, action }: { title: string; action?: React.ReactNode }) {
  return <div className="mb-8 flex items-end justify-between gap-4"><div><p className="mb-3 text-xs font-medium text-sage">مساحة العمل</p><h1 className="text-3xl font-semibold tracking-[-0.04em] text-charcoal">{title}</h1><p className="mt-2 text-sm text-charcoal/45">أدر بياناتك بسهولة واحتفظ بصورة واضحة عن عملك.</p></div>{action}</div>;
}
