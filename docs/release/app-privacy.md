# App Privacy answers (draft, brief 010)

Draft answers for App Store Connect → App Privacy. The PM reviews and enters them by hand.
They must match `ios/Umma/Resources/PrivacyInfo.xcprivacy`; change both together.

**Status: draft.** Items marked *PM to confirm* need a decision before publishing.

## Summary

- **Tracking:** No. Umma does not track people across other companies' apps or sites.
- **Third-party SDKs:** none in the app. No ads, no analytics, no crash reporter.
- **Data collected:** yes, all of it linked to the account and used only for
  **App Functionality**. Nothing is used for advertising, analytics, personalization of ads
  or sold.
- **Privacy policy:** `https://ummacooks.app/privacy.html`. Contact: jacogoby@gmail.com.

## Data types

For every row: *Linked to the user* = Yes, *Used for tracking* = No, *Purpose* = App Functionality.

| Apple category | Data type | What it is in Umma |
|---|---|---|
| Contact Info | Name | The display name Apple or Google shares at sign-in. Shown on recipes the person publishes. |
| Contact Info | Email Address | The email Apple or Google shares (Apple may give a relay address). Account identity only; no marketing email. |
| Identifiers | User ID | The account ID and the sign-in provider's subject ID. |
| User Content | Photos or Videos | Photos the person takes of their pantry, a receipt or a cooking step, and recipe photos or video they add. |
| User Content | Audio Data | Speech while the person talks to the voice coach, when server voice is on. |
| Health & Fitness | Health | Allergies the person enters, so swaps never suggest them. *PM to confirm (below).* |
| User Content | Other User Content | Recipes and drafts, pantry items, food preferences, cooking sessions and questions asked to the coach. |

## Not collected

Location, contacts, browsing or search history, purchases, financial info, device or
advertising identifiers, usage analytics, diagnostics or crash data, messages.

## Things the review may ask about

- **Speech recognition:** on-device voice uses Apple's speech recognition; audio may be
  processed by Apple to transcribe it. Umma does not keep that audio.
- **AI processing:** photos, transcripts and questions are sent to Umma's server, which uses
  Google's Gemini API to answer. The provider key is only on the server. This is processing on
  our behalf, not sharing for the provider's own purposes. *PM to confirm* the Gemini API terms
  in use do not allow training on this data; if they do, say so in the privacy policy.
- **Camera and microphone:** only while the person has tapped to scan, record or talk. Nothing
  is captured in the background.
- **Deletion:** Profile → Delete account deletes the account, its data and media, and revokes
  the Apple sign-in token.
- **Retention:** a creator's source video is kept until the creator deletes it (DECISIONS #20).
  Pantry and step photos are not kept on the phone after the server answers.

## Open questions for the PM

1. **Allergies as Health data.** A) Declare "Health" (what this draft and the manifest do):
   the most cautious reading, and the label shows "Health". B) Declare them only under "Other
   User Content": a lighter label, but a reviewer could disagree. **Recommendation:** A.
2. **Audio Data while server voice is off.** Server voice ships dark
   (`PAID_VOICE_ENABLED=false`). A) Declare Audio Data now (this draft), so nothing changes
   when it is switched on. B) Leave it out until then and update the answers at that time.
   **Recommendation:** A.
