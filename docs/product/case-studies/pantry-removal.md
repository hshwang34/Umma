# Case study: how does the pantry learn that something is gone?

**Date:** 2026-11-14 · **Outcome:** brief 017, DECISIONS #29

## The question
The live scan (brief 016) adds items as the cook pans a phone across the kitchen. Adding is the
easy half. The PM asked the other half: how does a later scan work, and how does Umma know an
item was used up or replaced? Pantry management is one of Umma's differentiators, so a pantry
that drifts out of date undermines the product.

## The limit we kept hitting
A handheld camera can prove an item is there. It cannot prove an item is gone. Not seeing the
milk has three explanations: it's used up, it's behind the juice, or it's somewhere the camera
didn't look. Every scan-based idea below failed on that limit.

## What we tried, and what broke it

| Idea | How it would work | What broke it |
|---|---|---|
| Ask at the end of a scan | "Didn't see these 4 items. Still have them?" | The PM ruled out another confirmation screen. |
| Count misses per area | An item missed in two scans of its area is dropped | **The cupboard.** Scanning only the fridge must not count against condiments in a cupboard that wasn't scanned. Fixable by tracking areas. |
| Areas, then neighbours | A miss only counts if nearby items were seen | **The drawer.** A fridge drawer left shut for two scans would lose everything in it. Each fix added a rule and a new edge case. |
| Expiry clocks | Fresh food leaves the list after its shelf life | It guesses from a clock, not from anything that happened, and it adds friction when the guess is wrong. |
| Remove on cooking | Finishing a recipe removes what it used | **Three bags of chicken.** Using one must not remove "chicken". Without counts, this is wrong whenever the cook owns more than one. |

The PM stopped the patching: "There's no fix. Let's talk about a solution."

## What we decided
Stop asking the camera to detect removal. Use evidence of things that actually happened.

1. **Receipts bring items in, with counts and dates.** After the first camera scan, a photo of
   the grocery receipt updates the pantry. Buying an item again renews it.
2. **Confidence matters most for the key ingredient.** A dish revolves around its main
   ingredient (the beef, the chicken); the rest is replaceable. Opening a dish shows that
   ingredient first with when it was last seen, and the cook confirms or discards it. This is
   the one confirmation the PM kept, because it sits where the answer matters.
3. **The cook removes things by saying so.** "I don't have that, find a replacement from what I
   have" during cooking updates the pantry and offers a swap.
4. **What was missing becomes a shopping list,** and the next receipt ticks it off.

## What this leaves open
- Food used outside Umma stays in the pantry until the key-ingredient card or a spoken "I don't
  have that" catches it.
- Shopping without a receipt still needs voice or the camera.
- Automatic decrement on cooking is still off. Receipts make it possible, because they supply
  counts, but it waits until we know the counts stay accurate.

## Lessons
- Check what a sensor can prove before designing around it. The camera proves presence only.
- When each fix adds a rule and a new edge case, the model underneath is wrong.
- Put the one confirmation the product needs where a wrong answer costs most: the main
  ingredient, at the moment the cook picks the dish.
