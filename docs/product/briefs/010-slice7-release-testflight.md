# 010 — Slice 7: hardening + public TestFlight beta

**Status:** building: every PR in the sequence is merged except the first Fly deploy and the first TestFlight upload, which need the PM's go · **Owner:** PM · **PR:** #79, #90, #91, #101, #102, #117, #118, #120–#124 · **Updated:** 2026-11-14

## Problem
The app runs only on a laptop with dev sign-in. Nobody outside can try it.

## Who it's for
Pilot testers who tap a public TestFlight link, and Apple's Beta App Review.

## What success looks like
A stranger taps the link, installs, signs in with Apple, and gets through the PRD §15 demo
(phone-only) against the hosted backend. They can delete their account from Profile.

## Acceptance criteria
- [ ] **Sign in with Apple:** a nonce-bound identity token is verified server-side (Apple JWKS,
      aud/iss/exp/nonce), and `AUTH_MODE=apple` is used in production. Dev-login stays dev/test
      only. Existing tests are unchanged.
- [ ] **Sign in with Google** (added 2026-11-14, DECISIONS #33): a second button under Sign in
      with Apple. The phone signs in through the system web sign-in sheet (no Google SDK in the
      app) and sends Google's ID token; the backend verifies it (Google JWKS,
      aud/iss/exp/nonce) at `POST /v1/auth/google`. Apple and Google sign-ins are separate
      accounts, never merged by email.
- [ ] **Account deletion** in Profile deletes the user's data and media and revokes the Apple
      token (`/auth/revoke`) (guideline 5.1.1(v)).
- [ ] **Review access:** a production-safe, single-account review login (secret code, rate
      limited, read/write only its own sandbox data) for Beta App Review. It is documented in the
      review notes.
- [ ] **Hosting:** a Fly app (web + worker process groups, ffmpeg in the image, alembic as the
      release command, health checks), Neon Postgres, Tigris bucket, secrets only in Fly. Runbook
      at `docs/release/backend.md`.
- [ ] **Hardening:** per-IP and per-user rate limits, the cost guard verified in production
      config, no raw photos or audio in logs, graceful permission-denied states, error-state UI pass.
- [ ] **iOS release config:** production API URL, server-URL override hidden outside debug,
      `ITSAppUsesNonExemptEncryption=NO`, privacy manifest + App Privacy answers drafted, build
      number from CI, and the archive exported headlessly with an App Store Connect API key.
- [ ] **Pipeline doc** `docs/release/testflight.md`: every human step (App ID + SIWA key, ASC app
      record, API key, privacy and test info, external group, public link), then a scripted
      `make release-ios`.
- [ ] Section 15 demo script passes end to end on a TestFlight build on a real iPhone.

## Out of scope
App Store submission, payments, Android, analytics SDKs.

