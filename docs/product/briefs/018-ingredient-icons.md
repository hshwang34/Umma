# 018 — Ingredient icons

**Status:** approved (direction A, 2026-11-14) · **Owner:** PM · **PR:** — · **Updated:** 2026-11-14

## Problem
The pantry is a list of plain words. With 30 items, "garlic", "ginger" and "gochujang" look
the same at a glance, so finding one means reading every row. Pantry fit and Swaps have the same
problem. Nothing on those screens feels like Umma; they look like a settings list.

## Who it's for
Every cook, every time they open Pantry or check whether they can make a recipe. Most of all
the 7 pm cook scanning the list on the way to a decision.

## What success looks like
- A cook can find garlic in a 30-item pantry by its icon before they read the word.
- The icons look like they belong to the persimmon mark: same flat fills, same palette, same
  cut-out details.
- An item Umma doesn't recognise still gets a sensible icon, never an empty gap.

## Direction (PM, 2026-11-14)
Option A, "Persimmon flat", from `docs/briefing/umma-pantry-icon-options-2026-11-14.html`.
The icons are drawn the way the mark is drawn:
- flat fills in the brand palette
- no outlines
- details cut out of the fill as real gaps, so the icons sit on any background
- a gap where one shape overlaps another, like the calyx and the fruit

Emoji (option 1) were rejected as off-brand.

## Acceptance criteria
- [ ] **Icon set.** About 55 drawn forms, each a vector asset with a light and a dark version.
  Together they cover every entry in the ingredient dictionary (`fixtures/ingredients.json`).
  - Ingredients that share a form, such as the bottled sauces, share its drawing with their own
    colours: soy sauce dark, rice vinegar pale, fish sauce amber.
  - Each category has its own fallback icon, and items that match no ingredient get a basket.
- [ ] **One source of truth.** A generator in `docs/brand/tools/` holds the geometry and writes the
  SVG imagesets and a review gallery (`docs/brand/ingredient-icons.html`), as
  `umma-brand.swift` does for the mark. Nobody hand-edits the generated files.
- [ ] **Dictionary.** Every dictionary entry names its icon. A test fails if an entry names an icon
  with no asset, or if an entry has no icon.
- [ ] **API.** Pantry items return `icon`: the ingredient's icon, else its category's, else
  `basket`. The field is additive, so older app builds ignore it.
- [ ] **Pantry row.** Each pantry row shows the icon at 28 pt before the name. VoiceOver skips it,
  because the name already says it.
- [ ] **Review sheets.** The scan, voice and receipt review rows show the icon for a matched
  candidate, and a basket for an unmatched one.
- [ ] **Unknown names.** If the app receives an icon name it has no asset for (a newer server), it
  shows the basket and never an empty space.
- [ ] **Accessibility.** The icon scales with Dynamic Type up to AX sizes. With Increase Contrast,
  the detail cut-outs stay visible.

## Out of scope
- Icons in Pantry fit, Swaps and recipe ingredient lists. They're the next PR once the set is
  approved; the asset names are the same.
- Photos of the user's own food. Frames are never kept (CLAUDE.md, capture invariants).
- Animated icons, and icons on recipe cards in Explore.

## PR sequence
1. **docs:** this brief and DECISIONS #30.
2. **assets:** the generator, the generated imagesets and the review gallery. Generated files
   don't count towards the 400-line guide. **The PM approves the gallery before PR 4 merges.**
3. **backend:** an `icon` key on every dictionary entry, `PantryItemOut.icon` with the fallback
   chain, and the asset-coverage test.
4. **iOS:** an `IngredientIcon` view, the pantry row and the review rows, and the fallback for
   unknown names.

## Open product questions
1. **Who draws the final set?** Options:
   - A (Claude draws it in code now, from the generator)
   - B (a designer redraws it later from the same asset names)

   **Recommendation:** A now. The asset names are stable, so B can replace the art without
   touching the app.
   → *Answer:* A, default; revisit after the gallery review.

## Engineering decisions (filled in by the lead while building)
- …

## Risks / what could go wrong for users
- **A wrong icon misleads.** For example, a chilli icon on a mild pepper. Icons are decoration:
  the name stays the source of truth, and the icon is never used to say whether an item matches.
- **Clash with brief 017.** Brief 017 is changing the same pantry row (the "From receipt" chip).
  The iOS PR rebases onto whatever lands first, and the icon sits before the name, away from the
  chips.
- **Colour-only meaning.** The icon never carries status, so a cook who can't tell red from green
  loses nothing.
