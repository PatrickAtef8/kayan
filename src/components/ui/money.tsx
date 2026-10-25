import { formatMoney, isNegativeMoney } from "@/lib/money";

// An amount with its currency, as ONE unbreakable left-to-right unit: "-٨٠٠٫٠٠ ج.م" (minus sign first, then digits,
// then the currency). Red whenever the amount is below zero; otherwise the colour comes from the parent.
export function Money({ value, suffix = "ج.م", className = "" }: { value: number | null | undefined; suffix?: string; className?: string }) {
  if (value === null) return <span className={`text-charcoal/40 ${className}`.trim()}>—</span>;
  const n = Number(value ?? 0);
  return (
    <span dir="ltr" className={`num ${isNegativeMoney(n) ? "!text-rose" : ""} ${className}`.trim()}>
      {formatMoney(n)}{suffix ? ` ${suffix}` : ""}
    </span>
  );
}
