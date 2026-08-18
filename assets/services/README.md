# Service icons — and what they are not

Icons in this folder are **drawn by DockHub**. They are **not** the official
marks of the projects they sit beside, and must never be presented as such.

## The rule

DockHub does **not** copy, trace, recolour or redistribute another project's
logo. Trademarks belong to their owners, and a catalogue entry is not a
licence to use someone's brand.

So there are exactly two cases:

| The upstream project… | What the catalogue shows |
|---|---|
| **publishes a logo** | nothing here — link to their project and let their own site carry their mark |
| **publishes none** | an icon drawn here, from scratch, clearly labelled unofficial |

Every file in this folder is the second case. Each one carries the disclaimer
inside the SVG itself, not only in this README — because a file gets copied
out of its folder and the comment travels with it.

## What's here

| File | For | Why it exists |
|---|---|---|
| `paperclip.svg` | [Paperclip](../../services/Multi-Agent/paperclip/) | Checked 2026-08-18: `paperclipai/paperclip` ships no logo, icon or brand asset. The catalogue entry would otherwise be blank. |

## If upstream publishes one later

**Delete the file here.** Do not keep both — two marks for one project is how
an unofficial drawing quietly becomes mistaken for the real one. Removing it
is the correct outcome, not a loss.

## Drawing conventions

So the set reads as one system rather than a pile of clip art:

- `viewBox="0 0 100 100"`, artwork centred on 50,50 by its **inked** extent —
  geometry plus half the stroke width, which `getBBox()` does not include
- DockHub's palette, via the same two-level `var()` the main mark uses:
  the page's token when one is inherited, the file's own when standalone —
  under **different** names, so inlining an icon never overrides the palette
  of the page it lands in
- light and dark handled with `prefers-color-scheme`
- no external fonts, no raster images, no network references

---

← Back to [all services](../../services/README.md)
