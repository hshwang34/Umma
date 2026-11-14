# Beta App Review notes (draft, brief 010)

Paste the "Notes for the reviewer" section into App Store Connect → TestFlight → Test
Information → Beta App Review Information → Review Notes. Fill in the two bracketed values at
that moment; they are never written in this repo.

## Before pasting: what the PM fills in

- **[REVIEW CODE]**: the review login secret. It exists only as a secret on the hosted
  backend (see `docs/release/backend.md`). Copy it from there into App Store Connect's review
  notes field. Do not put it in this file, a commit, a PR or a chat.
- **[HOW TO ENTER IT]**: the exact taps to reach the review login in the build being
  submitted. See "Open item" below: the app-side entry for the review login is not in this
  build series yet, so this line cannot be written until it is.
- Contact: first and last name, phone, jacogoby@gmail.com.
- "Sign-in required": yes.

## How the review login works (for us, not for pasting)

- The backend exposes a review login for Beta App Review: **one** fixed review account, opened
  by a secret code instead of Apple or Google sign-in.
- It is rate limited, and the account can read and write only its own sandbox data. It cannot
  see or change any real tester's recipes, pantry or sessions.
- It is safe in production: it is the only non-Apple, non-Google way in, the code is a server
  secret, and rotating the secret closes it.
- Dev sign-in (email and a 6-digit code from the server log) does not exist in the TestFlight
  build or on the production backend.

## Notes for the reviewer (paste from here)

Umma is a cooking app. A person records a recipe once, and anyone can then cook it step by step
with the ingredients they actually have.

**Signing in**

- Testers sign in with "Sign in with Apple" (first button) or "Sign in with Google".
- For review, a dedicated review account is available without an Apple or Google account:
  [HOW TO ENTER IT]. Review code: [REVIEW CODE].
- The review account has its own sample data and cannot affect other people's data.

**What to try (about 5 minutes, iPhone only, no accessories needed)**

1. Explore: open a recipe. Change the servings; the ingredient amounts rescale.
2. Pantry: add a few items by typing. Camera and voice entry are optional and ask for
   permission only when tapped. If a permission is declined, the screen explains why it is
   needed and offers "Open Settings"; typing still works.
3. Back on the recipe: see which ingredients you have, and try a suggested swap.
4. Start cooking: move through the steps with Next. Ask the coach a typed question.
5. Profile: "Delete account" permanently deletes the account and its data.

**AI features**

- Recipe drafts, pantry recognition, swaps and the cooking coach use a generative AI model on
  our server. AI-written content is labelled in the app, and a person confirms every change
  before it is saved. The app never claims food is safe or cooked through from a photo.
- Allergies a person enters always override AI suggestions.

**Permissions**

- Camera: only when the person taps to scan the pantry or show a step.
- Microphone and Speech Recognition: only while the person is talking to the app.
- Nothing is recorded in the background.

**Other**

- No purchases, ads, tracking or third-party SDKs.
- Meta AI glasses are mentioned in the product description as an optional accessory; this
  build is phone-only and needs no hardware.
- Account deletion: Profile → Delete account (guideline 5.1.1(v)). It also revokes the Sign in
  with Apple token.
- Support and privacy contact: jacogoby@gmail.com. Privacy policy:
  https://ummacooks.app/privacy.html

## Open item

The iOS app has no screen for the review login yet (brief 010's iOS PRs cover Apple, Google,
delete account, release config and error states). Until an entry point exists, a reviewer
cannot use the review code. Options:

- A) Add a small "Have a review code?" link under the sign-in buttons in release builds
  (recommended: Apple expects a working demo login when sign-in is required).
- B) Give the reviewer a real Apple ID or Google test account in the notes instead and keep the
  review login server-only.
