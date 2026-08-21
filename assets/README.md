# DockHub brand assets

Every file here is drawn for DockHub. The mark, the palette and the tier rule
were settled on 2026-08-15 and are **closed** — do not re-open the geometry,
the tiers or the tempo. Everything below records what was decided and why, so
the next change is an informed one.

Service icons live in [`services/`](services/) and follow a different rule —
read that folder's README before adding one.

## Pick a file

| You need | Use | Source is |
|---|---|---|
| A profile picture (GitHub, X, Discord — dark platforms) | `avatar-paper/` | 512 × 512 |
| A profile picture on a **light** ground (slide, print, doc) | `avatar-dark/` | 512 × 512 |
| The mark + name on a web page you control | `dockhub-lockup/` | 442 × 295 |
| The mark + name **anywhere else** — README, PDF, slide | `dockhub-lockup-readme/` | 442 × 295 |
| A link preview / social card | `og-card/` | 1200 × 630 |
| A browser tab, a 16 px glyph | `favicon/` | 100 × 100 |
| The micro mark inside a page whose colours it should follow | `mark-micro/` | 100 × 100 |

Each folder holds the `.svg` **source** and the PNGs rendered from it. The SVG
is the file to edit; the PNGs are output and can always be regenerated.

## The one distinction that explains half this folder

Two files can look identical and behave in opposite ways. Every asset here is
one or the other, and they must never be merged:

| | Inherits colours | Paints its own ground |
|---|---|---|
| **Which** | `dockhub-lockup.svg`, `mark-micro.svg` | everything else |
| **How** | two-level `var(--page-token, --own-fallback)` | hardcoded hex, no media query |
| **Use when** | inlined into a page that has tokens | anywhere else at all |

**Why it matters.** An SVG loaded through `<img>` — which is how a README, a
PDF, a preview card and a social platform all load it — still runs its own CSS,
but `prefers-color-scheme` inside it follows the reader's **operating system**,
not the theme they chose on the site showing it. Dark GitHub on a light laptop
renders the light artwork on a dark page and the wordmark all but vanishes.
GitHub's documented `<picture>` workaround keys off the same OS setting, so it
does not fix it either.

A file that paints its own ground never asks the question, because nothing of
it is behind it. That is why the README lockup, the avatars, the favicon and
the card all carry their own background.

> **Never define the page's own token names inside an inheriting SVG.** It
> overrides the page and breaks its light theme. The fallback must use
> *differently named* locals.

## Colours

One accent per view. No gradients anywhere — the mark has to survive
engraving, embroidery, a one-colour print run, a stencil and a terminal.

| Token | Dark | Light |
|---|---|---|
| ground | `#0B1417` | `#E7EAE9` |
| surface | `#101E22` | `#F3F5F3` |
| surface-2 | `#16282D` | `#DBE1DF` |
| rule | `#1F363C` | `#C6CFCC` |
| rule-strong | `#2C4A51` | `#9FABA7` |
| text | `#DEE7E7` | `#0F1E20` |
| text-dim | `#93A7A9` | `#485A5B` |
| text-faint | `#748A8D` | `#5A6B6C` |
| **signal** | `#F0714A` | `#BF3F1B` |
| on-signal | `#0B1417` | `#FFFFFF` |
| beacon | `#55BCB0` | `#146C64` |
| good | `#6FBF73` | `#2C7537` |
| warn | `#E0A33E` | `#8E5D0E` |

The two signals are **not** the same colour lightened. `#F0714A` on paper is
far too weak; `#BF3F1B` is the light theme's value and holds.

⚠️ **`#BF3F1B` is 4.40:1 on the light ground — AA-large only.** Fine for the
logotype (WCAG exempts logotypes and brand names from contrast minimums) and
fine at large sizes. Measure before using it on normal-size light-theme text.

⚠️ **The palette is copy-pasted into each HTML file, and drift has already
happened twice.** Grep every file when changing a colour.

## Three tiers — and the thresholds are arithmetic, not taste

Scaling a 100-unit box to 24 px multiplies every dimension by 0.24. Anything
that lands under 1 px is not drawn, so the artwork changes with the size
instead of being shrunk and hoped for.

| Tier | Size | What is drawn |
|---|---|---|
| **Full** | 48 px and above | hull, cargo, six nodes + spokes |
| **Compact** | 28 – 47 px | nodes dropped, cargo kept (gaps are 1.1 px at 28) |
| **Micro** | 27 px and below | cargo alone, **enlarged to fill the frame** |

At 48 px every element still clears 1 px — that is the full mark's floor. At
28 px the spokes and nodes have gone sub-pixel but the cargo gaps survive at
1.1 px. Below that the hull is dropped and the cargo is redrawn at full frame,
where the same three bars are 2.9 px tall with 1.1 px between them at 16 px —
the identical margin the compact tier has at 28.

