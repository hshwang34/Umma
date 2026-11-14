# 021 — Plain words, calmer screens

**Status:** in review · **Owner:** PM · **PR:** see "PR sequence" · **Updated:** 2026-11-14

## Problem
The app was written feature by feature, and the words on screen show it. Three things got in a
cook's way:

- **Our vocabulary leaked onto the screen.** "Checking with the server…", "pinned sessions",
  "Publish version 2?", "This snapshot can't be edited", "Low uncertainty".
- **One word meant two things.** A "cook" was both a person you follow ("Follow cooks you'll
  love") and a recipe in progress ("You have too many unfinished cooks").
- **Screens carried things nobody needs.** The recipe page ended in four full-width buttons
  (Save, Share, Edit, Unpublish) under the recipe. Profile showed testers a "Device" section
  with camera and microphone status, an empty "Drafts" heading, and footers explaining how to
  tap and swipe.

The PM asked for a pass on UX writing and clutter, following iPhone conventions, and delegated
the calls (2026-11-14).

## Who it's for
Every tester in the TestFlight pilot, at every screen. Most of all a first-time cook, who
reads these words without knowing how the app works inside.

## What success looks like
- Nothing on screen names the server, a session, a version number or a tap being "confirmed".
- A recipe in progress is never called "a cook".
- The recipe page is the recipe plus two buttons: Check my pantry and Start cooking.
- Profile opens on who you are and your recipes, with no diagnostics.

## The writing rules (apply to all new copy)
1. **Say what happened and what to do next, in the cook's words.** "Reconnect to continue",
   not "Checking with the server".
2. **One word per thing.** A *cook* is a person. A *recipe* is what you are cooking, also while
   it is in progress. A *swap* is a replacement ingredient (never "substitute"). You *cross
   off* a shopping item and *select* a scanned item.
3. **Never show our internals:** server, session, version number, snapshot, cached, pinned.
4. **Don't explain standard gestures.** No "tap to open, swipe to delete" footers. A footer
   earns its place only when it says something the screen can't.
5. **Mark the exception, not the rule.** A published recipe needs no "Public" badge; an
   unpublished one gets one.
6. **Errors start with "Couldn't …"** and say whether anything was lost.
7. **Sentence case, US spelling** (it matches the US units and "flavor" already in the app).
8. **Privacy and safety promises stay.** Shorter is fine; dropping "the photo isn't kept" or
   "check the label" is not.

## Acceptance criteria

**Recipe page**
- [x] Save and Share are icons in the top bar. The owner's Edit and Unpublish are in a "More"
  menu next to them. Nothing but Check my pantry and Start cooking sits under the recipe.
- [x] The "v2" badge shows only to the recipe's owner.
- [x] A failed Save, Edit or Unpublish shows its message at the top of the page.
- [x] Unpublishing reads the same on the recipe page and in Profile, with no "pinned" or
  "version".

**Profile**
- [x] Order: account, My recipes, Drafts, Cooking, Sign out, Delete account.
- [x] The Device section (camera, microphone, speech, server) shows only in debug builds.
- [x] Drafts appears only when there is a draft.
- [x] My recipes rows show a badge only when a recipe is not public or has a draft in progress.
- [x] No footer explains taps or swipes.

**Cooking**
- [x] No on-screen text contains "cook" for a recipe in progress, "session" or "server".
- [x] The offline banner says what didn't go through by name ("“Next” didn't go through").
- [x] The coach's certainty reads "Fairly sure", "Not certain" or "Unsure, double-check".

**Pantry, shopping, Explore**
- [x] Shopping uses "cross off"; scan review uses "select" and "deselect".
- [x] Pantry fit and its tests say "You can make this" where they said "Can make it".
- [x] The offline Explore notice says "Showing recipes from earlier", not "cached".

**Publishing and recording**
- [x] Publishing asks "Publish this recipe?" the first time and "Publish your changes?" after.
  The confirmation says who can see it and that it can be edited later.
- [x] The success screen says "Your recipe is published" or "Your changes are published".

**Everywhere**
- [x] The unit tests that pin on-screen text are updated with it, and the suite passes on iOS CI.

## Out of scope
- Button labels in the first person ("Check my pantry", "Save my changes"). Apple's guidance
  prefers "your", but these are used consistently and changing them touches every flow. See
  open question 1.
- "Creator" versus "cook" for the person who wrote a recipe. The PRD's provenance label is
  "Creator instructions", so "creator" stays wherever a recipe's source is named.
- Swap confidence labels ("High confidence"). Rewording them risks overclaiming.
- The sign-in screen's dev-only text, and Server settings (debug builds only).
- Localisation. Strings stay inline.
- Any backend-supplied message.

## Open product questions
1. **Should buttons speak as the cook ("Check my pantry") or to the cook ("Check your
   pantry")?** Options: A keep "my" on buttons and "your" in sentences (today), B "your"
   everywhere. **Recommendation:** A for the pilot. It is consistent and reads as the cook's
   own choice. → *Answer:* not asked; A stands until the PM says otherwise.
2. **Is "Cook without it" the right label when no swap is found?** It replaced "Keep it
   missing". The button only closes the sheet; the ingredient stays listed as missing.
   **Recommendation:** keep it. → *Answer:* eng lead's call under the delegation, PM may revisit.

## PR sequence
1. Docs: this brief and DECISIONS #37.
2. iOS: recipe page and Profile declutter.
3. iOS: cooking wording (one word for a recipe in progress, no server talk).
4. iOS: pantry, shopping and Explore wording.
5. iOS: editor, publishing, recording, sign-out wording and US spelling.

PRs 2–5 are stacked; iOS CI runs once on the top branch (DECISIONS #32).

## Engineering decisions (filled in by the lead while building)
- Shared unpublish wording lives in `RecipeCopy` (in `RecipeDetailView.swift`) so the recipe
  page and Profile cannot drift.
- Accessibility identifiers are unchanged (`recipe.save`, `recipe.share`, `recipe.edit`,
  `recipe.unpublish`), plus a new `recipe.more` for the owner menu. The live smoke test looks
  for the bar button "Saved" and the title "Your recipe is published".
- While Edit or Unpublish is running, the More menu is replaced by a spinner.
- `SessionStarterTests` now also fails if "unfinished cooks" comes back to the sheet.
- Review round 1 found four problems, all fixed: the unpublish text wrongly said a link still
  opens the recipe (only the owner, savers and people already cooking can); the photo-scan
  intro had lost "only when you tap it"; the offline detail line showed while online; the
  smoke test expected the old publish title.
- Verified locally with `xcodebuild build-for-testing` (no simulator booted). The unit suite
  runs on iOS CI.

## Risks / what could go wrong for users
- **Save and Share move.** A tester used to the buttons under the recipe has to find them in
  the top bar. This is where iPhone apps put them, and VoiceOver labels are unchanged.
- **Not seen on a phone yet** (the simulator pool was full on 2026-11-14). The layout change compiles and follows standard toolbar
  behaviour, but nobody has looked at it on a device or at the largest text sizes.
- **The briefing screenshots are stale** for the recipe page, Profile and the cooking banner.
