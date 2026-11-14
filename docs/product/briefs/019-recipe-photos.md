# 019 — Recipe photos and a tighter layout

**Status:** approved (direction, 2026-11-14) · **Owner:** PM · **PR:** — · **Updated:** 2026-11-14

## Problem
Every recipe shows the same gradient placeholder. Creators have no way to add a photo of the
dish, and seeded or captured recipes never get one. Meanwhile the placeholder takes too much
room:

- On Explore, a 16:10 card photo is about 245pt tall, so one card fills most of the screen.
- On the recipe page, the 4:3 photo is about 290pt tall, which pushes the title and buttons
  below the fold.
- Each tab's title sits under an empty standard navigation bar, about 50pt below the clock.

PM direction (2026-11-14):
- Smaller photos.
- Real dish photos.
- A photo picker in the recipe editor.
- Tab titles at the top left.

## Who it's for
- Learners browsing Explore at dinnertime, who should see more dishes per screen and a real
  picture of each.
- Creators finishing a recipe, who want their own photo of the dish on it.

## What success looks like
- On Explore, about two cards fit on one iPhone screen, and every card shows a real food photo.
- On the recipe page, the photo, title, summary and both buttons are on the first screen.
- A creator adds a photo of their finished dish from the camera or their library in a few taps.
  It replaces any stock photo.
- Each tab's title sits at the top left, just under the status bar.

## Acceptance criteria

