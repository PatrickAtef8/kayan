# Kayan — Design System

This is the single source of truth for how Kayan looks. Every phase from
here on builds against this file instead of improvising per-page. If a new
screen needs something not covered here, add it here first, then build it.

## Product mood

Kayan is a **ledger, not a dashboard toy** — a business-management tool an
Egyptian shop owner or accountant trusts with real money. The reference
mood is: **calm, precise, slightly warm** (brass/paper, not corporate
blue-and-white SaaS). Arabic RTL is the primary language, not a translated
afterthought.

**Anti-patterns — do not do these:**
- No purple/blue "AI gradient" branding — this isn't a consumer AI app.
- No emoji as icons, ever — use Lucide SVG icons only.
- No dark mode for v1 — one well-executed light theme beats two mediocre ones.
- No dense corporate-blue enterprise-software look — warmth (brass/paper)
  is the differentiator from generic ERP UI.
- Never rely on color alone for status (credit status, invoice state) —
  pair color with a text label, as `credit_status` already does.

## Color tokens

Defined in `tailwind.config.ts`. Use these names, not raw hex, in any new
component.

| Token | Hex | Use |
|---|---|---|
| `ink` | `#151313` | Primary text/headings, dark sidebar, primary buttons (app) |
| `paper` | `#FBF9F6` | App background (light theme, dashboard only) |
| `line` | `#E4DFD6` | Borders, dividers (app) |
| `brass` | `#D4AF37` | Primary accent — true metallic gold, not tan/brown. Active nav, CTAs, focus rings |
| `brassLight` | `#F3D477` | Gradient highlight / shimmer top-stop |
| `brassDeep` | `#9C7A24` | Gradient shadow / shimmer bottom-stop |
| `obsidian` | `#08080A` | Marketing-page background only (near-black) |
| `panel` | `#131215` | Card surface on the marketing page (dark) |
| `moss` | `#4E5D4A` | Positive/success state (good credit, profit) |
| `rose` | `#9C4F45` | Negative/danger state (blocked credit, loss, destructive actions) |

**Note on the brass fix:** the original brass (`#8A6D3B`) read as muddy
brown, not gold — flagged directly by the client. It's now a true
saturated gold with light/deep gradient stops, used consistently: gold
accents against dark (`obsidian`/`panel`/`ink`) read as premium; the same
gold against light (`paper`) is the app's existing accent color, unchanged
in role, just corrected in hue.

## Two surfaces, two palettes — this is intentional, not an inconsistency

- **The marketing/landing page** (`src/components/marketing/`) uses a
  separate, deliberately restrained palette — see below. It is light, not
  dark; the earlier dark/gold version was rejected by the client and
  replaced with this one.
- **The authenticated dashboard** keeps the `ink`/`paper`/`brass` tokens
  from the top of this file, unchanged.

### Marketing-page palette

| Token | Hex | Use |
|---|---|---|
| `ivory` | `#F7F6F2` | Page background |
| White | `#FFFFFF` | Cards, mockup panel |
| `charcoal` | `#1C1C1A` | All text, primary buttons |
| `sage` | `#344E41` | The *only* accent — CTAs' hover state, active states, one highlighted word/row per section |
| `sageSoft` | `#E7EDE8` | Sage's background tint (icon circles, one highlighted row) |
| `borderSoft` | `#E5E3DD` | All hairline borders/dividers |

**Rule, stated plainly because it was violated once already: this page
gets *one* accent color, used sparingly.** No gradients, no glassmorphism,
no second or third accent color, no colored icon badges beyond the single
sage tint above. If a new marketing section wants to "pop," the answer is
better whitespace, size, or typography weight — not another color.

### Motion rules for the marketing page

- Section entrances: fade + small `y` translate, `whileInView`,
  `viewport={{ once: true }}` — reveals happen once, scrolling back up
  doesn't replay them.
- At most **one** scroll-tied parallax element (currently: the hero
  mockup, via `useScroll`/`useTransform`) — not every section.
