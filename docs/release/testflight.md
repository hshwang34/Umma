# TestFlight pipeline (brief 010)

How an Umma build gets from this repo to a tester's phone. Human steps first, then the scripted
ones. It reuses the shared personal pipeline in `~/Documents/Projects/IOS-RELEASE.md`
(`testflight-upload.sh`, `asc.py`); read that runbook's gotchas once.

| What | Value |
|---|---|
| Apple Developer team | `V56DG94ZL5` (personal, individual). Never a work team. |
| Bundle ID | `com.umma.ios` |
| App Store Connect record | "Umma Cooks", Apple ID `6834884703`, SKU `umma-ios-001` (DECISIONS #33) |
| Home-screen name | Umma (`CFBundleDisplayName`) |
| Production API | `https://umma-api.fly.dev` (`ios/Umma/App/BuildConfig.swift`, one line) |
| Support and privacy contact | jacogoby@gmail.com (DECISIONS #20) |
| Tester cap on the public link | 100 (DECISIONS #20) |

**No key material lives in this repo.** The App Store Connect API key (`.p8`), its key ID and
the Issuer ID stay in `~/.appstoreconnect/` as described in `IOS-RELEASE.md`. The Sign in with
Apple key stays in Fly secrets (`docs/release/backend.md`). Never paste either into a file, a
commit, a log or a PR.

## Part 1: human steps (PM, once)

### 1. Developer portal: App ID
developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → `com.umma.ios`.

- [ ] The App ID exists on team `V56DG94ZL5`. (The first signed archive with
      `-allowProvisioningUpdates` registers it if it does not.)
- [ ] **Sign in with Apple** is ticked, as a primary App ID.
- [ ] **Associated Domains** is ticked (the app declares `applinks:ummacooks.app`).
- [ ] Keychain sharing needs no tick; it is an entitlement only.

### 2. Developer portal: Sign in with Apple key
Keys → **+** → Sign in with Apple → configure for `com.umma.ios`.

- [ ] Download the `.p8` (Apple shows it once) and store it as a Fly secret with its key ID.
      The backend uses it to revoke Apple tokens when an account is deleted. It is not used by
      the iOS build and never goes in this repo.

### 3. Google Cloud: iOS OAuth client (for Sign in with Google)
console.cloud.google.com, signed in with the **personal** Google account.

- [ ] OAuth consent screen: External, app name Umma, support email jacogoby@gmail.com,
      scopes `openid`, `email`, `profile` only.
- [ ] Credentials → Create OAuth client ID → **iOS**, bundle ID `com.umma.ios`.
- [ ] Give the client ID to the eng lead. It is not a secret. It goes in two places: the
      backend's `GOOGLE_IOS_CLIENT_ID` and the app's Google client ID setting. Until it is set,
      the Google button stays hidden.

### 4. App Store Connect: the app record
appstoreconnect.apple.com → Apps. The record "Umma Cooks" (Apple ID `6834884703`) exists.

- [ ] Confirm bundle ID `com.umma.ios`, SKU `umma-ios-001`, primary language English (U.S.).
- [ ] App Information → Privacy Policy URL: `https://ummacooks.app/privacy.html`.

### 5. App Store Connect: API key
Already set up for every personal app; nothing to create.

- [ ] `~/.appstoreconnect/config.env` and the `.p8` under `~/.appstoreconnect/private_keys/`
      exist on the Mac that runs the release (see `IOS-RELEASE.md`, "Credentials"). If the
      `.p8` is lost, follow that runbook to revoke and replace the key.

### 6. App Store Connect: App Privacy
App Privacy → Get Started. Answer from `docs/release/app-privacy.md`. The answers must match
`ios/Umma/Resources/PrivacyInfo.xcprivacy`.

- [ ] Data is collected: yes. No tracking. Nothing is used for advertising or analytics.
- [ ] Publish the answers.

### 7. App Store Connect: Test Information
TestFlight → Test Information.

- [ ] Beta App Description and "What to Test" (short, plain; the PRD §15 demo path).
- [ ] Feedback email jacogoby@gmail.com. Privacy Policy URL as above.
- [ ] Beta App Review Information: contact name, phone, jacogoby@gmail.com.
- [ ] Sign-in required: yes. Paste the review notes from `docs/release/review-notes.md`,
      which explain the review login.
- [ ] Export compliance is not asked per build: the app sets
      `ITSAppUsesNonExemptEncryption = NO`.

### 8. Internal group (no review)
After the first build is processed (Part 2).

- [ ] TestFlight → Internal Testing → **+** → a group, add yourself, add the build.
- [ ] Install from the TestFlight app on a real iPhone and run the PRD §15 demo end to end
      against production: Sign in with Apple, browse, cook, delete the account.

### 9. External group and the public link
Only once the internal run passes and the backend PRs for external testing are live.

- [ ] TestFlight → External Testing → **+** → a group. Add the build. This submits it to
      **Beta App Review** (usually about a day for a first build).
- [ ] When approved: the group → Public Link → enable, **limit 100 testers**.
- [ ] Share the link. To pause sign-ups, disable the link; installed testers keep the build.

## Part 2: scripted steps (every build)

Uploading is outward-facing. The eng lead confirms with the PM before step 3.

1. Be on `main` with the release commit, in a clean checkout. `make ios-check` is green.
2. Archive without uploading, and read what it prints:
   ```bash
   make release-ios
   ```
   It regenerates the project, archives the Release configuration signed for team
   `V56DG94ZL5`, and prints the bundle ID, version and build number. Expect `com.umma.ios`.
   The archive is at `ios/build/release/Umma.xcarchive`.
3. Archive and upload:
   ```bash
   make release-ios UPLOAD=1                        # build number = UTC timestamp
   make release-ios UPLOAD=1 VERSION=0.2.0 BUILD=7  # or set both yourself
   ```
   `BUILD` must be higher than every build already uploaded for that version. The default
   (a UTC timestamp, `YYYYMMDDHHMM`) always is. `VERSION` defaults to `MARKETING_VERSION` in
   `ios/project.yml`; change it there for a new version so the repo matches what shipped.
4. Wait for processing (5 to 30 minutes), then check:
   ```bash
   cd ~/Documents/Projects/.claude/scripts && uv run -q --with pyjwt --with cryptography \
     python -I asc.py GET '/v1/builds?filter[app]=6834884703&fields[builds]=version,processingState'
   ```
   `VALID` means ready. If it says `FAILED`, `/v1/apps/6834884703/buildUploads` says why.
5. Add the build to the internal group (Part 1, step 8), then the external group (step 9).

## What a release build does differently

- Talks only to `https://umma-api.fly.dev`. A server address saved by an earlier debug build is
  ignored, and the server settings screen and server status are not shown.
- No dev sign-in (email and 6-digit code). Sign in with Apple, and Google once its client ID is set.
- The version and build number come from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.

## If something goes wrong

- **Archive fails on signing:** check `~/.appstoreconnect/config.env` and that the App ID has
  the capabilities in Part 1, step 1.
- **Processing FAILED:** usually a missing usage string or a build number that is not higher.
  Fix, then upload again with a new `BUILD`.
- **Sign in with Apple fails on the TestFlight build only:** the capability is missing on the
  App ID, or the backend's Apple audience is not `com.umma.ios`.