### Layout (iOS)
- [ ] **Explore card.** The card photo is about 2.4:1 (about 140pt on a 6.1" iPhone), down from
      16:10. Saved and creator-profile cards use the same card and shrink with it.
- [ ] **Recipe page photo.** The photo at the top is about 2.4:1, down from 4:3. Tapping it opens
      the photo full screen, where it can be closed with a swipe down or Close.
- [ ] **Photo credit.** When the photo comes from Pexels, a small line under the recipe page
      photo reads "Photo: {photographer} / Pexels". It links to the photographer's Pexels page.
      Cards in Explore show no credit and no label.
- [ ] **Tab headers.** Explore, Saved, Pantry and Profile drop the standard navigation bar on
      their top-level screen. Each shows its title in the brand display face at the top left,
      with standard top padding under the status bar.
- [ ] **Header specifics.**
  - Explore's search field moves into the page under the title. It keeps the same placeholder
    and search behaviour.
  - Pantry's mic, camera and + buttons sit at the trailing edge of its header.
  - Screens pushed from a tab, such as a recipe or a creator page, keep the standard back bar.
- [ ] **Accessibility.**
  - Headers keep the header trait, so VoiceOver announces each title as a heading.
  - Titles scale with Dynamic Type.
  - The photo viewer has a labelled Close button.

### Stock photos from Pexels (backend)
- [ ] **When.** A published recipe without a creator photo gets one Pexels photo:
  - on first publish, looked up after the publish commits, so a Pexels failure never blocks
    publishing
  - by a backfill command for existing recipes, including the seeded ones
- [ ] **What is stored.** The image URL, the photographer's name and Pexels page URL, and the
      Pexels photo id, all on the recipe. The read side never calls Pexels.
- [ ] **Query.** The recipe title. If nothing comes back, retry once with the title's last two
      words plus "food". If that also finds nothing, store nothing: the card keeps the
      placeholder, and nothing is guessed.
- [ ] **Precedence.** A creator photo always wins. Removing a creator photo falls back to the
      stored stock photo.
- [ ] **No key, no lookup.** Without `PEXELS_API_KEY` the lookup is skipped and logged once.
      Tests never call the network.
- [ ] **Rate limit.** Backfill stays under Pexels' 200 requests an hour.

### Finished-dish photo (backend + iOS)
- [ ] **Editor entry.** The recipe editor has a "Photo of the finished dish" section with:
  - **Take photo** (camera)
  - **Choose from library** (photo picker)
  - **Remove** once a photo is set
  - a preview at the card's 2.4:1 crop
- [ ] **Permissions.**
  - Camera permission is asked on the first Take photo, using the existing camera usage string.
  - The library picker needs no permission.
  - A denied camera explains how to allow it in Settings, and Choose from library still works.
- [ ] **On device.** The photo is downscaled to at most 2048px on the long edge and re-encoded
      as JPEG before upload. Re-encoding drops all metadata, including location.
- [ ] **Upload.** The photo goes up through a presigned PUT to private object storage, as source
      videos do (brief 008). The phone never sees storage credentials.
  - The server confirms the upload: the object exists, is under 10 MB, and starts with JPEG
    magic bytes. Otherwise it rejects it.
  - Progress shows while uploading. A failure shows Try again and keeps the draft unchanged.
- [ ] **Versions.** The draft holds the photo until publish. Publishing attaches it to that
      version, and published versions stay immutable. A later edit with a new photo creates a
      new version.
- [ ] **Read side.** Uploaded photos are served through short-lived signed URLs, generated on
      each read, as step clips are.
- [ ] **Ownership.** Another creator's photo is the same 404 as a missing one.
- [ ] **Abuse caps.** Cover photos count toward the existing monthly upload byte budget. A user
      can have at most 5 unconfirmed cover uploads at a time.

## Out of scope
- AI-generated dish images.
- More than one photo per recipe, step photos and galleries.
- Cropping or filters in the app. The system picker's own crop is enough.
- Image moderation beyond type and size checks. This is a pilot with known testers; it is
  revisited before a public launch.
- Choosing between several Pexels results. The first result is used, and the creator can
  replace it.

## Open product questions
1. **Label stock photos as "Example photo"?** Options: A, label the card and the recipe page;
   B, no label, with the Pexels credit on the recipe page only.
   → *Answer (PM, 2026-11-14):* **B.** No label anywhere. The credit stays on the recipe page,
   since Pexels' API terms ask for it.
2. **Photo source for recipes without a creator photo?** Options: Pexels, Unsplash,
   AI-generated, web image search.
   → *Answer (PM, 2026-11-14):* **Pexels.** It had the closest matches for the test dish, a free
   API, and we can keep our own copy. Web image search was ruled out, because those photos
   belong to other sites.
3. **Explore card and recipe photo size?**
   → *Answer (PM):* a short banner on both, about 2.4:1.
4. **Tab headers?**
   → *Answer (PM):* our own header on all four tabs, with the title at the top left.

## PR sequence
1. **docs:** this brief and DECISIONS #31.
2. **backend: cover photo upload.**
   - Migration: cover media on drafts, versions and recipes, plus the stock-photo credit columns.
   - Upload intent and confirm for `cover_image`, attached to the draft.
   - Publish carries it to the version.
   - Signed URL on read, with the additive `cover_credit` field on cards and detail.
3. **backend: Pexels stock photos.** The adapter, the post-publish lookup, the backfill command
   (`make covers`) and its tests.
4. **iOS: smaller photos.** The 2.4:1 card and recipe photo, the full-screen viewer and the
   credit line.
5. **iOS: tab headers.** The custom header on the four tabs, with Explore search moved into the
   page.
6. **iOS: finished-dish photo.** The media service calls, and the editor section with camera,
   library, upload progress and remove.

PRs 4 and 5 don't depend on the backend and can merge first. PR 6 needs PR 2.

## Engineering decisions (filled in by the lead while building)
- …

## Risks / what could go wrong for users
- **A stock photo can look like the creator's dish.** The PM accepted this (question 1). The
  credit on the recipe page is the only marker, and a creator photo replaces the stock one.
- **The wrong dish.** Title search can return a near miss, such as fried chicken for glazed
  thighs. Pexels' metadata matched well on the test dish, but some titles will miss. The
  creator can replace the photo, and the backfill can be re-run per recipe.
- **Location leaks.** Phone photos carry GPS in their metadata. Re-encoding on the device drops
  it; a test asserts that the uploaded bytes carry no EXIF.
- **The custom header drops system behaviour.** We lose the large title collapsing into the bar
  on scroll and the system search bar's placement. The header scrolls with the content, and
  search keeps its keyboard and submit behaviour.
