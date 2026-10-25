import { formatMoney, isNegativeMoney } from "@/lib/money";

// An amount, always left-to-right, in red when it is below zero. Colour for non-negative amounts is inherited from the
// parent (or passed in className), so it drops into any existing heading / row. Never splits across two lines.
export function Money({ value, suffix = "ج.م", className = "" }: { value: number; suffix?: string; className?: string }) {
  const negative = isNegativeMoney(value);
  return (
    <span dir="ltr" className={`num ${negative ? "text-rose" : ""} ${className}`.trim()}>
      {formatMoney(value)}{suffix ? ` ${suffix}` : ""}
    </span>
  );
}
