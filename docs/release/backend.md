# Backend release runbook (Fly.io + Neon + Tigris)

Brief 010, DECISIONS #18/#19. Everything here runs on **personal** accounts
(`jacogoby@gmail.com`), never a work account. Nothing in this file is a secret; secrets live
only in Fly (`fly secrets`).

**Every production deploy needs the PM's one-line go at that moment (DECISIONS #18).**

What gets deployed: one Docker image (`backend/Dockerfile`), run as two Fly process groups
defined in `/fly.toml`:

| Process | Command | Notes |
|---|---|---|
| `web` | `uvicorn app.main:app --port 8080` | 1 machine, 512 MB, health check `GET /v1/health` |
| `worker` | `python -m app.workers.extraction` | 1 machine, 1 GB, creator-video jobs + media deletes (needs ffmpeg) |

`alembic upgrade head` runs as the Fly release command before each new version takes traffic.
Expected cost: about $3/mo (web) + $6/mo (worker) + Tigris storage; Neon free tier.

## 0. One-time checks

```bash
fly auth whoami        # must print jacogoby@gmail.com. If not: fly auth logout && fly auth login
docker build -f backend/Dockerfile -t umma-api:local .   # optional local build, from the repo root
```

All `fly` commands below run from the **repo root** (where `fly.toml` is).

## 1. Create the Fly app (human, once)

```bash
fly apps create umma-api --org personal
```

`umma-api` is a placeholder. Fly app names are global: if it is taken, pick another, change
`app = "…"` in `fly.toml`, and use that name everywhere below (the API host becomes
`https://<name>.fly.dev`, which the iOS release config must point at).

## 2. Neon Postgres (human, once)

1. Sign in to <https://neon.tech> with the personal account. Create project `umma`, Postgres 16,
   region **AWS US East (N. Virginia)** (next to Fly `iad`).
2. Copy the **direct** connection string (host without `-pooler`). The pooled endpoint breaks
   asyncpg's prepared statements.
3. Rewrite it for the app: scheme `postgresql+asyncpg://`, and `?ssl=require` instead of
   `?sslmode=require` (asyncpg does not accept `sslmode`; drop `channel_binding` too):
   `postgresql+asyncpg://USER:PASSWORD@ep-xxxx.us-east-1.aws.neon.tech/neondb?ssl=require`
4. The free tier sleeps after 5 idle minutes: the first request after a sleep takes a few
   seconds. If that hurts testers, move to the $19 plan (brief 010 risks).

## 3. Tigris bucket (human, once)

```bash
fly storage create --name umma-media --app umma-api   # private bucket; do NOT make it public
```

It prints an access key id and secret **once**, and sets `AWS_*` / `BUCKET_NAME` secrets on the
app. The app does not read those names; copy the two key values into the `STORAGE_*` secrets in
step 4. If the bucket name is taken, pick another and set `STORAGE_BUCKET` to match.

## 4. Secrets and settings

Set secrets with `fly secrets import`, which reads `NAME=value` lines from standard input, so
no value is ever typed on a command line (where it would land in shell history and the
process list). Keep the values in a file **outside the repo** that only you can read, or pipe
them straight from the tool that makes them. `--stage` avoids a restart per call before the
first deploy. Never put them in `fly.toml`,
the repo, a PR or a log.

**Required secrets** (the app refuses to start in `ENVIRONMENT=prod` without valid values):

| Name | What it is for |
|---|---|
| `DATABASE_URL` | The Neon URL from step 2. Used by web, worker and the release command. |
| `JWT_SECRET` | Signs the app's own session tokens (32 random bytes; the example below generates it). Changing it signs everyone out. |
| `STORAGE_ACCESS_KEY_ID` | Tigris access key id from step 3 (creator video, clips, cover photos). |
| `STORAGE_SECRET_ACCESS_KEY` | Tigris secret from step 3. |

**Secrets that turn features on** (each is optional; without it the feature degrades as noted):

