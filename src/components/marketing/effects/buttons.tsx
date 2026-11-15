import Link from "next/link";
import clsx from "clsx";

// Plain, confident buttons — no shimmer, no gradient sweep. Restraint is the effect here.
//
// Colours come from a `tone`, never from className. Passing `bg-ivory text-charcoal` through className on top of a
// built-in `bg-charcoal text-ivory` puts two competing utilities on the same element, and which one wins depends on
// the order Tailwind happens to emit them — that is what made the white button on the green card show no text until hover.
const TONES = {
  dark: "bg-charcoal text-ivory hover:bg-sage hover:text-ivory",
  light: "bg-ivory text-charcoal hover:bg-charcoal hover:text-ivory",
} as const;

export function PrimaryButton({
  href,
  children,
  className,
  tone = "dark",
}: {
  href: string;
  children: React.ReactNode;
  className?: string;
  tone?: keyof typeof TONES;
}) {
  return (
    <Link
      href={href}
      className={clsx(
        "inline-flex items-center gap-2 rounded-[4px] px-6 py-3.5 text-sm font-medium transition-colors",
        TONES[tone],
        className
      )}
    >
      {children}
    </Link>
  );
}

export function SecondaryLink({
  href,
  children,
  className,
}: {
  href: string;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <Link
      href={href}
      className={clsx(
        "inline-flex items-center gap-2 text-sm font-medium text-charcoal/70 transition-colors hover:text-charcoal",
        className
      )}
    >
      {children}
    </Link>
  );
}
