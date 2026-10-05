import { forwardRef, type InputHTMLAttributes } from "react";
import clsx from "clsx";

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function Input({ className, ...props }, ref) {
  return <input ref={ref} className={clsx("w-full border border-borderSoft bg-white px-3.5 py-3 text-base text-charcoal outline-none transition-colors placeholder:text-charcoal/30 focus:border-sage focus-visible:ring-2 focus-visible:ring-sage/20", className)} {...props} />;
});

export function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <div><label className="mb-2 block text-sm text-charcoal/65">{label}</label>{children}</div>;
}