- No infinite/looping animations (no drifting blobs, no continuous
  floating cards). The first version of this page had a looping "aurora"
  background and floating stat cards — removed, because looping motion
  reads as "look how many effects" rather than "calm and premium," which
  is the opposite of the brief.
- Buttons: plain color transition on hover (`hover:bg-sage`), no shimmer
  sweep, no gradient fill.

## Typography

- **Font:** IBM Plex Sans Arabic, loaded via `next/font/google` in
  `src/app/layout.tsx`. Never reference a font family by CSS string alone —
  that was the Phase 1/2 bug (font name in CSS with nothing actually
  loading it, silently falling back to Tahoma). If a new layout or page
  needs its own font instance, it must import from `next/font`, not add a
  CSS `font-family` string.
- **Scale:** page title `text-lg font-semibold` · section/card label
  `text-sm text-ink/70` · body / table cells `text-base` or `text-sm` ·
  numbers in tables/cards `text-2xl font-semibold` for the hero figure,
  plain `text-base` inline.
- **Numerals & LTR fragments:** phone numbers, SKUs, emails, and money
  amounts get `dir="ltr"` on their own span/input even inside an RTL page —
  already the pattern in the customers/products pages, keep it everywhere
  numbers appear.

## Spacing, radius, elevation

- **Radius:** one token, `rounded-card` (10px), on every card/input/button.
  No mixed radii.
- **Card padding:** `p-5` for compact cards (forms, list wrappers), `p-6`–`p-8`
  for standalone auth cards.
- **Grid gaps:** `gap-3` as the default between form fields and dashboard
  cards.
- **Elevation:** flat by default (`border border-line`, no shadow) for
  structural containers (tables, form cards). Reserve `shadow-sm` +
  `hover:shadow-md` for interactive summary cards (like the dashboard
  home tiles) — elevation signals "this is a highlighted number," not
  "this is a container."

## Structural shell (the thing that was actually missing)

A flat, undifferentiated layout is what reads as "cheap," regardless of
palette. The shell now has three deliberate planes:

- **Sidebar** — dark (`bg-ink`), full-height, grouped into labeled sections
  (عام / العمليات / تقارير). Active route gets a solid `brass` pill, not
  just a text-color change.
- **Topbar** — light, `border-b`, always present above page content. Carries
  the date and a user-avatar slot; this is where global actions (search,
  notifications, org switcher) go as they're built in later phases —
  never bury a global action inside a page's own content area.
- **Auth pages** — split-screen (`AuthShell`), not a centered card on empty
  background: a dark branded panel (identity, tagline, 3 feature bullets)
  on one side, the actual form on the other. A centered card alone reads as
  a placeholder, not a product's front door.

## Components (updated)

- `AuthShell` (`components/auth/auth-shell.tsx`) — the split-screen wrapper
  every login/signup/invite page renders inside.
- `Topbar` (`components/dashboard/topbar.tsx`) — sits above `{children}` in
  the dashboard layout, alongside `Sidebar`.

- `Input` / `Field` (`input.tsx`) — text inputs + labeled field wrapper.
- `Button` (`button.tsx`) — variants: `primary` (ink, default actions),
  `secondary` (bordered, secondary actions), `ghost` (text-only, tertiary),
  `danger` (rose, destructive — delete/cancel/void).
- `Card` (`card.tsx`) — bordered container.
- `PageHeader` (`page-header.tsx`) — page title + optional right-aligned action.
- `DataTable` (`data-table.tsx`) — list views; has a built-in empty state,
  always pass a real `emptyLabel` in Arabic rather than leaving the default.
- `Sidebar` (`components/dashboard/sidebar.tsx`) — module-aware nav with
  Lucide icons and active-route highlighting.

**Interaction states every input/button must have** (already true for
`Input`/`Button`, keep true for anything new):
- Hover state (`hover:bg-...` / `hover:border-...`)
- Focus state — visible focus ring (`focus:border-brass`, or add
  `focus-visible:ring-2 focus-visible:ring-brass/40` for keyboard nav on
  non-input elements like table row actions)
