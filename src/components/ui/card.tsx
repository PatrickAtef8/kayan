import clsx from "clsx";

// min-w-0: a card inside a flex/grid parent may shrink below its content instead of stretching the page.
// Callers that pass their own padding (p-5, p-6…) still win, because clsx puts className last.
export function Card({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={clsx("min-w-0 rounded-2xl border border-borderSoft/80 bg-white p-4 shadow-[0_10px_30px_rgba(28,28,26,0.035)] sm:p-5", className)} {...props} />;
}