## Open product questions
1. **Beta tester cap on the public link?** A) 100, B) 1,000, C) 10,000 (the Apple max).
   **Recommendation:** A. 100 keeps Gemini spend predictable within $25; it can be raised later.
   → *Answer:* **A, 100 testers** (DECISIONS #20).
2. **Support / privacy contact email shown to testers and Apple?** **Recommendation:**
   jacogoby@gmail.com (personal), or a new alias you create.
   → *Answer:* **jacogoby@gmail.com** (DECISIONS #20).

## PR sequence
The PM's go (2026-11-14): host the backend, replace the dev sign-in code with Sign in with Apple
for testers, and clear every blocker to an internal and then an external TestFlight build.

0. Docs: this sequence.
1. Backend: Apple identity-token verifier (JWKS, aud/iss/exp/nonce) and `POST /v1/auth/apple`,
   mounted only when `AUTH_MODE=apple`.
2. Backend: authorization-code exchange, stored Apple refresh token, and `DELETE /v1/me`
   (data, queued media, Apple token revoke).
3. Backend: review login (one account, secret code, rate limited, its own sandbox data).
4. Backend: per-IP and per-user rate limits, and a production-config check for the cost guard.
5. Backend: Dockerfile, `fly.toml` (web and worker, alembic release command, health checks)
   and `docs/release/backend.md`. The first deploy needs the PM's go in the session.
6. iOS: Sign in with Apple (entitlement, button, `AuthStore` flow). Dev sign-in stays in debug
   builds only.
6a. Backend: Google ID-token verifier and `POST /v1/auth/google`, stacked on PR 1.
6b. iOS: Sign in with Google button and web sign-in sheet (PKCE), stacked on PR 6.
7. iOS: delete account in Profile.
8. iOS: release config (production API URL, server override hidden outside debug, build
   number), `make release-ios` and `docs/release/testflight.md`.
9. iOS: permission-denied and error-state pass, App Privacy answers and review notes.

Internal TestFlight needs PRs 1, 5, 6 and 8. External adds 2, 3, 4, 6a, 6b, 7 and 9.

**Human steps (PM):**
- Developer portal: App ID `com.umma.ios` with Sign in with Apple and Associated Domains.
- Developer portal: a Sign in with Apple key (`.p8`), needed for token revoke in PR 2.
- App Store Connect: the app record (SKU `umma-ios-001`), then Test Information and the
  external group.
- Google Cloud (personal account): OAuth consent screen and an iOS OAuth client for
  `com.umma.ios`. The client ID is not a secret.
- A Neon project on a personal account, and the go for the first Fly deploy.

## Engineering decisions (filled in by the lead while building)
- Hosting: `fly.toml` sits at the repo root because the image needs `fixtures/`. One web
  machine and one worker, kept running. Migrations run once per deploy as the release command.
- Rate limits are held in memory on the one web machine (#118). The caller's address is read
  only from Fly's `Fly-Client-IP` header. IPv6 callers are keyed on their /64 with a /48 cap. A
  full table degrades to wider shared buckets and is never cleared. Costly routes are marked on
  the route, and a test fails on an unclassified write route. A rolling deploy resets the
  limiter. A shared store is the step up if a second web machine is added.
- Production refuses to start with dev sign-in, without all four AI caps stated, or without the
  client-address header.
- Sign in with Apple sends an optional `authorization_code`; the server stores the refresh token
  encrypted with a key derived from `JWT_SECRET` (#120). Rotating that secret skips later revokes.
- Account deletion (#121): a recipe another person has cooked, saved, adapted or suggested a
  swap on is kept under an anonymous "Former Umma cook" account, served without the creator's
  clips or cover link; the stored version is not changed. Other recipes are deleted. The Apple
  revoke is tried once. Free text the creator typed stays on a kept recipe. **Open product
  question: keep anonymised, or make private.**
- Review login (#122): `POST /v1/auth/review`, absent until `REVIEW_LOGIN_CODE` (20+ characters)
  is set. Only wrong codes spend the shared budget, so the reviewer cannot be locked out.
- iOS: the production URL and the Google client ID live in `BuildConfig.swift`. `make
  release-ios` archives only; `UPLOAD=1` uploads. The build number defaults to a UTC timestamp.
- iOS: Google sign-in uses the system web sheet with PKCE and shares Safari's cookies. The
  button is hidden until a client ID is set, and has no Google logo yet.
- iOS: signing out, deleting the account, changing server or a different account signing in
  removes recorded transcripts from the phone. An expired session keeps an unsent recording.
- Universal links and share links use `ummacooks.app`. The site has no recipe page yet and the
  backend's `SHARE_URL_BASE` default still says `umma.app`.
- Not verified: any real Fly, Neon, Tigris, Apple or Google call; a release archive.

## Risks / what could go wrong for users
- Beta App Review rejects the build. Mitigation: phone-only build, a review account, clear notes,
  and the AI features labelled.
- The Neon free tier sleeps, giving a slow first request. Mitigation: a health ping, and the
  $19 plan if it hurts.
