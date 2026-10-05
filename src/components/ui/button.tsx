import { forwardRef, type ButtonHTMLAttributes } from "react";
import clsx from "clsx";

type Variant = "primary" | "secondary" | "ghost" | "danger";
const variants: Record<Variant, string> = { primary: "rounded-xl bg-charcoal text-ivory shadow-sm hover:bg-sage", secondary: "rounded-xl border border-borderSoft bg-white text-charcoal hover:border-sage hover:bg-sageSoft/30", ghost: "rounded-xl text-charcoal/55 hover:bg-paper hover:text-charcoal", danger: "rounded-xl bg-rose text-white hover:bg-rose/90" };

export const Button = forwardRef<HTMLButtonElement, ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }>(function Button({ className, variant = "primary", ...props }, ref) {
  return <button ref={ref} className={clsx("cursor-pointer px-4 py-2.5 text-sm font-medium transition-all duration-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sage/40 disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 active:scale-[0.98]", variants[variant], className)} {...props} />;
});
