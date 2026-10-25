// A big figure inside a card or tile (a KPI, a balance, a total) that always fits:
//   - the font steps down as the number gets longer, so "١٬٢٥٠٬٠٠٠٫٠٠" never pokes out of a narrow card;
//   - the currency / unit sits beside the number and wraps under it when there is no room, instead of overflowing;
//   - the number itself is an isolated left-to-right run (sign and digits keep their order) but the block follows the
//     page direction, so it lines up with the label above it instead of jumping to the opposite edge.
const SIZES = {
  xl: [[8, "text-[1.75rem] sm:text-3xl"], [12, "text-2xl sm:text-[1.75rem]"], [16, "text-xl sm:text-2xl"], [Infinity, "text-lg sm:text-xl"]],
  lg: [[8, "text-2xl"], [12, "text-xl sm:text-2xl"], [16, "text-lg sm:text-xl"], [Infinity, "text-base sm:text-lg"]],
  md: [[10, "text-lg"], [14, "text-base"], [Infinity, "text-sm"]],
} as const;

export function StatValue({ value, unit, negative, size = "xl", className = "" }: { value: string | number; unit?: string; negative?: boolean; size?: keyof typeof SIZES; className?: string }) {
  const text = String(value);
  const step = SIZES[size].find(([max]) => text.length <= max)![1];
  return (
    <p className={`flex min-w-0 flex-wrap items-baseline gap-x-1.5 leading-tight ${className}`}>
      <span dir="ltr" className={`num font-semibold tracking-tight ${step} ${negative ? "text-rose" : ""}`}>{text}</span>
      {unit ? <span className="text-[0.6875rem] font-medium text-charcoal/45 sm:text-xs">{unit}</span> : null}
    </p>
  );
}
