// ONE way to print a money amount everywhere in the app.
//
// Rules (decided once, applied everywhere):
//   - Arabic-Indic digits, two decimals:            ١٬٢٥٠٫٥٠
//   - a negative amount has a minus sign "-" directly BEFORE the digits (on their left): -٨٠٠٫٠٠ — never after them;
//   - the number is an isolated left-to-right unit (U+2066 … U+2069), so the surrounding Arabic text can never move
//     the sign to the other end, whichever element or table cell it ends up in;
//   - anything below zero is also shown in red (see <Money />, <StatValue /> and `negativeClass`).
//
// Why a helper: n.toLocaleString("ar-EG") puts an Arabic letter mark in front of the minus sign, so a negative
// amount printed inside Arabic text showed the sign in a different place from screen to screen.

const LRI = "\u2066"; // left-to-right isolate
const PDI = "\u2069"; // pop directional isolate

/** True only if the amount is below zero AFTER rounding to 2 decimals (so -0.004 is not "negative"). */
export function isNegativeMoney(n: number): boolean {
  return Number.isFinite(n) && Math.round(n * 100) < 0;
}

/** "-١٢٣٫٤٥" / "١٢٣٫٤٥" — no currency suffix. `decimals` is 2 for money, 0 for compact chart figures. */
export function formatMoney(n: number | null | undefined, decimals = 2): string {
  const v = Number.isFinite(Number(n)) ? Number(n) : 0;
  const digits = Math.abs(v).toLocaleString("ar-EG", { minimumFractionDigits: decimals, maximumFractionDigits: decimals });
  const negative = decimals === 0 ? Math.round(v) < 0 : isNegativeMoney(v);
  return `${LRI}${negative ? "-" : ""}${digits}${PDI}`;
}

/** Tailwind class for an amount: red below zero, otherwise nothing (the parent colour applies). */
export function negativeClass(n: number | null | undefined): string {
  return isNegativeMoney(Number(n ?? 0)) ? "text-rose" : "";
}