| Name | What it is for | Without it |
|---|---|---|
| `GEMINI_API_KEY` | Coach, pantry photos, receipts, video extraction, live scan. Paid-tier key from the personal Cloud project (DECISIONS #19). Also needs `AI_PROVIDER=gemini`. | With `AI_PROVIDER=mock` every AI answer is the labelled demo path. |
| `GOOGLE_IOS_CLIENT_ID` | iOS OAuth client id for Sign in with Google (DECISIONS #33). Not secret, but set here so it is in one place. | `POST /v1/auth/google` does not exist. |
| `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` | Sign in with Apple key, used to exchange the sign-in authorization code for a refresh token (stored encrypted) and to revoke it when the person deletes their account (App Review guideline 5.1.1(v)). Team ID `V56DG94ZL5`; the key ID and `.p8` come from the developer portal (Keys → Sign in with Apple). Set the key from its file path as shown below and keep the `.p8` out of the repo (`*.p8`, `*.pem` and `*.key` are also excluded from the Docker image). | Sign-in and account deletion still work; the Apple revoke is skipped and logged. **Set these before the external beta.** |
| `REVIEW_LOGIN_CODE` | The secret code for Apple's Beta App Review login (section 10). At least 20 characters. | `POST /v1/auth/review` does not exist. |
| `PEXELS_API_KEY` | Stock cover photo after a first publish (brief 019). | Recipes without a cover stay without one. |
| `DEEPGRAM_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID` | Paid server voice (brief 012). Also needs `PAID_VOICE_ENABLED=true`, which needs the PM's go (DECISIONS #26). | Voice stays on the phone. |

**Plain settings** already in `fly.toml` `[env]` (change them there, not as secrets):
`ENVIRONMENT=prod`, `AUTH_MODE=apple` (dev sign-in does not exist in prod; the app refuses to
start with `AUTH_MODE=dev`), `LOG_LEVEL`, `STORAGE_ENDPOINT_URL=https://t3.storage.dev`,
`STORAGE_REGION=auto`, `STORAGE_ADDRESSING_STYLE=virtual`, `CLIENT_IP_HEADER=Fly-Client-IP`,
and the four AI caps below.

**Production start-up checks.** With `ENVIRONMENT=prod` the app (web, worker and the release
command) refuses to start unless: `AUTH_MODE` is not `dev`; the storage keys are real and the
endpoint is https; the four AI caps (`AI_USER_DAILY_CAP_USD`, `AI_USER_DAILY_LIVE_CAP_USD`,
`AI_MONTH_SOFT_CAP_USD`, `AI_MONTH_HARD_CAP_USD`) are each **stated** and above zero (a default
is not accepted); every rate limit is above zero; and `CLIENT_IP_HEADER` is set. A failed check
shows in `fly logs` as a settings validation error naming the variable.

**Settings with safe defaults** (set as secrets or in `[env]` only to change them):

| Name | Default | What it is for |
|---|---|---|
| `AI_PROVIDER` | `mock` | Set `gemini` to spend real money (PM go, DECISIONS #18). |
| `AI_USER_DAILY_CAP_USD` | `0.50` | Per-person AI spend per UTC day (DECISIONS #34). |
| `AI_USER_DAILY_LIVE_CAP_USD` | `1.15` | Per-person live pantry scan allowance per UTC day. |
| `AI_MONTH_SOFT_CAP_USD` / `AI_MONTH_HARD_CAP_USD` | `15` / `22` | App-wide monthly caps: soft turns video extraction off, hard sends everything to the demo path. |
| `RATE_LIMIT_SIGN_IN_PER_IP_PER_MINUTE` | `10` | Sign-in attempts per IP address per minute. |
| `RATE_LIMIT_PER_IP_PER_MINUTE` | `600` | All requests per IP address per minute (carrier networks share addresses, so this is loose). |
| `RATE_LIMIT_PER_USER_PER_MINUTE` | `300` | All requests per signed-in person per minute. |
| `RATE_LIMIT_COSTLY_PER_USER_PER_MINUTE` | `60` | Writes on AI, media, capture and voice routes per person per minute. |
| `AI_USER_VIDEO_EXTRACTIONS_PER_MONTH` | `5` | Creator video extractions per person per month. |
| `STORAGE_BUCKET` | `umma-media` | Tigris bucket name. |
| `APPLE_BUNDLE_ID` | `com.umma.ios` | Audience that Apple identity tokens must carry. |
| `DEFAULT_ENTITLEMENT` | `paid` | Every beta account is `paid` (brief 012). |
| `SHARE_URL_BASE` | `https://umma.app/r` | Base of recipe share links. Set to the live site domain. |
| `JWT_TTL_DAYS` | `30` | Session length. |

First-deploy example. The file lives outside the repo and holds one `NAME=value` per line:

```bash
umask 077 && mkdir -p ~/.umma-secrets
# Write DATABASE_URL, STORAGE_ACCESS_KEY_ID, STORAGE_SECRET_ACCESS_KEY and
# GOOGLE_IOS_CLIENT_ID into this file with an editor (not with echo on the command line):
"${EDITOR:-nano}" ~/.umma-secrets/prod.env
fly secrets import --stage --app umma-api < ~/.umma-secrets/prod.env

# Generated values go straight down a pipe and are never shown:
printf 'JWT_SECRET=%s\n' "$(openssl rand -hex 32)" | fly secrets import --stage --app umma-api

# The Sign in with Apple key, read from its file path (a multi-line value, so it is wrapped
# in triple quotes):
P8=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
{ printf 'APPLE_PRIVATE_KEY="""'; cat "$P8"; printf '"""\n'; } \
  | fly secrets import --stage --app umma-api
printf 'APPLE_TEAM_ID=V56DG94ZL5\nAPPLE_KEY_ID=XXXXXXXXXX\n' | fly secrets import --stage --app umma-api

fly secrets list --app umma-api      # names and digests only; check every name is there
```

## 5. First deploy (PM go required)

```bash
fly deploy --app umma-api            # builds the image, runs alembic, starts web + worker
fly scale count web=1 worker=1 --app umma-api
fly status --app umma-api            # both groups "started", web check "passing"
curl -s https://umma-api.fly.dev/v1/health    # {"status":"ok",…}
```

Keep **web at exactly 1 machine**: sign-in keys, voice limits and rate limits are held in that
one process. Scaling web out needs a shared store first.

**Rate limits and the caller's address.** Requests reach the app from Fly's proxy, so the
socket address is the proxy's, not the tester's. Fly's proxy sets `Fly-Client-IP` itself
(a caller cannot forge it), and `CLIENT_IP_HEADER=Fly-Client-IP` tells the app to use it for
per-IP limits. `X-Forwarded-For` is never read. Without the setting every tester would share
one per-IP budget, so the app refuses to start in prod when it is missing. If the backend ever
moves behind a different proxy, change this to the header *that* proxy overwrites. Over a
limit, the app answers 429 `RATE_LIMITED` and the phone can retry after a minute.

**Accepted limit:** the counters live in the web process, so every deploy or restart
(including a rolling deploy) resets them: a caller who was being throttled gets a fresh
budget. That is accepted for the beta; a shared store fixes it.

- IPv4 callers are counted per address; IPv6 callers per /64 (one home or phone line).
- A header value that is not an IP address is ignored and the socket address is used.
- IPv6 is also capped per /48 (8x the per-caller limit), so one allocation cannot pose as
  thousands of callers.
- Memory is bounded and counters are never reset wholesale. Each per-IP limiter tracks at
  most 20,000 callers and drops only callers idle for a minute. If it is full of active
  callers (a flood), a new caller is not refused: they are counted in a wider bucket (IPv4
  /24, IPv6 /48; 4,000 of those, 8x the per-caller limit each), and beyond that in one shared
  overflow bucket. So during a flood the flooding networks get throttled, callers already
  throttled stay throttled, and testers elsewhere are still served. In the very worst case
  (a flood from more than 4,000 networks at once) new testers share the overflow bucket and
  may see 429s until it eases; `fly logs` will show the spike.
- **This is a first line of defence, sized for a ~100-tester beta on one web machine.** It
  stops casual abuse and runaway clients; it is not DDoS protection. If the beta grows, or a
  second web machine is added, the step up is a shared store for the counters (Redis/Upstash)
  or rate limiting at Fly's edge.
- "Costly" writes (AI, voice, receipts, live scan, capture, media upload and uploaded
  callbacks, publish, clip trim) are marked in code with `Depends(limit_costly)`; a test fails
  when a new write route is not classified.

Seed the catalogue (ingredient dictionary, substitution rules, the demo recipes and creators).
Idempotent; re-run after any deploy that changes `fixtures/`:

```bash
fly ssh console --app umma-api --process-group web -C "python -m app.scripts.seed"
```

Then check from a phone build: Sign in with Apple, open a seeded recipe, start cooking.

## 6. Later deploys

```bash
fly deploy --app umma-api
```

The release command migrates first. If the migration fails the deploy stops and the old version
keeps serving. Migrations must stay backwards compatible with the previous image for that reason.

## 7. Rollback

```bash
fly releases --app umma-api --image                 # find the last good image
fly deploy --app umma-api --image registry.fly.io/umma-api:deployment-XXXXXXXX
```

This rolls back **code only**. The database is not rolled back: if the bad release ran a
migration, the old code must still work with the new schema (it does when migrations are
additive). Do not run `alembic downgrade` in production without a Neon branch/backup first
(Neon console → Branches → create a branch from a point in time).

## 8. Logs and debugging

```bash
fly logs --app umma-api                             # live, both groups
fly logs --app umma-api --process-group worker
fly ssh console --app umma-api --process-group web  # shell in the running machine
fly machine list --app umma-api
```

Logs are JSON lines: method, path, status, duration and a correlation id per request. Bodies,
tokens, photos and audio are never logged. A tester's error screen shows the correlation id;
search the logs for it.

## 9. Account deletion

`DELETE /v1/me` (Profile → Delete account) answers 204 and, in one transaction, deletes the
account and everything it owns: pantry, shopping list, preferences, follows, saves, cooking
sessions, drafts, recordings' transcripts, recipes, and every video, clip and cover photo
(the worker removes the files from Tigris within seconds; check with
`fly logs --process-group worker`).

- Recipes that another person has cooked, saved or adapted (or holds a substitution
  suggestion for) are kept without their media under an anonymous account named "Former Umma
  cook", so other people's sessions and saved lists keep working. All other recipes are
  deleted. A kept recipe is served without its step clips and without the creator's own cover
  link (the stock photo stays). The recipe's text is unchanged: anything the creator typed
  into the title, notes or steps, including a name, is still shown.
- If someone starts cooking one of the person's recipes at the very moment of deletion, the
  deletion re-checks and keeps that recipe. If it still cannot finish, nothing is deleted and
  the app gets 409 `ACCOUNT_DELETION_BUSY` (retryable); trying again works.
- AI spend rows stay, with the person removed, so deleting an account never refunds the
  monthly budget.
- **Accepted limit:** the Apple revoke is attempted once, right after the data is deleted. If
  Apple is down, or the web process dies in the moment between the delete and the revoke,
  there is no retry (the token was deleted with the account). The account and data are gone
  either way; only the "Sign in with Apple" entry on the person's Apple account remains,
  which they can remove in iPhone Settings.
- The Apple token is revoked after the data is gone. The log line `account deleted` carries
  `apple_revoke`: `revoked`, `failed` (Apple refused or was down; the account is still
  deleted), `skipped_no_token` (the app did not send an authorization code at sign-in, or the
  Apple key was not configured then), `skipped_not_configured`, or `not_apple` (Google).
  For `failed`/`skipped`, the person can remove the app under iPhone Settings → Apple Account
  → Sign in with Apple.
- The stored Apple refresh token is encrypted with a key derived from `JWT_SECRET`. Rotating
  `JWT_SECRET` makes stored tokens unreadable: later deletions skip the revoke until the
  person signs in again.

## 10. Review login (Beta App Review)

Apple's reviewers cannot use Sign in with Apple with a personal account, so production has
one extra way in while a build is in review: `POST /v1/auth/review` with body
`{"code": "<secret>"}`, answering the same token response as the other sign-ins.

- It signs in as **one fixed account** ("App Review"). That account is an ordinary user: it
  sees only its own pantry, sessions and recipes, plus the public catalogue. It can delete
  itself (reviewers test account deletion); the next review login makes a fresh one.
- The route exists **only while `REVIEW_LOGIN_CODE` is set**. Unset, it is a 404.
- Wrong codes get one indistinguishable 401. The code is compared in constant time and never
  logged. Its length (24 random bytes) is what makes guessing hopeless; the limits below only
  slow it down.
- Limits: every attempt counts against 5 per minute per address (plus the general sign-in
  limit of 10 per minute per address). **Wrong** codes also count against 30 per minute
  across all callers; over that, wrong codes get 429. The right code never spends or is
  blocked by that shared budget, so a flood of guesses cannot lock the reviewer out.
- Residual limit: the per-address limits still apply to the reviewer. Someone on the
  reviewer's own network (same IPv4 address or IPv6 /64), or a flood large enough to push
  new callers into shared prefix buckets (section 5), could still make the reviewer see 429
  for a minute. They retry; nothing is locked permanently.

Turn it on before submitting a build for review:

```bash
umask 077 && mkdir -p ~/.umma-secrets
printf 'REVIEW_LOGIN_CODE=%s\n' "$(openssl rand -base64 24)" > ~/.umma-secrets/review.env
fly secrets import --app umma-api < ~/.umma-secrets/review.env
cat ~/.umma-secrets/review.env        # copy the code into App Store Connect, then delete the file
```

Put the code in App Store Connect → the build's **Test Information → Beta App Review
Information → Sign-in required** (and the review notes), with one line on where to enter it
in the app. Never put it in the repo, a PR, a screenshot or the public site.

Turn it off when review is done, and rotate it for each new review:

```bash
fly secrets unset REVIEW_LOGIN_CODE --app umma-api   # the route is gone after the restart
```

If the code leaks: unset or replace it at once. Anyone holding it could only ever reach the
review account's own sandbox data, never a tester's.

## 11. Not done here

- No custom API domain: the app uses `https://<app>.fly.dev`.
- No staging app. Test risky changes locally with `make check` and the docker build above.
