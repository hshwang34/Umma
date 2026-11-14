# 017 — A pantry that stays current

**Status:** approved (direction, 2026-11-14) · **Owner:** PM · **PR:** — · **Updated:** 2026-11-14

## Problem
The live scan (brief 016) fills a pantry quickly, but nothing keeps it true afterwards. A camera
can show that an item is there. It can't show that an item is gone: the milk may be used up,
behind the juice, or in a drawer nobody opened. So the pantry drifts, and Pantry fit starts
promising dishes the cook can't make. The case study
(`docs/product/case-studies/pantry-removal.md`) records the options we walked through and why
each was dropped.

The PM's direction (2026-11-14): no new confirmation screens, no expiry clocks and no silent
removal when a recipe is cooked. Pantry management is one of Umma's differentiators.

## Who it's for
The learner in their second week and after: the pantry is stocked, they shop once or twice a
week, and they open Umma to decide what to cook tonight.

## What success looks like
- After a shop, the cook photographs the receipt and the pantry is updated. They tap nothing else.
- Opening a dish, the first thing they see is its main ingredient and when Umma last saw it.
  One tap says whether it's still there.
- Mid-cook, "I don't have that, find a replacement from what I have" updates the pantry and
  offers a swap from what they do have.
- When they finish, a shopping list already holds what was missing or ran out. The next receipt
  ticks those items off.

## Acceptance criteria
- [ ] **Receipt entry.** Pantry has a Receipt entry (camera or photo library). One photo of a
      receipt is read by the model. The photo is never stored.
- [ ] **Receipt save rule.** A line is saved without review only when it is food, matches the
      ingredient dictionary and is high confidence. Saved items carry source `receipt` and a
      "From receipt" chip. Lines Umma can't read are skipped, never guessed, and are listed
      under the result banner with nothing to answer.
- [ ] **Rebuying renews.** A receipt line that matches an existing pantry item merges into it:
      the count is added when the units agree, and "last seen" is refreshed.
- [ ] **Same receipt twice.** Photographing the same receipt again changes nothing and says so.
- [ ] **Result banner.** "Added 12 items · 2 lines not read", with Undo for the whole receipt.
- [ ] **Key ingredient.** Pantry fit marks one ingredient per recipe as the key ingredient: a
      required ingredient named in the title; otherwise the first protein; otherwise the largest
      by weight. A recipe counts as "can make" only when its key ingredient is available and was
      seen within 14 days (DECISIONS #11).
- [ ] **Key-ingredient card.** The recipe screen opens with a card: "Beef · last seen 6 days
      ago", with **Still have it** and **Don't have it**. "Don't have it" removes the pantry
      item, adds it to the shopping list and offers a swap. If the key ingredient isn't in the
      pantry, the card says so and offers a swap or the shopping list.
- [ ] **"I don't have that."** During cooking, saying or typing that an ingredient is missing
      removes it from the pantry and adds it to the shopping list. If the cook doesn't name it,
      the current step's ingredient is used; if the step has several, the coach asks which.
- [ ] **Swap offer.** The same reply offers a swap drawn from the pantry. Applying it takes one
      approval (SUB-03). If nothing suitable exists, the coach says so (SUB-05).
- [ ] **Shopping list.** A Shopping list screen opens from Pantry. Items are added by the
      key-ingredient card, by "I don't have that", and at session finish (ingredients missing at
      the start that got no swap). Each item appears once. The cook can tick and delete items.
- [ ] **Finish screen.** "Added to your shopping list: 4 items".
- [ ] **Receipt closes the loop.** A receipt ticks off matching shopping-list items.
- [ ] **Spend.** Reading a receipt uses a new `pantry_receipt` capability inside the existing
      $0.25 per person per day cap (#19). Over the cap, the cook is told and nothing is saved.
- [ ] **AI-off.** With `AI_PROVIDER=mock`, a fixture receipt is read and labelled as a demo.

## Out of scope
- Counting "misses" in repeat scans, and any removal based on not seeing an item.
- Expiry clocks and freshness judgements.
- Automatic decrement when a recipe is cooked (DECISIONS #4 stands). Receipts bring counts in;
  taking them out automatically waits for evidence that the counts stay accurate.
- Emailed or forwarded e-receipts, and grocery-store accounts.
- Sharing or exporting the shopping list (Apple Reminders stays out, DECISIONS #2).
- Marking the key ingredient in the recipe itself. It is derived, so published versions don't change.

## Open product questions
1. **How do later pantry updates happen?** → *Answer:* voice, the camera scan, and grocery
   receipts (PM, 2026-11-14).
2. **What may be removed without a confirmation screen?** → *Answer:* nothing silently. Removal
   comes from the cook: the key-ingredient card, or saying "I don't have that" (PM, 2026-11-14).
3. **Grocery list now or later?** → *Answer:* now, as part of this brief (PM, 2026-11-14).
   Logged as DECISIONS #29.

## PR sequence
0. Docs: this brief, DECISIONS #29 and the case study.
1. Backend: receipt contract, Gemini and mock `read_receipt`, capability `pantry_receipt`.
2. Backend: `POST /v1/pantry/receipts`, the `pantry_receipts` table, the save and merge rule.
3. iOS: receipt capture and result banner, behind a flag.
4. Backend: `is_key` and `last_confirmed_at` in Pantry fit.
5. iOS: key-ingredient card.
6. Backend: `shopping_items` table and endpoints, the finish hook, receipt tick-off.
7. Backend: `missing_ingredient` coach intent.
8. iOS: in-cook swap offer, shopping summary on the finish screen, Shopping list screen.

## Engineering decisions (filled in by the lead while building)
- Receipts reuse the pantry photo upload path and the live scan's auto-save rule
  (`live_scan.finish`): dictionary-matched and high confidence only.
- `PantryItem.source` has no CHECK constraint, so `receipt` needs no schema change. The
  `pantry_receipts` table stores a hash of date, store, total and lines, unique per owner, plus
  the first result, so a repeat upload replays it.
- The ingredient dictionary already has a `category` field with 17 `protein` entries, which the
  key-ingredient rule uses.

## Risks / what could go wrong for users
- **A receipt line is misread** and a wrong item lands in the pantry with no review. Limited by
  the dictionary and high-confidence rule, the "From receipt" chip and the whole-receipt Undo.
  The real-receipt test (5 receipts) reports lines read, skipped and wrong before PR 3 ships.
- **Store abbreviations** ("CHKN THGH BNLS") get skipped, so the pantry misses real purchases.
  The banner shows how many lines weren't read.
- **Shopping with no receipt** (markets, a housemate's shop). Voice and the camera scan remain.
- **The wrong key ingredient is picked** for a dish with no clear main ingredient. The card
  still names a real ingredient of the dish, and the rest of Pantry fit is unchanged.
- **Food used outside Umma** stays in the pantry until the key-ingredient card or "I don't have
  that" catches it. This is the accepted cost of having no silent removal.
