import clsx from "clsx";

export function BentoGrid({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-1 md:grid-cols-3 gap-px bg-borderSoft rounded-2xl overflow-hidden">{children}</div>;
}

// Deliberately quiet: white card, hairline border (via the grid gap trick
// above so dividers stay perfectly thin and even), one small monochrome
// icon. No color-blur hover glow, no gradients — the earlier bento cards
// were exactly the kind of "more colors" excitement this brief asks to remove.
export function BentoCard({
  className,
  eyebrow,
  title,
  description,
  icon: Icon,
}: {
  className?: string;
  eyebrow: string;
  title: string;
  description: string;
  icon: React.ComponentType<{ size?: number; strokeWidth?: number }>;
}) {
  return (
    <div className={clsx("bg-white p-8 flex flex-col", className)}>
      <div className="h-9 w-9 rounded-full bg-sageSoft text-sage flex items-center justify-center mb-6">
        <Icon size={20} strokeWidth={1.75} />
      </div>
      <p className="text-xs tracking-wide text-charcoal/40 uppercase mb-2">{eyebrow}</p>
      <h3 className="text-charcoal font-medium mb-2 leading-snug">{title}</h3>
      <p className="text-sm text-charcoal/55 leading-relaxed">{description}</p>
    </div>
  );
}
