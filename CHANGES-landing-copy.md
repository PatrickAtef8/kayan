# Landing page — Arabic copy pass + invisible-button fix

## Bug: «ابدأ مجانًا» text invisible on the green card
`PrimaryButton` had `bg-charcoal text-ivory` built in, and the final CTA added `bg-ivory text-charcoal` on top.
Two competing utilities on one element: the winner depends on Tailwind's output order, so the text was dark-on-dark
until hover. Fixed at the root: `PrimaryButton` now takes `tone="dark" | "light"`; colours no longer come from className.
(`src/components/marketing/effects/buttons.tsx`, `final-cta.tsx`)

## Accuracy fixes
- Final CTA said "بدون بطاقة ائتمان وبدون التزام" even when no free trial is on. Now shown only while the trial is enabled.
- "How it works" step 2 said users pick their modules; modules are controlled by the package. Reworded.
- Section numbering: «سطح الإشارة» (literal translation) -> «نظرة سريعة».
- Signal selector showed mixed digits («٠1»); now «٠١…٠٤».
- Arabic text inside `dir="ltr"` containers rendered in reversed order (hero card header/footer, final CTA tag, how-it-works tag,
  signal card header). `dir="ltr"` removed from those.
- «مندوبين / مناديب» unified to «المناديب» (the app uses it ~3x more).
- Trial line uses `daysText()` so day grammar is right (يومان / ٣ أيام / ١٥ يومًا).
- Low-contrast small text on the green card raised.

## Copy
Rewritten for hero, stats, signal surface, features, roles, how-it-works and final CTA: shorter sentences, no translated-sounding
phrases, one consistent register (clear everyday Arabic). Facts are unchanged and were checked against the code
(12 modules, 12 report sections, 3 roles, Excel/PDF export, role access).

Checked: `tsc --noEmit` and `eslint src/components/marketing` clean. `next build` could not run in the sandbox (no access to Google Fonts).
