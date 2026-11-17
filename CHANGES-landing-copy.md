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

## Responsive pass (checked in a real browser at 320, 390, 768, 1024, 1280, 1536 px)
- No horizontal overflow at any size; the CTA text is dark on the light button at every size.
- Hero headline was too big for the new (longer) text and wrapped to 4 lines on laptops: sizes retuned (2.5rem phone -> 4.2rem wide screens; smaller on <=360px).
- Hero mini chart never rendered (bars had no height to resolve % against): fixed height added.
- Hero tag row and buttons were pushed to the opposite side from the text in RTL (`justify-end`): now `justify-start`.
- Feature / how-it-works cards used absolutely-positioned text that could overlap the icon row on narrow screens: now normal flex flow.
- Signal card: "أرقام للتوضيح فقط" no longer overlaps the text on phones; value no longer forced LTR.

## Hero card on mobile
The example card faded out (and tilted/slid) with scrolling; on a phone it sits near the bottom of the hero, so it nearly vanished right
after the first scroll. The scroll effect now runs only on large screens with a mouse (>=1024px, fine pointer); on phones and tablets the card
stays fully visible. Verified: opacity stays 1.00 while scrolling at 390px and 768px.

## Link preview (WhatsApp / Facebook / Telegram / X)
- New `public/og-image.png` (1200×630, ~62 KB): brand headline + the example dashboard card, rendered with the project's own IBM Plex Sans Arabic.
- `src/app/layout.tsx`: Open Graph + Twitter tags now carry the image (`summary_large_image`), and the site description was rewritten.
- The absolute image URL comes from `metadataBase` = `NEXT_PUBLIC_SITE_URL` (or Vercel's production URL). Set `NEXT_PUBLIC_SITE_URL=https://kayan-xi.vercel.app` in Vercel.
- WhatsApp caches previews: after deploying, test with `https://kayan-xi.vercel.app/?v=2`.

## Merge note
Merged onto the newer working version (receipt notes, backorders, purchase price history, party contact fields, split returns reports…).
None of those files were touched by the landing work. One consequence: sales and purchase returns are now two separate reports,
so the landing stat "تقرير مالي وتشغيلي" went from 12 to 13.
