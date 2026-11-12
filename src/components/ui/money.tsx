import { formatMoney, isNegativeMoney } from "@/lib/money";

// An amount with its currency, as ONE unbreakable unit that reads the Arabic way: the number first (on the right),
// the currency after it (on its left):  "ج.م ٦٬٨٤٠٫٠٠". The digits themselves are an isolated left-to-right run
// ("-٨٠٠٫٠٠": minus sign first, then digits), so Arabic text around it can never reorder them.
// `sign` ("+" or "−") is printed inside that same run, glued to the digits, instead of as a separate piece of text.
// Red whenever the amount is below zero; otherwise the colour comes from the parent.
export function Money({
  value,
  suffix = "ج.م",
  sign,
  className = "",
}: {
  value: number | null | undefined;
  suffix?: string;
  sign?: "+" | "−";
  className?: string;
}) {
  if (value === null) return <span className={`text-charcoal/40 ${className}`.trim()}>—</span>;
  const n = Number(value ?? 0);
  return (
    <span
      dir="rtl"
      style={{ unicodeBidi: "isolate", whiteSpace: "nowrap", fontVariantNumeric: "tabular-nums" }}
      className={`inline-block max-w-full ${isNegativeMoney(n) ? "!text-rose" : ""} ${className}`.trim()}
    >
      <span dir="ltr" className="num">
        {sign ? `${sign}\u2060` : ""}
        {formatMoney(n)}
      </span>
      {suffix ? ` ${suffix}` : ""}
    </span>
  );
}
