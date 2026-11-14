# 020 — Cook for the people at your table: adjustable servings

**Status:** approved · **Owner:** PM · **PR:** — · **Updated:** 2026-11-14

## Problem
Every recipe shows "Serves 4" as a fixed label. A cook feeding one person, or six, has to do
the arithmetic for every ingredient in their head, while cooking. Pantry fit and the cooking
coach also only know the creator's original amounts, so "you have enough" and "how much soy
sauce?" are answered for the wrong number of people.

PRD §12.2 already asks for this: "When recipe changes serving count, scale straightforward
amounts but warn for season-to-taste, time, pans and some baking ingredients."

## Who it's for
A cook who has picked a recipe and is about to make it for a different number of people than
the creator wrote it for. Typically someone cooking for one or two from a family-sized recipe.

## Storyboard
1. Jun opens his mum's kimchi stew. It says **Serves 4**. He taps the servings control and
   dials it to **2**.
2. Every ingredient amount changes at once: 400 g pork becomes 200 g, 2 tbsp becomes 1 tbsp.
   A line under the control says "Scaled from 4. Cooking times and seasoning don't scale; taste
   as you go." One tap resets it.
3. Pantry fit updates for 2 servings: he now has enough kimchi.
4. He taps **Start cooking**. The confirmation says "Cooking for 2". Every amount on the cook
   screen is for 2, and when he asks "how much gochugaru?" the coach answers for 2.
5. Later he sets **Default servings: 2** in Profile. From then on every recipe opens already
   scaled to 2, still showing what it was scaled from.

## What success looks like
- A cook changes servings and never has to calculate an amount, on the recipe page or while
  cooking.
- Pantry fit, the cook screen and the coach always agree with the number on the dial.
- Nobody is surprised by a scaled recipe: it is always visible that amounts were scaled and
  from what, and the creator's original is one tap away.

## Acceptance criteria

**The dial (recipe page)**
- [ ] The "Serves N" pill becomes a control that steps through whole servings **1 to 6**,
  whatever the recipe's original servings are.
- [ ] A recipe written for more than 6 (say 8) gets its original as one extra stop after 6, so
  the dial reads 1, 2, 3, 4, 5, 6, 8. It opens at its original unless a default is set.
- [ ] Changing it rescales every ingredient amount immediately, with no loading state.
- [ ] When the value differs from the recipe's original, the page shows "Scaled from N" and a
  one-tap reset to the original.
- [ ] Whenever amounts are scaled, a short notice says that cooking times, pan sizes and
  seasoning don't scale.
- [ ] The control works with VoiceOver (adjustable, announces "2 servings").

**Scaling rules**
- [ ] Measured amounts (g, ml, tsp, tbsp, cup…) scale linearly and are shown as kitchen
  amounts (¼, ⅓, ½, ⅔, ¾ steps), never as long decimals.
- [ ] Count items (eggs, cloves, cucumbers) round to a usable amount: nearest half where a
  half makes sense, never zero.
- [ ] Ingredients with no quantity ("to taste") are left untouched.
- [ ] Prep and cook minutes, step text, success cues and warnings are never changed.
- [ ] At the recipe's original servings, every amount is exactly what the creator wrote.

**Pantry fit**
- [ ] Pantry fit is computed for the servings on the dial, and updates when the dial changes.

**Carried into cooking**
- [ ] Starting a cooking session records the chosen servings. The start confirmation states it
  ("Cooking for 2").
- [ ] Servings are **locked once cooking starts**. There is no servings control on the cook
  screen. To change it, the cook ends the session and starts again.
- [ ] Ingredient amounts on the cook screen, in step ingredient lists and in the coach's
  answers are for the session's servings.
- [ ] Resuming a session keeps its servings, even if the profile default changed since.
- [ ] Sessions started before this ships behave as the recipe's original servings.

**Default servings (Profile)**
- [ ] Profile settings has **Default servings**: "Recipe's own" (the default) or 1 to 6.
- [ ] While it is "Recipe's own", recipes open at the creator's servings, as today.
- [ ] Once set, every recipe opens scaled to that number, with the "Scaled from N" label. The
  cook can still change the dial on any recipe.
- [ ] A dial change applies to that recipe visit only. It does not change the default.

**Unchanged**
- [ ] The published recipe is never modified (published versions are immutable). Scaling is the
  cook's view and their session, nothing else. Other cooks and the creator see the original.
- [ ] Works with the mock AI provider (AI-off still works).

## Out of scope
- Changing servings in the middle of a cooking session.
- Scaling cook times, pan sizes or oven temperatures.
- Rewriting amounts that a creator typed into step text.
- Unit conversion while scaling (48 tsp stays tsp-based; no automatic "1 cup").
- Remembering a different servings choice per recipe.
- Scaling for creators in the editor, and half servings.

## Open product questions
None. Answered in DECISIONS #33.

## PR sequence
1. **Docs:** this brief and DECISIONS #33.
2. **Backend, scaling rules:** a pure scaling module plus a shared fixture of
   expected scaled amounts (the iOS tests decode the same file).
3. **Backend, default servings:** `default_servings` on the user (migration) and the profile
   API.
4. **Backend, pantry fit:** fit accepts `servings`. Lands after brief 017's key-ingredient
   PR (#76), which touches the same file.
5. **Backend, sessions:** `servings` on the session (migration), set at start, used for the
   session's ingredient amounts and the coach's grounding.
6. **iOS, dial:** the servings control, live scaling and the scaled notice on the recipe page,
   with pantry fit for the chosen servings.
7. **iOS, default setting:** Default servings in Profile.
8. **iOS, cooking:** "Cooking for N" at start, scaled amounts on the cook screen.

## Engineering decisions (filled in by the lead while building)
- The live dial is computed on the phone; pantry fit, sessions and the coach are computed on
  the backend. One shared fixture keeps the two implementations identical.
- Servings is a column on the session, not a field in `adaptation_json`, so it is validated
  and part of the session contract. Null means the recipe's original.

## Risks / what could go wrong for users
- **Odd amounts** (⅓ of an egg, 0.17 tsp). Mitigation: rounding rules per kind of unit, and a
  floor so nothing rounds to zero.
- **A cook doesn't notice the recipe opened scaled** because of their default, and cooks the
  wrong amount for guests. Mitigation: the "Scaled from N" label is always shown next to the
  dial and in the start confirmation.
- **Scaled amounts with unscaled times** (a doubled stew needs longer). Mitigation: the notice,
  and the creator's success cues stay as the real test of doneness.
- **Amounts written inside step text** ("add the 2 tbsp of soy") will not match the scaled
  list. Mitigation: seeded recipes keep amounts out of step text; the notice covers the rest.
