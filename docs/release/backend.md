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

Set with `fly secrets set NAME=value … --app umma-api` (one command can take several; add
`--stage` to avoid a restart per call before the first deploy). Never put them in `fly.toml`,
the repo, a PR or a log.

**Required secrets** (the app refuses to start in `ENVIRONMENT=prod` without valid values):

| Name | What it is for |
|---|---|
| `DATABASE_URL` | The Neon URL from step 2. Used by web, worker and the release command. |
| `JWT_SECRET` | Signs the app's own session tokens. Generate: `openssl rand -hex 32`. Changing it signs everyone out. |
| `STORAGE_ACCESS_KEY_ID` | Tigris access key id from step 3 (creator video, clips, cover photos). |
| `STORAGE_SECRET_ACCESS_KEY` | Tigris secret from step 3. |

**Secrets that turn features on** (each is optional; without it the feature degrades as noted):

| Name | What it is for | Without it |
|---|---|---|
| `GEMINI_API_KEY` | Coach, pantry photos, receipts, video extraction, live scan. Paid-tier key from the personal Cloud project (DECISIONS #19). Also needs `AI_PROVIDER=gemini`. | With `AI_PROVIDER=mock` every AI answer is the labelled demo path. |
| `GOOGLE_IOS_CLIENT_ID` | iOS OAuth client id for Sign in with Google (DECISIONS #33). Not secret, but set here so it is in one place. | `POST /v1/auth/google` does not exist. |
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

First-deploy example (values are placeholders):

```bash
fly secrets set --stage --app umma-api \
  DATABASE_URL='postgresql+asyncpg://…?ssl=require' \
  JWT_SECRET="$(openssl rand -hex 32)" \
  STORAGE_ACCESS_KEY_ID='tid_…' STORAGE_SECRET_ACCESS_KEY='tsec_…' \
  GOOGLE_IOS_CLIENT_ID='…apps.googleusercontent.com'
fly secrets list --app umma-api      # names and digests only
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
limit, the app answers 429 `RATE_LIMITED` and the phone can retry after a minute. Counters
reset on every deploy or restart.

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

## 9. Not done here

- No custom API domain: the app uses `https://<app>.fly.dev`.
- No staging app. Test risky changes locally with `make check` and the docker build above.