- Disabled state (`disabled:opacity-50 disabled:pointer-events-none`)
- `cursor-pointer` on every clickable non-button element (e.g. a `<tr>`
  that opens a detail view)

## Icons

Lucide React only (`lucide-react`, already installed). Size `16`–`18` with
`strokeWidth={2}` for inline/nav icons, `20`–`24` for card/empty-state icons.
Icons are always paired with a text label in navigation — never icon-only
nav items, since this is a business tool people will use daily and need to
scan fast, not a mobile app optimizing for icon-only chrome.

## Accessibility checklist (apply before shipping any new page)

- [ ] Text contrast at least 4.5:1 (ink-on-paper and ink-on-white both pass;
      don't introduce a lighter text color without checking)
- [ ] Every interactive element reachable and operable by keyboard, with a
      visible focus state
- [ ] Status conveyed by color is also conveyed by text (see credit_status)
- [ ] Numbers/currency always `dir="ltr"` even in the RTL flow
- [ ] Empty states have a real, specific Arabic message — not a blank table
- [ ] Long names/SKUs/labels wrap or truncate gracefully, don't break the
      table layout

## What NOT to add without discussion

- A second font family (one Arabic family is intentional, not a gap)
- Dark mode
- A component library beyond what's in `src/components/ui/` — if shadcn/ui
  primitives get added later (Phase 3+ data tables, per the TanStack Table
  recommendation), they should be restyled to match these tokens, not
  used with their own default look

## Base scale — 125%, set once at the root

`html { font-size: 20px }` in `globals.css` (default browser base is 16px)
is the single source of the app's overall scale. Because Tailwind's default
spacing/sizing/typography scale is entirely `rem`-based, this one line
scales nearly everything together — cards, padding, gaps, headings, body
text, `rounded-card` (converted from a fixed `10px` to `0.625rem` so it
scales too).

**What this means for new components:**
- Use Tailwind's normal scale (`text-sm`, `p-5`, `h-9`, `gap-3`, etc.) —
  it already renders at 125% via the root, no extra work needed.
- **Never use an arbitrary pixel value** (`text-[11px]`, `min-h-[220px]`)
  without converting it to `rem` (`text-[0.6875rem]`) — a raw `px` value is
  absolute and silently opts out of the scale, which is exactly what
  happened to the small "eyebrow" micro-labels (`KAYAN / OS` etc.) and the
  card min-heights before this fix. If a pixel value is unavoidable, divide
  by 16 to get the rem equivalent.
- Lucide icon `size={N}` props are a real exception — they're raw px, not
  rem, and don't scale with the root automatically. Icon sizes were scaled
  once by hand (×1.25) as part of this pass; a new icon usage should be
  sized at the "final" (already-scaled) number directly, not the pre-scale
  one.
- Deliberately-fixed hairline widths (a 1px border, a 3–4px progress bar)
  are the one thing that should generally *stay* fixed regardless of
  scale — don't rem-ify pure hairlines.

## Standing rules learned from a real regression

An externally-edited version of this project reverted several fixed bugs
at once, which is why these are now written down explicitly rather than
left as "something we already fixed once":

- **The Arabic font must load via `next/font/google` (or `next/font/local`
  if build-time network access is genuinely unavailable) — never a bare
  CSS `font-family` string with a system-font fallback.** `next/font`
  self-hosts the files after the first build; it is not a live runtime
  dependency on Google, so "avoid depending on Google Fonts" is not a
  reason to drop it.
- **`Sidebar` takes `open`/`onClose` props and is rendered through
  `DashboardShell`, never directly from `dashboard/layout.tsx`.** That's
  what makes the mobile drawer work. If `Sidebar`'s props ever shrink back
  to just `{ orgName, enabledKeys }`, the mobile drawer is gone.
- **A single dark card inside an otherwise-light grid reads as a mistake,
  not a design choice** — removed from both the dashboard home cards and
  the marketing features grid for this reason. A full-width dark *section*
  used for pacing (like `SignalSurface`) is a different, legitimate
  technique and is not covered by this rule — don't conflate the two.
