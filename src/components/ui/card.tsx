import clsx from "clsx";

export function Card({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={clsx("rounded-2xl border border-borderSoft/80 bg-white p-5 shadow-[0_10px_30px_rgba(28,28,26,0.035)]", className)} {...props} />;
}
