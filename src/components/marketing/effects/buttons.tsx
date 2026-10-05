import Link from "next/link";
import clsx from "clsx";

// Plain, confident buttons — no shimmer, no gradient sweep. Restraint is
// the effect here.
export function PrimaryButton({
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
        "inline-flex items-center gap-2 rounded-full bg-charcoal px-6 py-3 text-sm font-medium text-ivory transition-colors hover:bg-sage",
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
