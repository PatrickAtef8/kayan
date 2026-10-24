// One way to print a money amount: Arabic-Indic digits, always laid out left-to-right, with the minus sign FIRST.
//
// Why: n.toLocaleString("ar-EG") puts a right-to-left mark before the minus sign, so inside Arabic text a negative
// balance showed up scrambled (the sign drifting to the end of the number). Callers render the result inside an
// element with dir="ltr" (see <Money />) so digits and sign keep their order.

const FORMAT: Intl.NumberFormatOptions = { minimumFractionDigits: 2, maximumFractionDigits: 2 };

/** True only if the amount is below zero AFTER rounding to 2 decimals (so -0.004 is not "negative"). */
export function isNegativeMoney(n: number): boolean {
  return Number.isFinite(n) && Math.round(n * 100) < 0;
}

/** "-١٬٢٣٤٫٥٠" / "١٬٢٣٤٫٥٠" — no currency suffix. */
export function formatMoney(n: number): string {
  const v = Number.isFinite(n) ? n : 0;
  const digits = Math.abs(v).toLocaleString("ar-EG", FORMAT);
  return isNegativeMoney(v) ? `-${digits}` : digits;
}
