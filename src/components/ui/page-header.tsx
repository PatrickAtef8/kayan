export function PageHeader({ title, action }: { title: string; action?: React.ReactNode }) {
  return (
    <div className="mb-6 flex flex-col gap-4 sm:mb-8 sm:flex-row sm:items-end sm:justify-between sm:gap-4">
      <div className="min-w-0">
        <p className="mb-2 text-xs font-medium text-sage sm:mb-3">مساحة العمل</p>
        <h1 className="break-words text-2xl font-semibold tracking-[-0.03em] text-charcoal sm:text-3xl">{title}</h1>
        <p className="mt-2 text-sm text-charcoal/45">أدر بياناتك بسهولة واحتفظ بصورة واضحة عن عملك.</p>
      </div>
      {action ? <div className="flex min-w-0 shrink-0 flex-wrap items-center gap-2 [&>a]:text-center [&>button]:text-center max-sm:[&>a]:flex-1 max-sm:[&>button]:flex-1">{action}</div> : null}
    </div>
  );
}