**Enlarging is the whole point of the micro tier, not a stylistic choice.** At
the hull's own scale a cargo bar is 1.1 px at 16 px, which is not a bar.

This rule has been broken once in production: the site's favicon was the
compact tier at 16 px until 2026-08-21. If a size looks wrong, check the tier
before checking anything else.

### Geometry, for anyone redrawing

100-unit box. Hexagon centred (50,50), half-width 22, half-height 24. Three
cargo bars **knocked out** of the hull with `fill-rule="evenodd"` — heights 7,
gaps 4, widths 28 / 21 / 14, a 1 : 0.75 : 0.5 taper. Six nodes r=5 on each
vertex's outward axis.

Micro tier keeps the same taper drawn **positive** instead of as holes:

```
x 9      y 66   w 82     h 18   rx 2
x 19.25  y 41   w 61.5   h 18   rx 2
x 29.5   y 16   w 41     h 18   rx 2   ← signal
```

Signal is the top bar in all three tiers. In a one-colour setting signal
resolves to the ink and the mark still reads.

The knock-out is why one drawing serves ground, paper and reversed alike.

## Clear space and minimums

- **Lockup clear space: ¼ the mark's width** on every side.
- **Never animate below 28 px.** The pulse is a 4.5 s cycle, six beats of
  0.75 s, and it is the only loop in the system. It stops on a hidden tab and
  stops completely — not slower — under `prefers-reduced-motion`.
- **Every animated part's resting state is its finished state**, so a still
  render (a PDF, a preview card) shows the finished mark, never a half-drawn
  one.

## What not to do

- ❌ Don't put a **service count** on anything a platform caches — social
  cards, `og:description`. A stale number on the page is a one-minute fix; a
  stale number in a platform's cache cannot be fixed at all.
- ❌ Don't use both avatars at once. `avatar-paper` is the default for platform
  accounts; `avatar-dark` is for light grounds. Recognition needs sameness.
- ❌ Don't use the lockup below ~128 px wide. The wordmark becomes a smear.
- ❌ Don't run a preset over the wrong shape. A favicon preset over the 442×295
  lockup produces 16×11 PNGs of a wordmark; a social preset over a square
  avatar produces a 1200×1200 "card". The converter now refuses both.
- ❌ Don't recolour the hull to signal, and don't put signal behind the mark as
  a full ground. Both were built, shown and rejected.
- ❌ Don't merge an inheriting file with a ground-painting one.

## Making PNGs

Use `website/svgtopng.html` — open it in a browser and drop an SVG on it.

It is a local page rather than a command, and that is the correct choice, not
merely the safe one: the wordmark is **live text** in a monospace stack, and a
converter running in a container renders it in whatever fonts that container
carries — usually none of the ones named — so the logotype comes out in a
fallback face. A browser renders it in the fonts the identity was designed on.

> The container route is a dead end already paid for: `minidocks/librsvg` does
> not contain `rsvg-convert`. Don't reach for another image.

Rasterise a logotype **once, on one machine**, and ship the PNG. Do not
regenerate it per platform.

## Before you add or edit a file

**SVG is XML, and an XML comment may not contain two hyphens in a row.** CSS
custom property names all start with two hyphens, so a comment explaining one
breaks the whole file — the parser rejects the document, not the line. This
has broken a shipped asset once. Describe the token instead of writing it.

Then validate. Not with a grep for `--`, which cannot tell a comment from a
`<style>` block and reports thirty legal CSS properties as faults:

```bash
powershell -c "Get-ChildItem -Filter *.svg -Recurse | %{ try { $null=[xml](Get-Content -Raw $_.FullName); \"OK     $($_.Name)\" } catch { \"BROKEN $($_.Name)\" } }"
```

Two more traps already paid for:

- **Frame from the rendered bounding box, not the construction grid.** The full
  mark's artwork occupies x 11–89, y 9–91 of its 100-unit box. A transform
  framed on the grid sits visibly high and left.
- **Give every `mask` and `id` a name unique to its file.** Two elements
  sharing an id in one document is a coin toss. Current ids: `x-cargo-rm`
  (README lockup), `og-cargo-rm` (card).

## Where the assets are used

| Asset | Used by |
|---|---|
| `dockhub-lockup` | the website hero, inlined into `index.html` |
| `dockhub-lockup-readme` | the root `README.md` |
| `og-card` | `og:image` / `twitter:image`, uploaded to the site root as `og-card.png` |
| `favicon` | the site's tab icon, inlined as a data URI — the file itself is not linked |
| avatars | platform accounts, uploaded by hand |

The site is a **two-file upload**: `og-card.png` to the root **first**, then
`index.html`. Crawl the page before the image lands and the platform caches an
imageless card for days.
