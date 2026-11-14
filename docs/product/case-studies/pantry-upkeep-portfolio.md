# Keeping a pantry true

**Portfolio case study, draft · Umma · written 2026-11-14**

Sources: briefs 004, 012, 016 and 017, DECISIONS #11–13, #22, #28 and #29, and the internal
decision record `pantry-removal.md` in this folder. Items marked **[fill in]** need evidence
that doesn't exist yet. The list at the end says what to collect.

## Summary
Umma teaches people to cook a creator's recipe with the ingredients they actually have. That
promise depends on the app knowing what is in the kitchen. Talking to the cooking coach is the
low-effort part of the product. Keeping the pantry accurate is the high-effort part, and a stale
pantry makes every recommendation wrong. This case study covers how I moved from "make adding
items faster" to "stop asking the camera a question it can't answer", and the three ways into
the pantry that came out of it: voice, a live camera scan, and grocery receipts.

## The problem
The first pantry (October 2026) had three entry methods: speak a list, photograph a shelf, or
type an item. Every detected item was a suggestion the cook had to tick before it was saved.
That rule was deliberate. The product principle is "no silent state changes", and a pantry the
user didn't confirm isn't one they trust.

It cost too much effort in two places:

- **Stocking.** A real kitchen holds 30 to 40 items. In a walkthrough of the dinner-time journey,
  a cook who listed seven items still opened a recipe to "You're missing 4 and check 4".
- **Upkeep.** Nothing kept the pantry true after day one. Food gets eaten, and the app went on
  promising dishes the cook could no longer make.

## Step 1: make adding fast
The live scan lets the cook pan the phone across the fridge and cupboards. Each ingredient
appears as a word on screen and drops into a basket. To make that worth using I relaxed the
confirm-everything rule, with limits:

- Only high-confidence items that match the ingredient dictionary are saved without a tap.
- They are labelled "Auto-added" and can be removed.
- Anything the model is unsure of, or that matches an item already in the pantry, still needs
  the cook's tap.
- The camera runs only while the scan screen is open, and frames are never stored.

## Step 2: the half that wouldn't solve
Adding was the easy half. The hard half was how the pantry learns that something is gone. I
tried five designs, and each one failed on a specific case:

| Idea | What broke it |
|---|---|
| Ask at the end of a scan: "Didn't see these 4. Still have them?" | It adds another confirmation screen, which is the effort I was trying to remove. |
| Drop an item after two scans miss it | **The cupboard.** Scanning only the fridge would count against condiments in a cupboard nobody scanned. |
| Count a miss only if neighbouring items were seen | **The drawer.** A fridge drawer left shut for two scans would lose everything in it. |
| Expiry clocks | They guess from a calendar, not from anything that happened. |
| Remove ingredients when a recipe is cooked | **Three bags of chicken.** Using one bag would remove "chicken". |

Each fix added a rule and a new edge case. That pattern meant the model underneath was wrong,
so I stopped patching it.

## The insight
A handheld camera can prove an item is there. It cannot prove an item is gone. Not seeing the
milk could mean it's used up, it's behind the juice, or it's somewhere the camera didn't look.
Every scan-based removal idea was asking the sensor for something it can't provide.

So removal moved off the camera and onto evidence of things that actually happened.

## The design
**Three ways in**

1. **Voice.** "I've got eggs, rice, spinach." The coach reads back the count and asks only
   about what's ambiguous ("Got eight. What kind of cheese?").
2. **Live camera scan.** Used for the first stock-up, and whenever there's no receipt.
3. **Grocery receipt.** One photo after a shop. It is the only source that brings counts and
   dates, and buying an item again renews it.

**Ways out, all in the cook's own words**

- **Key-ingredient card.** A dish depends on its main ingredient, and the rest can be swapped.
  Opening a recipe shows that ingredient first: "Beef · last seen 6 days ago", with **Still
  have it** and **Don't have it**. This is the one confirmation I kept, because it sits where a
  wrong answer costs the most.
- **"I don't have that."** Saying it mid-cook removes the item and offers a swap from what the
  cook does have.
- **Shopping list.** Whatever was missing or ran out is collected into a list, and the next
  receipt ticks it off.

## Trade-offs I accepted
- Food used outside Umma stays in the pantry until the key-ingredient card or a spoken "I don't
  have that" catches it. That is the cost of never removing anything silently.
- Receipts and the live scan save high-confidence items without a per-item review. The guards
  are the dictionary match, a visible source chip, and Undo for a whole receipt.
- Shopping without a receipt (a market, a housemate's shop) still needs voice or the camera.
- Automatic decrement on cooking stays off until receipt counts prove reliable.

## Where it stands (2026-11-14)
- Speak, photo and typed entry with per-item review: shipped (October 2026).
- Live scan: backend, camera frame stream and Gemini Live transport are merged. **[fill in]**
  whether the scan screen has reached a tester.
- Receipts, the key-ingredient card, "I don't have that" and the shopping list: direction
  approved, first of eight PRs merged (the receipt reader).
- Voice mode: the voice core is merged. Pantry by voice inside a voice session is a later PR.

## What I took from it
- Check what a sensor can prove before designing around it.
- When every fix adds a rule and a new edge case, change the model, not the rules.
- A principle like "confirm everything" can be relaxed if each exception is bounded, labelled
  and reversible.
- Spend the user's confirmations where a wrong answer costs most.

## To collect before this goes in the portfolio
- **[fill in] Stocking time.** Minutes to stock a real kitchen by voice, by photo and by live
  scan, plus how many items Pantry fit shows as Available afterwards.
- **[fill in] Receipt accuracy.** Brief 017 plans a test on five real receipts: lines read,
  skipped and wrong.
- **[fill in] Drift.** After two weeks of real use, how many pantry items are no longer in the
  kitchen.
- **[fill in] Voice quality.** The claim that cooking by voice is smooth and natural needs a
  tester session or a recording. Paid server voice hasn't had its first live call yet.
- **[fill in] Screens.** Live scan basket, receipt result banner, key-ingredient card and
  shopping list. Existing shots cover only the October pantry (`docs/briefing/assets/`).
- **[fill in] My role and timeline.** One line on who did what (PM direction, AI-assisted
  build) and the dates: 23 Oct first pantry, 13 Nov live scan, 14 Nov upkeep decision.
